import { Inject, Injectable, OnModuleInit } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService, diff } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { encrypt, mask } from '../../common/crypto/crypto';
import { badRequest, conflict, escapeRegex, forbidden, ListQuery, notFound, objectId, oid, Paged, sortSpec } from '../../common/http/validation';
import { APP_CONFIG } from '../../config/config.module';
import { AppEnv, secretOf } from '../../config/env.schema';
import { InjectModel, serialize } from '../../database/model';
import { EMPLOYMENT_STATUSES, EMPLOYMENT_TYPES } from '../../schemas/workforce.schemas';
import { ApprovalEngine } from '../approvals/approval.engine';
import { NotificationsService } from '../notifications/notifications.service';
import { SessionService } from '../auth/session.service';
import { JobsService } from '../system/jobs.service';
import { UsersService } from '../users/users.service';

const optId = objectId.optional().nullable();

export const employeeInput = z.object({
  employeeCode: z.string().trim().min(1).max(30).optional(),
  firstName: z.string().trim().min(1).max(60),
  lastName: z.string().trim().max(60).default(''),
  displayName: z.string().trim().max(60).optional(),
  contactEmail: z.string().trim().toLowerCase().email().optional().nullable(),
  contactPhone: z.string().trim().max(20).optional().nullable(),
  emergencyContact: z.object({ name: z.string().max(80).optional(), relation: z.string().max(40).optional(), phone: z.string().max(20).optional() }).optional(),
  joiningDate: z.coerce.date().optional().nullable(),
  employmentType: z.enum(EMPLOYMENT_TYPES).default('full_time'),
  designation: z.string().trim().max(80).optional().nullable(),
  departmentId: optId,
  teamId: optId,
  reportingManagerId: optId,
  locationId: optId,
  shiftId: optId,
  probation: z.object({ endsOn: z.coerce.date().optional().nullable(), status: z.enum(['none', 'on_probation', 'confirmed', 'extended']).default('none') }).optional(),
  /** Create a sign-in account and send an invitation in the same step. */
  invite: z.object({ role: z.enum(['employee', 'manager', 'hr', 'admin', 'moderator', 'user']).default('employee') }).optional(),
});
export const employeeUpdate = employeeInput.partial().omit({ invite: true }).extend({
  status: z.enum(EMPLOYMENT_STATUSES).optional(),
  effectiveOn: z.coerce.date().optional(),
  note: z.string().max(300).optional(),
});
export const sensitiveInput = z.object({
  dateOfBirth: z.coerce.date().optional().nullable(),
  exitReason: z.string().max(500).optional().nullable(),
  bank: z
    .object({
      accountName: z.string().max(100).optional(),
      accountNumber: z.string().regex(/^\d{6,20}$/, '6 to 20 digits').optional(),
      ifsc: z.string().regex(/^[A-Z]{4}0[A-Z0-9]{6}$/, 'Example: HDFC0001234').optional(),
      bankName: z.string().max(80).optional(),
    })
    .optional(),
  tax: z.object({ pan: z.string().regex(/^[A-Z]{5}\d{4}[A-Z]$/, 'Example: ABCDE1234F').optional(), uan: z.string().regex(/^\d{12}$/).optional(), regime: z.enum(['old', 'new']).optional() }).optional(),
});

const ONBOARDING_TEMPLATE = [
  { key: 'account', title: 'Activate account and sign in', day: 1, ownerRole: 'employee' },
  { key: 'profile', title: 'Complete profile and photo', day: 1, ownerRole: 'employee' },
  { key: 'documents', title: 'Upload ID and address proof', day: 1, ownerRole: 'employee' },
  { key: 'bank', title: 'Add bank and tax details', day: 2, ownerRole: 'hr' },
  { key: 'policies', title: 'Read and acknowledge policies', day: 2, ownerRole: 'employee' },
  { key: 'shift', title: 'Assign shift and work location', day: 1, ownerRole: 'hr' },
  { key: 'buddy', title: 'Meet your buddy', day: 3, ownerRole: 'manager' },
  { key: 'equipment', title: 'Laptop and tools handed over', day: 1, ownerRole: 'manager' },
  { key: 'first_goals', title: 'First-month goals set', day: 5, ownerRole: 'manager' },
];
const OFFBOARDING_TEMPLATE = [
  { key: 'handover', title: 'Work and task handover', ownerRole: 'manager' },
  { key: 'assets', title: 'Return company assets', ownerRole: 'hr' },
  { key: 'documents', title: 'Exit documents signed', ownerRole: 'hr' },
  { key: 'final_payroll', title: 'Final payroll processed', ownerRole: 'hr' },
  { key: 'access', title: 'Access revoked on the last working day', ownerRole: 'hr' },
  { key: 'exit_interview', title: 'Exit interview', ownerRole: 'hr' },
];

const TRACKED: Record<string, 'transfer' | 'promotion' | 'manager_change' | 'status_change' | 'location_change'> = {
  departmentId: 'transfer',
  teamId: 'transfer',
  designation: 'promotion',
  reportingManagerId: 'manager_change',
  status: 'status_change',
  locationId: 'location_change',
};

@Injectable()
export class EmployeesService implements OnModuleInit {
  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly approvals: ApprovalEngine,
    private readonly notifications: NotificationsService,
    private readonly usersSvc: UsersService,
    private readonly sessions: SessionService,
    private readonly jobs: JobsService,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('EmployeeHistory') private readonly history: Model<any>,
    @InjectModel('Checklist') private readonly checklists: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('Team') private readonly teams: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Task') private readonly tasks: Model<any>,
    @InjectModel('Location') private readonly locations: Model<any>,
    @InjectModel('Shift') private readonly shifts: Model<any>,
  ) {}

  onModuleInit(): void {
    this.approvals.register('offboarding', {
      onApproved: async (a) => {
        const emp = await this.employees.findById(a.requestId).lean<any>();
        if (!emp || emp.status === 'exited') return;
        await this.employees.updateOne({ _id: emp._id }, { $set: { status: 'notice' } });
        await this.history.create({ organizationId: emp.organizationId, employeeId: emp._id, type: 'status_change', from: { status: emp.status }, to: { status: 'notice' }, note: 'Offboarding approved' });
        await this.checklists.updateOne({ organizationId: emp.organizationId, employeeId: emp._id, kind: 'offboarding', status: 'open' }, { $set: { approvalId: a._id } });
      },
      onRejected: async (a) => {
        await this.checklists.updateOne({ organizationId: a.organizationId, employeeId: a.requestId, kind: 'offboarding', status: 'open' }, { $set: { status: 'cancelled' } });
      },
      onCancelled: async (a) => {
        await this.checklists.updateOne({ organizationId: a.organizationId, employeeId: a.requestId, kind: 'offboarding', status: 'open' }, { $set: { status: 'cancelled' } });
      },
    });
  }

  // ------------------------------------------------------------------ presentation

  private async canSensitive(ctx: Ctx, employeeId: unknown, action: 'view' | 'edit' = 'view'): Promise<boolean> {
    return this.scope.covers(ctx, 'employees_sensitive', action, employeeId);
  }

  /** Sensitive fields appear only with employees_sensitive:view; otherwise a lock marker, never blanks. */
  async present(ctx: Ctx, e: any): Promise<any> {
    const out = serialize({ ...e, sensitive: undefined });
    if (await this.canSensitive(ctx, e._id)) {
      const s = e.sensitive ?? {};
      out.sensitive = {
        locked: false,
        dateOfBirth: s.dateOfBirth ?? null,
        exitReason: s.exitReason ?? null,
        bank: s.bank ? { accountName: s.bank.accountName, accountNumber: s.bank.accountLast4 ? mask('XXXXXX' + s.bank.accountLast4) : null, ifsc: s.bank.ifsc, bankName: s.bank.bankName } : null,
        tax: s.tax ? { pan: s.tax.panLast4 ? `••••••${s.tax.panLast4}` : null, uan: s.tax.uanEnc ? 'on file' : null, regime: s.tax.regime } : null,
      };
    } else {
      out.sensitive = { locked: true };
    }
    return out;
  }

  // ------------------------------------------------------------------ queries

  async list(ctx: Ctx, q: ListQuery & { departmentId?: string; teamId?: string; locationId?: string; managerId?: string; archived?: boolean }): Promise<Paged<any>> {
    const filter: Record<string, unknown> = await this.scope.filter(ctx, 'employees', 'view', '_id');
    filter.status = q.archived ? { $in: ['exited', 'archived'] } : q.status ? q.status : { $nin: ['exited', 'archived'] };
    if (q.departmentId) filter.departmentId = oid(q.departmentId);
    if (q.teamId) filter.teamId = oid(q.teamId);
    if (q.locationId) filter.locationId = oid(q.locationId);
    if (q.managerId) filter.reportingManagerId = oid(q.managerId);
    if (q.q) {
      const rx = new RegExp(escapeRegex(q.q), 'i');
      filter.$or = [{ firstName: rx }, { lastName: rx }, { displayName: rx }, { employeeCode: rx }, { contactEmail: rx }, { designation: rx }];
    }
    const [rows, total] = await Promise.all([
      this.employees
        .find(filter, { sensitive: 0 })
        .sort(sortSpec(q.sort, ['firstName', 'joiningDate', 'employeeCode', 'designation', 'createdAt'], { firstName: 1, lastName: 1 }))
        .skip((q.page - 1) * q.limit)
        .limit(q.limit)
        .lean<any[]>(),
      this.employees.countDocuments(filter),
    ]);
    const deptIds = [...new Set(rows.map((r) => String(r.departmentId ?? '')).filter(Boolean))];
    const depts = await this.departments.find({ _id: { $in: deptIds.map(oid) } }, { name: 1 }).lean<any[]>();
    const deptName = new Map(depts.map((d) => [String(d._id), d.name]));
    const items = rows.map((r) => ({ ...serialize(r), departmentName: deptName.get(String(r.departmentId)) ?? null, sensitive: { locked: true } }));
    return { items, page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    const e = await this.employees.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!e || !(await this.scope.covers(ctx, 'employees', 'view', e._id))) throw notFound('Employee');
    const [dept, team, manager, location, shift, user] = await Promise.all([
      e.departmentId ? this.departments.findById(e.departmentId, { name: 1 }).lean<any>() : null,
      e.teamId ? this.teams.findById(e.teamId, { name: 1 }).lean<any>() : null,
      e.reportingManagerId ? this.employees.findById(e.reportingManagerId, { firstName: 1, lastName: 1, designation: 1 }).lean<any>() : null,
      e.locationId ? this.locations.findById(e.locationId, { name: 1 }).lean<any>() : null,
      e.shiftId ? this.shifts.findById(e.shiftId, { name: 1, startTime: 1, endTime: 1 }).lean<any>() : null,
      e.userId ? this.users.findById(e.userId, { role: 1, status: 1, email: 1, lastLoginAt: 1 }).lean<any>() : null,
    ]);
    return {
      ...(await this.present(ctx, e)),
      department: serialize(dept),
      team: serialize(team),
      manager: manager ? { id: String(manager._id), name: `${manager.firstName} ${manager.lastName ?? ''}`.trim(), designation: manager.designation } : null,
      location: serialize(location),
      shift: serialize(shift),
      account: user ? serialize(user) : null,
      can: {
        edit: await this.scope.covers(ctx, 'employees', 'edit', e._id),
        editSensitive: await this.canSensitive(ctx, e._id, 'edit'),
        offboard: ctx.authz.can('employees', 'edit', 'organization'),
      },
    };
  }

  async historyOf(ctx: Ctx, id: string): Promise<any[]> {
    if (!(await this.scope.covers(ctx, 'employees', 'view', id))) throw notFound('Employee');
    return serialize(await this.history.find({ organizationId: ctx.orgOid, employeeId: oid(id) }).sort({ effectiveOn: -1, createdAt: -1 }).limit(200).lean());
  }

  // ------------------------------------------------------------------ create and update

  private async nextCode(orgId: Types.ObjectId): Promise<string> {
    const last = await this.employees.find({ organizationId: orgId, employeeCode: /^EMP-\d+$/ }, { employeeCode: 1 }).sort({ employeeCode: -1 }).limit(1).lean<any[]>();
    const n = last.length ? Number(last[0].employeeCode.slice(4)) + 1 : 1;
    return `EMP-${String(n).padStart(4, '0')}`;
  }

  private async validateRefs(ctx: Ctx, b: Record<string, any>, selfId?: string): Promise<void> {
    const checks: [string, Model<any>, string][] = [
      ['departmentId', this.departments, 'Department'],
      ['teamId', this.teams, 'Team'],
      ['reportingManagerId', this.employees, 'Manager'],
      ['locationId', this.locations, 'Location'],
      ['shiftId', this.shifts, 'Shift'],
    ];
    for (const [field, model, label] of checks) {
      if (b[field] && !(await model.exists({ _id: oid(b[field]), organizationId: ctx.orgOid }))) throw badRequest('REFERENCE_INVALID', `${label} not found.`, field);
    }
    if (selfId && b.reportingManagerId === selfId) throw badRequest('SELF_MANAGER', "Someone can't report to themselves.", 'reportingManagerId');
    if (selfId && b.reportingManagerId) {
      // Prevent reporting cycles (A -> B -> A).
      let cur: any = b.reportingManagerId;
      for (let i = 0; i < 20 && cur; i++) {
        if (String(cur) === selfId) throw badRequest('MANAGER_CYCLE', 'That would create a reporting loop.', 'reportingManagerId');
        cur = (await this.employees.findById(cur, { reportingManagerId: 1 }).lean<any>())?.reportingManagerId;
      }
    }
  }

  private ids(b: Record<string, any>): Record<string, any> {
    const out: Record<string, any> = { ...b };
    for (const k of ['departmentId', 'teamId', 'reportingManagerId', 'locationId', 'shiftId']) {
      if (k in out) out[k] = out[k] ? oid(out[k]) : null;
    }
    return out;
  }

  async create(ctx: Ctx, input: z.infer<typeof employeeInput>): Promise<any> {
    PermissionsService.require(ctx, 'employees', 'create', 'organization');
    await this.validateRefs(ctx, input);
    const code = input.employeeCode ?? (await this.nextCode(ctx.orgOid));
    if (await this.employees.exists({ organizationId: ctx.orgOid, employeeCode: code })) throw conflict('EMPLOYEE_CODE_TAKEN', `Employee ID ${code} is already used.`);
    if (input.contactEmail && (await this.employees.exists({ organizationId: ctx.orgOid, contactEmail: input.contactEmail }))) {
      throw conflict('EMPLOYEE_EMAIL_TAKEN', 'Another employee already uses this email.');
    }
    const { invite, ...rest } = input;
    const doc = await this.employees.create({ ...this.ids(rest), organizationId: ctx.orgOid, employeeCode: code, status: 'onboarding', createdBy: ctx.userOid });
    if (doc.teamId) await this.teams.updateOne({ _id: doc.teamId }, { $addToSet: { memberIds: doc._id } });
    await this.history.create({ organizationId: ctx.orgOid, employeeId: doc._id, type: 'joined', to: { departmentId: doc.departmentId, teamId: doc.teamId, designation: doc.designation }, effectiveOn: input.joiningDate ?? new Date(), byUserId: ctx.userOid });
    await this.checklists.create({
      organizationId: ctx.orgOid,
      employeeId: doc._id,
      kind: 'onboarding',
      items: ONBOARDING_TEMPLATE.map((i) => ({ ...i, done: false })),
    });
    await this.audit.record(ctx, { action: 'employee.create', resourceType: 'employee', resourceId: doc._id, changes: diff(null, rest as any, ['firstName', 'lastName', 'designation', 'departmentId', 'joiningDate']) });
    if (invite && input.contactEmail) {
      await this.usersSvc.create(ctx, { fullName: `${input.firstName} ${input.lastName}`.trim(), email: input.contactEmail, role: invite.role, employeeId: String(doc._id), sendInvitation: true });
    }
    return this.get(ctx, String(doc._id));
  }

  async update(ctx: Ctx, id: string, input: z.infer<typeof employeeUpdate>): Promise<any> {
    const before = await this.employees.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!before) throw notFound('Employee');
    if (!(await this.scope.covers(ctx, 'employees', 'edit', before._id))) throw forbidden('FORBIDDEN', "You don't have permission to edit this employee.");
    await this.validateRefs(ctx, input, id);
    const { effectiveOn, note, ...fields } = input;
    if (fields.employeeCode && fields.employeeCode !== before.employeeCode && (await this.employees.exists({ organizationId: ctx.orgOid, employeeCode: fields.employeeCode }))) {
      throw conflict('EMPLOYEE_CODE_TAKEN', `Employee ID ${fields.employeeCode} is already used.`);
    }
    if (fields.status === 'exited') throw badRequest('USE_OFFBOARDING', 'Use offboarding to record an exit.', 'status');
    const set = this.ids(fields);
    await this.employees.updateOne({ _id: before._id }, { $set: set });

    // History: one entry per tracked change, preserving where they were before (transfers keep reports correct).
    for (const [field, type] of Object.entries(TRACKED)) {
      if (field in set && String(set[field] ?? '') !== String(before[field] ?? '')) {
        await this.history.create({ organizationId: ctx.orgOid, employeeId: before._id, type, from: { [field]: before[field] ?? null }, to: { [field]: set[field] ?? null }, effectiveOn: effectiveOn ?? new Date(), note, byUserId: ctx.userOid });
      }
    }
    if ('teamId' in set && String(set.teamId ?? '') !== String(before.teamId ?? '')) {
      if (before.teamId) await this.teams.updateOne({ _id: before.teamId }, { $pull: { memberIds: before._id } });
      if (set.teamId) await this.teams.updateOne({ _id: set.teamId }, { $addToSet: { memberIds: before._id } });
    }
    if (fields.firstName || fields.lastName) {
      if (before.userId) await this.users.updateOne({ _id: before.userId }, { $set: { fullName: `${fields.firstName ?? before.firstName} ${fields.lastName ?? before.lastName ?? ''}`.trim() } });
    }
    await this.audit.record(ctx, { action: 'employee.update', resourceType: 'employee', resourceId: before._id, changes: diff(before, set) });
    return this.get(ctx, id);
  }

  /** Sensitive fields: separate permission; bank account and PAN encrypted at rest, shown masked. */
  async updateSensitive(ctx: Ctx, id: string, input: z.infer<typeof sensitiveInput>): Promise<any> {
    const e = await this.employees.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!e) throw notFound('Employee');
    if (!(await this.canSensitive(ctx, e._id, 'edit'))) throw forbidden('FORBIDDEN', "You don't have permission to edit sensitive details.");
    const key = secretOf(this.env, 'ENCRYPTION_KEY');
    const set: Record<string, unknown> = {};
    if (input.dateOfBirth !== undefined) set['sensitive.dateOfBirth'] = input.dateOfBirth;
    if (input.exitReason !== undefined) set['sensitive.exitReason'] = input.exitReason;
    if (input.bank) {
      if (input.bank.accountName !== undefined) set['sensitive.bank.accountName'] = input.bank.accountName;
      if (input.bank.ifsc !== undefined) set['sensitive.bank.ifsc'] = input.bank.ifsc;
      if (input.bank.bankName !== undefined) set['sensitive.bank.bankName'] = input.bank.bankName;
      if (input.bank.accountNumber) {
        set['sensitive.bank.accountNumberEnc'] = encrypt(input.bank.accountNumber, key);
        set['sensitive.bank.accountLast4'] = input.bank.accountNumber.slice(-4);
      }
    }
    if (input.tax) {
      if (input.tax.pan) {
        set['sensitive.tax.panEnc'] = encrypt(input.tax.pan, key);
        set['sensitive.tax.panLast4'] = input.tax.pan.slice(-4);
      }
      if (input.tax.uan) set['sensitive.tax.uanEnc'] = encrypt(input.tax.uan, key);
      if (input.tax.regime) set['sensitive.tax.regime'] = input.tax.regime;
    }
    await this.employees.updateOne({ _id: e._id }, { $set: set });
    // Only field names are audited, never values.
    await this.audit.record(ctx, { action: 'employee.sensitive_update', resourceType: 'employee', resourceId: e._id, changes: Object.fromEntries(Object.keys(set).map((k) => [k.replace(/Enc$/, ''), { from: '[redacted]', to: '[redacted]' }])) });
    return this.get(ctx, id);
  }

  // ------------------------------------------------------------------ onboarding and offboarding

  async checklist(ctx: Ctx, id: string, kind: 'onboarding' | 'offboarding'): Promise<any> {
    if (!(await this.scope.covers(ctx, 'employees', 'view', id))) throw notFound('Employee');
    const c = await this.checklists.findOne({ organizationId: ctx.orgOid, employeeId: oid(id), kind }).sort({ createdAt: -1 }).lean<any>();
    if (!c) return null;
    const done = c.items.filter((i: any) => i.done).length;
    return { ...serialize(c), progress: c.items.length ? Math.round((done * 100) / c.items.length) : 0 };
  }

  async toggleChecklistItem(ctx: Ctx, id: string, kind: 'onboarding' | 'offboarding', key: string, done: boolean): Promise<any> {
    const c = await this.checklists.findOne({ organizationId: ctx.orgOid, employeeId: oid(id), kind, status: 'open' }).lean<any>();
    if (!c) throw notFound('Checklist');
    const item = c.items.find((i: any) => i.key === key);
    if (!item) throw notFound('Checklist item');
    const isSelf = ctx.user.employeeId === id;
    const canEdit = await this.scope.covers(ctx, 'employees', 'edit', id);
    // Employees can tick their own items; everything else needs edit rights on the employee.
    if (!(canEdit || (isSelf && item.ownerRole === 'employee'))) throw forbidden('FORBIDDEN', "You can't update this item.");
    await this.checklists.updateOne({ _id: c._id, 'items.key': key }, { $set: { 'items.$.done': done, 'items.$.doneAt': done ? new Date() : null, 'items.$.doneBy': done ? ctx.userOid : null } });
    const updated = await this.checklists.findById(c._id).lean<any>();
    const complete = updated.items.every((i: any) => i.done);
    let celebrate = false;
    if (complete && kind === 'onboarding') {
      await this.checklists.updateOne({ _id: c._id }, { $set: { status: 'completed', completedAt: new Date() } });
      const emp = await this.employees.findById(id).lean<any>();
      if (emp?.status === 'onboarding') {
        const next = emp.probation?.status === 'on_probation' ? 'probation' : 'active';
        await this.employees.updateOne({ _id: emp._id }, { $set: { status: next } });
        await this.history.create({ organizationId: ctx.orgOid, employeeId: emp._id, type: 'status_change', from: { status: 'onboarding' }, to: { status: next }, note: 'Onboarding completed', byUserId: ctx.userOid });
      }
      celebrate = true; // the client plays one confetti burst, once
    }
    await this.audit.record(ctx, { action: `${kind}.item`, resourceType: 'employee', resourceId: id, changes: { [key]: { from: !done, to: done } } });
    return { ...(await this.checklist(ctx, id, kind)), celebrate };
  }

  /** Starts offboarding: records the last working day and asks for the required approval. */
  async startOffboarding(ctx: Ctx, id: string, input: { lastWorkingDay: Date; reason?: string; note?: string }): Promise<any> {
    PermissionsService.require(ctx, 'employees', 'edit', 'team');
    const e = await this.employees.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!e || !(await this.scope.covers(ctx, 'employees', 'edit', e._id))) throw notFound('Employee');
    if (['exited', 'archived'].includes(e.status)) throw conflict('ALREADY_EXITED', 'This employee has already left.');
    if (await this.checklists.exists({ organizationId: ctx.orgOid, employeeId: e._id, kind: 'offboarding', status: 'open' })) throw conflict('OFFBOARDING_OPEN', 'Offboarding is already in progress.');
    const openTasks = await this.tasks.countDocuments({ organizationId: ctx.orgOid, assigneeIds: e._id, status: { $nin: ['completed', 'cancelled'] } });
    const cl = await this.checklists.create({
      organizationId: ctx.orgOid,
      employeeId: e._id,
      kind: 'offboarding',
      lastWorkingDay: input.lastWorkingDay,
      items: OFFBOARDING_TEMPLATE.map((i) => ({ ...i, done: false })),
    });
    await this.employees.updateOne({ _id: e._id }, { $set: { exitDate: input.lastWorkingDay, ...(input.reason ? { 'sensitive.exitReason': input.reason } : {}) } });
    const approval = await this.approvals.start(ctx, {
      requestType: 'offboarding',
      requestId: e._id,
      subjectEmployeeId: e._id,
      title: `Offboarding: ${e.firstName} ${e.lastName ?? ''}`.trim(),
      summary: `Last working day ${input.lastWorkingDay.toISOString().slice(0, 10)}. ${openTasks} open task(s) to hand over.`,
      link: `/people/${id}`,
    });
    await this.checklists.updateOne({ _id: cl._id }, { $set: { approvalId: approval._id } });
    await this.audit.record(ctx, { action: 'employee.offboarding_start', resourceType: 'employee', resourceId: e._id, changes: { lastWorkingDay: { from: null, to: input.lastWorkingDay } } });
    return { checklist: await this.checklist(ctx, id, 'offboarding'), approvalId: String(approval._id), openTasks };
  }

  /**
   * Final step once the checklist is done and the last day has passed. Records are retained
   * (never deleted because an account is deactivated); access is revoked.
   */
  async completeOffboarding(ctx: Ctx, id: string): Promise<any> {
    PermissionsService.require(ctx, 'employees', 'edit', 'organization');
    const e = await this.employees.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!e) throw notFound('Employee');
    const c = await this.checklists.findOne({ organizationId: ctx.orgOid, employeeId: e._id, kind: 'offboarding', status: 'open' }).lean<any>();
    if (!c) throw conflict('NO_OFFBOARDING', 'Start offboarding first.');
    if (e.status !== 'notice') throw conflict('OFFBOARDING_NOT_APPROVED', 'Offboarding is waiting for approval.');
    const pending = c.items.filter((i: any) => !i.done).map((i: any) => i.title);
    if (pending.length) throw conflict('CHECKLIST_INCOMPLETE', `Finish these first: ${pending.join(', ')}.`);
    await this.exit(e, ctx.userOid);
    await this.checklists.updateOne({ _id: c._id }, { $set: { status: 'completed', completedAt: new Date() } });
    await this.audit.record(ctx, { action: 'employee.exit', resourceType: 'employee', resourceId: e._id });
    return this.get(ctx, id);
  }

  private async exit(e: any, by?: Types.ObjectId): Promise<void> {
    await this.employees.updateOne({ _id: e._id }, { $set: { status: 'exited' } });
    await this.history.create({ organizationId: e.organizationId, employeeId: e._id, type: 'exit', from: { status: e.status }, to: { status: 'exited' }, effectiveOn: e.exitDate ?? new Date(), byUserId: by });
    if (e.teamId) await this.teams.updateOne({ _id: e.teamId }, { $pull: { memberIds: e._id } });
    if (e.userId) {
      await this.users.updateOne({ _id: e.userId }, { $set: { status: 'inactive' } });
      await this.sessions.revokeAll(e.userId, 'employee_exit');
    }
  }

  /** Access is revoked at the appropriate time: daily, for approved exits whose last day has passed. */
  @Cron('15 0 * * *')
  async revokeAfterLastDay(): Promise<void> {
    await this.jobs.run('employees.exit_access', async () => {
      const due = await this.employees.find({ status: 'notice', exitDate: { $lt: new Date() } }).lean<any[]>();
      let n = 0;
      for (const e of due) {
        if (e.userId) {
          await this.users.updateOne({ _id: e.userId, status: 'active' }, { $set: { status: 'inactive' } });
          await this.sessions.revokeAll(e.userId, 'last_working_day');
          n++;
        }
      }
      return `${n} account(s) deactivated`;
    });
  }

  async archive(ctx: Ctx, id: string): Promise<any> {
    PermissionsService.require(ctx, 'employees', 'delete', 'organization');
    const e = await this.employees.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!e) throw notFound('Employee');
    if (e.status !== 'exited') throw conflict('NOT_EXITED', 'Only employees who have left can be archived.');
    await this.employees.updateOne({ _id: e._id }, { $set: { status: 'archived', archivedAt: new Date() } });
    await this.audit.record(ctx, { action: 'employee.archive', resourceType: 'employee', resourceId: e._id });
    return { archived: true };
  }

  /** Notifies for probation endings in the next 7 days (needs-attention + compliance calendar). */
  async probationEnding(orgId: Types.ObjectId, days = 7): Promise<any[]> {
    const until = new Date(Date.now() + days * 86400_000);
    return this.employees.find({ organizationId: orgId, 'probation.status': 'on_probation', 'probation.endsOn': { $lte: until } }, { firstName: 1, lastName: 1, probation: 1 }).lean();
  }

}
