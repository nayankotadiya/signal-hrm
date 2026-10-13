import { Injectable, OnModuleInit } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, conflict, dayString, notFound, objectId, oid, Paged } from '../../common/http/validation';
import { localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { ApprovalEngine } from '../approvals/approval.engine';
import { FilesService } from '../files/files.service';
import { NotificationsService } from '../notifications/notifications.service';

export const expenseInput = z.object({
  categoryId: objectId,
  amount: z.number().positive().max(10_000_000),
  currency: z.string().length(3).toUpperCase().default('INR'),
  expenseDate: dayString,
  merchant: z.string().trim().max(120).optional(),
  description: z.string().trim().max(1000).optional(),
  receiptFileId: objectId.optional().nullable(),
  taskId: objectId.optional(),
  travelRequestId: objectId.optional(),
  submit: z.boolean().default(true),
});

const r2 = (n: number): number => Math.round(n * 100) / 100;

@Injectable()
export class ExpensesService implements OnModuleInit {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly approvals: ApprovalEngine,
    private readonly files: FilesService,
    private readonly notifications: NotificationsService,
    private readonly orgSettings: OrgSettingsService,
    @InjectModel('Expense') private readonly expenses: Model<any>,
    @InjectModel('ExpenseCategory') private readonly categories: Model<any>,
    @InjectModel('Reimbursement') private readonly reimbursements: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  onModuleInit(): void {
    this.approvals.register('expense', {
      // Approval never marks the expense paid: it only becomes eligible for reimbursement.
      onApproved: async (a) => void (await this.expenses.updateOne({ _id: a.requestId, status: 'submitted' }, { $set: { status: 'approved', reimbursementStatus: 'pending' } })),
      onRejected: async (a, _c, comment) => {
        await this.expenses.updateOne({ _id: a.requestId, status: 'submitted' }, { $set: { status: 'rejected', decisionComment: comment } });
        await this.notifyOwner(a.requestId, 'Expense not approved', comment);
      },
      onClarification: async (a, _c, comment) => void (await this.expenses.updateOne({ _id: a.requestId }, { $set: { decisionComment: comment } })),
      onCancelled: async (a) => void (await this.expenses.updateOne({ _id: a.requestId }, { $set: { status: 'cancelled' } })),
    });
    this.files.registerAuthorizer('expense', async (ctx, f) => String(f.ownerEmployeeId) === ctx.user.employeeId || this.scope.covers(ctx, 'expenses', 'view', f.ownerEmployeeId));
  }

  private async notifyOwner(expenseId: Types.ObjectId, title: string, body?: string): Promise<void> {
    const e = await this.expenses.findById(expenseId).lean<any>();
    const u = e ? await this.users.findOne({ organizationId: e.organizationId, employeeId: e.employeeId }, { _id: 1 }).lean<any>() : null;
    if (u) await this.notifications.notify(e.organizationId, [u._id], { event: 'expense_decided', title, body, link: '/money/expenses' });
  }

  /** Policy-limit hints shown while filling the form and to the approver. They warn; they don't block. */
  async policyCheck(ctx: Ctx, employeeId: Types.ObjectId, b: { categoryId: string; amount: number; expenseDate: string; receiptFileId?: string | null }, excludeId?: Types.ObjectId): Promise<{ warnings: string[]; receiptRequired: boolean }> {
    const cat = await this.categories.findOne({ _id: oid(b.categoryId), organizationId: ctx.orgOid, active: true }).lean<any>();
    if (!cat) throw badRequest('CATEGORY_INVALID', 'Choose a category.', 'categoryId');
    const org = await this.orgSettings.get(ctx.orgOid);
    const warnings: string[] = [];
    if (cat.perClaimLimit && b.amount > cat.perClaimLimit) warnings.push(`Above the ${cat.name} limit of ${cat.perClaimLimit} per claim.`);
    if (cat.monthlyLimit) {
      const month = b.expenseDate.slice(0, 7);
      const agg = await this.expenses.aggregate([
        { $match: { organizationId: ctx.orgOid, employeeId, categoryId: cat._id, expenseDate: { $regex: `^${month}` }, status: { $in: ['submitted', 'approved'] }, ...(excludeId ? { _id: { $ne: excludeId } } : {}) } },
        { $group: { _id: null, total: { $sum: '$amount' } } },
      ]);
      const total = (agg[0]?.total ?? 0) + b.amount;
      if (total > cat.monthlyLimit) warnings.push(`This month's ${cat.name} total would be ${r2(total)}, above the ${cat.monthlyLimit} monthly limit.`);
    }
    const threshold = cat.receiptRequiredAbove ?? org.settings?.expenses?.receiptRequiredAbove ?? 500;
    return { warnings, receiptRequired: b.amount > threshold };
  }

  async create(ctx: Ctx, b: z.infer<typeof expenseInput>): Promise<any> {
    PermissionsService.require(ctx, 'expenses', 'create');
    if (!ctx.employeeOid) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    const org = await this.orgSettings.get(ctx.orgOid);
    const today = localParts(new Date(), org.timezone).day;
    if (b.expenseDate > today) throw badRequest('FUTURE_DATE', "The expense date can't be in the future.", 'expenseDate');
    const check = await this.policyCheck(ctx, ctx.employeeOid, b);
    if (b.submit && check.receiptRequired && !b.receiptFileId) throw badRequest('RECEIPT_REQUIRED', 'Attach a receipt for this amount.', 'receiptFileId');
    const receipt = b.receiptFileId ? await this.files.requireOwnUpload(ctx, b.receiptFileId, 'receipt') : null;
    const doc = await this.expenses.create({
      organizationId: ctx.orgOid,
      employeeId: ctx.employeeOid,
      categoryId: oid(b.categoryId),
      amount: r2(b.amount),
      currency: b.currency,
      expenseDate: b.expenseDate,
      merchant: b.merchant,
      description: b.description,
      receiptFileId: receipt?._id,
      taskId: b.taskId ? oid(b.taskId) : undefined,
      travelRequestId: b.travelRequestId ? oid(b.travelRequestId) : undefined,
      policyWarnings: check.warnings,
      status: 'draft',
    });
    if (receipt) await this.files.link(receipt._id, { type: 'expense', id: doc._id });
    await this.audit.record(ctx, { action: 'expense.create', resourceType: 'expense', resourceId: doc._id, changes: { amount: { from: null, to: doc.amount } } });
    return b.submit ? this.submit(ctx, String(doc._id)) : serialize(doc.toObject());
  }

  async submit(ctx: Ctx, id: string): Promise<any> {
    const e = await this.expenses.findOne({ _id: oid(id), organizationId: ctx.orgOid, employeeId: ctx.employeeOid }).lean<any>();
    if (!e) throw notFound('Expense');
    if (e.status !== 'draft') throw conflict('EXPENSE_NOT_DRAFT', `This expense is already ${e.status}.`);
    const check = await this.policyCheck(ctx, e.employeeId, { categoryId: String(e.categoryId), amount: e.amount, expenseDate: e.expenseDate, receiptFileId: e.receiptFileId ? String(e.receiptFileId) : null }, e._id);
    if (check.receiptRequired && !e.receiptFileId) throw badRequest('RECEIPT_REQUIRED', 'Attach a receipt for this amount.', 'receiptFileId');
    const r = await this.expenses.updateOne({ _id: e._id, status: 'draft' }, { $set: { status: 'submitted', submittedAt: new Date(), policyWarnings: check.warnings } });
    if (!r.modifiedCount) throw conflict('EXPENSE_NOT_DRAFT', 'This expense was already submitted.');
    const cat = await this.categories.findById(e.categoryId, { name: 1 }).lean<any>();
    const a = await this.approvals.start(ctx, {
      requestType: 'expense',
      requestId: e._id,
      subjectEmployeeId: e.employeeId,
      title: `Expense ${e.currency} ${e.amount}: ${ctx.user.name}`,
      summary: `${cat?.name ?? 'Expense'} · ${e.expenseDate}${e.merchant ? ` · ${e.merchant}` : ''}${check.warnings.length ? ` · ${check.warnings.length} policy warning(s)` : ''}`,
      amount: e.amount,
      link: '/money/expenses',
    });
    await this.expenses.updateOne({ _id: e._id }, { $set: { approvalId: a._id } });
    return serialize(await this.expenses.findById(e._id).lean());
  }

  async cancel(ctx: Ctx, id: string): Promise<any> {
    const e = await this.expenses.findOne({ _id: oid(id), organizationId: ctx.orgOid, employeeId: ctx.employeeOid }).lean<any>();
    if (!e) throw notFound('Expense');
    if (e.status === 'draft') await this.expenses.updateOne({ _id: e._id }, { $set: { status: 'cancelled' } });
    else if (e.status === 'submitted') await this.approvals.cancel(ctx, 'expense', e._id);
    else throw conflict('EXPENSE_CLOSED', `This expense is already ${e.status}.`);
    await this.audit.record(ctx, { action: 'expense.cancel', resourceType: 'expense', resourceId: id });
    return serialize(await this.expenses.findById(e._id).lean());
  }

  async list(ctx: Ctx, q: { mine?: boolean; employeeId?: string; status?: string; reimbursementStatus?: string; categoryId?: string; from?: string; to?: string; page: number; limit: number }): Promise<Paged<any>> {
    const filter: Record<string, any> = q.mine ? { organizationId: ctx.orgOid, employeeId: ctx.employeeOid ?? null } : await this.scope.filter(ctx, 'expenses', 'view');
    if (q.employeeId) {
      await this.scope.requireCovers(ctx, 'expenses', 'view', q.employeeId);
      filter.employeeId = oid(q.employeeId);
    }
    if (q.status) filter.status = q.status;
    if (q.reimbursementStatus) filter.reimbursementStatus = q.reimbursementStatus;
    if (q.categoryId) filter.categoryId = oid(q.categoryId);
    if (q.from || q.to) filter.expenseDate = { ...(q.from ? { $gte: q.from } : {}), ...(q.to ? { $lte: q.to } : {}) };
    const [rows, total] = await Promise.all([this.expenses.find(filter).sort({ expenseDate: -1, createdAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean<any[]>(), this.expenses.countDocuments(filter)]);
    const [cats, emps] = await Promise.all([
      this.categories.find({ organizationId: ctx.orgOid }, { name: 1 }).lean<any[]>(),
      this.employees.find({ _id: { $in: rows.map((r) => r.employeeId) } }, { firstName: 1, lastName: 1 }).lean<any[]>(),
    ]);
    const catName = new Map(cats.map((c) => [String(c._id), c.name]));
    const empName = new Map(emps.map((e) => [String(e._id), `${e.firstName} ${e.lastName ?? ''}`.trim()]));
    return { items: serialize(rows).map((r: any) => ({ ...r, categoryName: catName.get(r.categoryId), employeeName: empName.get(r.employeeId) })), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  /** Category donut and monthly bars for the dashboard (scoped). */
  async summary(ctx: Ctx, from: string, to: string, mine: boolean): Promise<any> {
    const filter: Record<string, any> = mine ? { organizationId: ctx.orgOid, employeeId: ctx.employeeOid ?? null } : await this.scope.filter(ctx, 'expenses', 'view');
    filter.expenseDate = { $gte: from, $lte: to };
    filter.status = { $in: ['submitted', 'approved'] };
    const [byCategory, byMonth, pending] = await Promise.all([
      this.expenses.aggregate([{ $match: filter }, { $group: { _id: '$categoryId', total: { $sum: '$amount' }, count: { $sum: 1 } } }, { $sort: { total: -1 } }]),
      this.expenses.aggregate([{ $match: filter }, { $group: { _id: { $substrBytes: ['$expenseDate', 0, 7] }, total: { $sum: '$amount' } } }, { $sort: { _id: 1 } }]),
      this.expenses.aggregate([{ $match: { ...filter, status: 'approved', reimbursementStatus: { $in: ['pending', 'scheduled'] } } }, { $group: { _id: null, total: { $sum: '$amount' }, count: { $sum: 1 } } }]),
    ]);
    const cats = await this.categories.find({ organizationId: ctx.orgOid }, { name: 1 }).lean<any[]>();
    const catName = new Map(cats.map((c) => [String(c._id), c.name]));
    return {
      byCategory: byCategory.map((c: any) => ({ categoryId: String(c._id), name: catName.get(String(c._id)) ?? 'Other', total: r2(c.total), count: c.count })),
      byMonth: byMonth.map((m: any) => ({ month: m._id, total: r2(m.total) })),
      pendingReimbursement: { total: r2(pending[0]?.total ?? 0), count: pending[0]?.count ?? 0 },
    };
  }

  // ------------------------------------------------------------------ reimbursements (separate from approval)

  async scheduleReimbursement(ctx: Ctx, expenseIds: string[]): Promise<any[]> {
    PermissionsService.require(ctx, 'expenses', 'manage', 'organization');
    const rows = await this.expenses.find({ _id: { $in: expenseIds.map(oid) }, organizationId: ctx.orgOid, status: 'approved', reimbursementStatus: 'pending' }).lean<any[]>();
    if (!rows.length) throw badRequest('NOTHING_TO_SCHEDULE', 'None of these expenses are approved and waiting for reimbursement.');
    const byEmp = new Map<string, any[]>();
    for (const r of rows) byEmp.set(String(r.employeeId), [...(byEmp.get(String(r.employeeId)) ?? []), r]);
    const out = [];
    for (const [emp, list] of byEmp) {
      const reim = await this.reimbursements.create({ organizationId: ctx.orgOid, employeeId: oid(emp), expenseIds: list.map((x) => x._id), amount: r2(list.reduce((a, x) => a + x.amount, 0)), currency: list[0].currency, status: 'scheduled' });
      await this.expenses.updateMany({ _id: { $in: list.map((x) => x._id) }, reimbursementStatus: 'pending' }, { $set: { reimbursementStatus: 'scheduled', reimbursementId: reim._id } });
      await this.audit.record(ctx, { action: 'reimbursement.schedule', resourceType: 'reimbursement', resourceId: reim._id, changes: { amount: { from: null, to: reim.amount } } });
      out.push(serialize(reim.toObject()));
    }
    return out;
  }

  /** Paid is recorded with a payment reference by someone authorized; never inferred from approval. */
  async markPaid(ctx: Ctx, id: string, paymentReference: string): Promise<any> {
    PermissionsService.require(ctx, 'expenses', 'manage', 'organization');
    const r = await this.reimbursements.findOneAndUpdate({ _id: oid(id), organizationId: ctx.orgOid, status: 'scheduled' }, { $set: { status: 'paid', paidAt: new Date(), paymentReference, paidBy: ctx.userOid } }, { new: true }).lean<any>();
    if (!r) throw conflict('REIMBURSEMENT_NOT_SCHEDULED', 'This reimbursement is not waiting for payment.');
    await this.expenses.updateMany({ _id: { $in: r.expenseIds } }, { $set: { reimbursementStatus: 'paid' } });
    await this.audit.record(ctx, { action: 'reimbursement.paid', resourceType: 'reimbursement', resourceId: id, changes: { paymentReference: { from: null, to: paymentReference } } });
    const u = await this.users.findOne({ organizationId: ctx.orgOid, employeeId: r.employeeId }, { _id: 1 }).lean<any>();
    if (u) await this.notifications.notify(ctx.orgOid, [u._id], { event: 'expense_decided', title: `Reimbursement paid: ${r.currency} ${r.amount}`, body: `Reference ${paymentReference}`, link: '/money/expenses' });
    return serialize(r);
  }

  async listReimbursements(ctx: Ctx, status?: string): Promise<any[]> {
    const filter: Record<string, unknown> = await this.scope.filter(ctx, 'expenses', 'view');
    if (status) filter.status = status;
    return serialize(await this.reimbursements.find(filter).sort({ createdAt: -1 }).limit(200).lean());
  }

  // ------------------------------------------------------------------ categories

  async listCategories(ctx: Ctx): Promise<any[]> {
    return serialize(await this.categories.find({ organizationId: ctx.orgOid }).sort({ name: 1 }).lean());
  }

  async saveCategory(ctx: Ctx, b: { name: string; code?: string; perClaimLimit?: number | null; monthlyLimit?: number | null; receiptRequiredAbove?: number | null; active?: boolean }, id?: string): Promise<any> {
    PermissionsService.require(ctx, 'expenses', 'manage', 'organization');
    if (id) {
      const r = await this.categories.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: b });
      if (!r.matchedCount) throw notFound('Category');
    } else {
      if (await this.categories.exists({ organizationId: ctx.orgOid, name: b.name })) throw conflict('CATEGORY_EXISTS', 'This category already exists.');
      id = String((await this.categories.create({ ...b, organizationId: ctx.orgOid })).id);
    }
    await this.audit.record(ctx, { action: 'expense_category.save', resourceType: 'expense_category', resourceId: id });
    return serialize(await this.categories.findById(id).lean());
  }
}
