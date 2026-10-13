import { Inject, Injectable, OnModuleInit } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { decrypt } from '../../common/crypto/crypto';
import { badRequest, conflict, dayString, forbidden, notFound, oid } from '../../common/http/validation';
import { addDays, daysBetween, OrgSettingsService, weekdayOf } from '../../common/org/org-settings.service';
import { APP_CONFIG } from '../../config/config.module';
import { AppEnv, secretOf } from '../../config/env.schema';
import { InjectModel, serialize } from '../../database/model';
import { ApprovalEngine } from '../approvals/approval.engine';
import { FilesService } from '../files/files.service';
import { NotificationsService } from '../notifications/notifications.service';
import { calculateLine, Component, lopDays, monthlyGross, r2, resolveComponents } from './payroll.calc';
import { renderPayslip } from './payslip.pdf';

const componentInput = z.object({
  code: z.string().trim().toUpperCase().regex(/^[A-Z][A-Z0-9_]{1,15}$/),
  name: z.string().trim().min(2).max(60),
  kind: z.enum(['earning', 'deduction']),
  calc: z.enum(['fixed', 'percent_of']).default('fixed'),
  amount: z.number().min(0).max(100_000_000).optional(),
  percent: z.number().min(0).max(100).optional(),
  of: z.string().optional(),
  taxable: z.boolean().default(true),
  prorate: z.boolean().default(true),
});
export const salaryInput = z.object({
  effectiveFrom: dayString,
  currency: z.string().length(3).default('INR'),
  components: z.array(componentInput).min(1).max(30),
  note: z.string().max(300).optional(),
});
export const statutoryInput = z.object({
  code: z.string().trim().toUpperCase().regex(/^[A-Z][A-Z0-9_]{1,20}$/),
  name: z.string().trim().max(80).optional(),
  kind: z.enum(['deduction', 'employer_contribution']),
  basis: z.enum(['component', 'gross', 'slab']),
  basisComponent: z.string().optional(),
  percent: z.number().min(0).max(100).optional(),
  cap: z.number().min(0).optional(),
  wageCeiling: z.number().min(0).optional(),
  slabs: z.array(z.object({ upTo: z.number().min(0), amount: z.number().min(0) })).max(20).optional(),
  active: z.boolean().default(false),
});

const PERIOD_RE = /^\d{4}-(0[1-9]|1[0-2])$/;

@Injectable()
export class PayrollService implements OnModuleInit {
  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly approvals: ApprovalEngine,
    private readonly files: FilesService,
    private readonly notifications: NotificationsService,
    private readonly orgSettings: OrgSettingsService,
    @InjectModel('SalaryStructure') private readonly salaries: Model<any>,
    @InjectModel('StatutoryRule') private readonly rules: Model<any>,
    @InjectModel('PayrollRun') private readonly runs: Model<any>,
    @InjectModel('PayrollLine') private readonly lines: Model<any>,
    @InjectModel('PayrollAdjustment') private readonly adjustments: Model<any>,
    @InjectModel('Payslip') private readonly payslips: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('Attendance') private readonly attendance: Model<any>,
    @InjectModel('LeaveRequest') private readonly leaves: Model<any>,
    @InjectModel('LeaveType') private readonly leaveTypes: Model<any>,
    @InjectModel('Holiday') private readonly holidays: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Organization') private readonly orgs: Model<any>,
  ) {}

  onModuleInit(): void {
    this.approvals.register('salary_change', {
      onApproved: async (a, actor) => this.activateSalary(a.requestId, actor?.userOid),
      onRejected: async (a) => void (await this.salaries.updateOne({ _id: a.requestId }, { $set: { status: 'rejected' } })),
      onCancelled: async (a) => void (await this.salaries.updateOne({ _id: a.requestId }, { $set: { status: 'draft' } })),
    });
    this.approvals.register('payroll', {
      onApproved: async (a, actor) => void (await this.runs.updateOne({ _id: a.requestId, status: 'pending_approval' }, { $set: { status: 'approved', stage: 'finalize', reviewedBy: actor?.userOid } })),
      onRejected: async (a) => void (await this.runs.updateOne({ _id: a.requestId, status: 'pending_approval' }, { $set: { status: 'calculated', stage: 'review' } })),
      onCancelled: async (a) => void (await this.runs.updateOne({ _id: a.requestId }, { $set: { status: 'calculated', stage: 'review' } })),
    });
    // Employees see only their own payslips; payroll viewers per their scope.
    this.files.registerAuthorizer('payslip', async (ctx, f) => String(f.ownerEmployeeId) === ctx.user.employeeId || (ctx.authz.can('payroll', 'view') && (await this.scope.covers(ctx, 'payroll', 'view', f.ownerEmployeeId))));
  }

  // ------------------------------------------------------------------ salary structures (versioned)

  async salaryHistory(ctx: Ctx, employeeId: string): Promise<any> {
    if (!(await this.scope.covers(ctx, 'salary', 'view', employeeId))) throw notFound('Employee');
    const versions = await this.salaries.find({ organizationId: ctx.orgOid, employeeId: oid(employeeId) }).sort({ version: -1 }).lean<any[]>();
    await this.audit.record(ctx, { action: 'salary.view', resourceType: 'employee', resourceId: employeeId });
    return { items: serialize(versions) };
  }

  async draftSalary(ctx: Ctx, employeeId: string, b: z.infer<typeof salaryInput>): Promise<any> {
    PermissionsService.require(ctx, 'salary', 'edit');
    if (!(await this.scope.covers(ctx, 'salary', 'edit', employeeId))) throw forbidden('FORBIDDEN', "You can't edit this employee's salary.");
    if (employeeId === ctx.user.employeeId) throw forbidden('SELF_SALARY', "You can't change your own salary.");
    const emp = await this.employees.findOne({ _id: oid(employeeId), organizationId: ctx.orgOid }).lean<any>();
    if (!emp) throw notFound('Employee');
    const codes = new Set<string>();
    for (const c of b.components) {
      if (codes.has(c.code)) throw badRequest('DUPLICATE_COMPONENT', `Component ${c.code} appears twice.`, 'components');
      codes.add(c.code);
      if (c.calc === 'fixed' && c.amount == null) throw badRequest('AMOUNT_REQUIRED', `Give ${c.name} an amount.`, 'components');
      if (c.calc === 'percent_of' && (c.percent == null || !c.of)) throw badRequest('PERCENT_REQUIRED', `${c.name} needs a percentage and a base component.`, 'components');
    }
    let gross: number;
    try {
      resolveComponents(b.components as Component[]);
      gross = monthlyGross(b.components as Component[]);
    } catch (e) {
      throw badRequest('COMPONENTS_INVALID', (e as Error).message, 'components');
    }
    const last = await this.salaries.findOne({ organizationId: ctx.orgOid, employeeId: emp._id }).sort({ version: -1 }).lean<any>();
    const doc = await this.salaries.create({ organizationId: ctx.orgOid, employeeId: emp._id, version: (last?.version ?? 0) + 1, effectiveFrom: b.effectiveFrom, currency: b.currency, components: b.components, monthlyGross: gross, annualCtc: r2(gross * 12), status: 'pending_approval', createdBy: ctx.userOid, note: b.note });
    const a = await this.approvals.start(ctx, {
      requestType: 'salary_change',
      requestId: doc._id,
      subjectEmployeeId: emp._id,
      title: `Compensation change: ${emp.firstName} ${emp.lastName ?? ''}`.trim(),
      summary: `Monthly gross ${b.currency} ${gross}${last?.monthlyGross ? ` (was ${last.monthlyGross})` : ''}, from ${b.effectiveFrom}`,
      amount: gross,
      link: `/people/${employeeId}`,
    });
    await this.salaries.updateOne({ _id: doc._id }, { $set: { approvalId: a._id } });
    await this.audit.record(ctx, { action: 'salary.propose', resourceType: 'employee', resourceId: employeeId, changes: { monthlyGross: { from: last?.monthlyGross ?? null, to: gross } } });
    return serialize(await this.salaries.findById(doc._id).lean());
  }

  /** Approved: becomes the active version from its date; the previous one ends the day before. */
  private async activateSalary(id: Types.ObjectId, by?: Types.ObjectId): Promise<void> {
    const s = await this.salaries.findOneAndUpdate({ _id: id, status: 'pending_approval' }, { $set: { status: 'approved', approvedBy: by } }, { new: true }).lean<any>();
    if (!s) return;
    await this.salaries.updateMany({ organizationId: s.organizationId, employeeId: s.employeeId, status: 'approved', _id: { $ne: s._id }, effectiveFrom: { $gte: s.effectiveFrom } }, { $set: { status: 'superseded' } });
    await this.salaries.updateMany({ organizationId: s.organizationId, employeeId: s.employeeId, status: 'approved', _id: { $ne: s._id }, effectiveFrom: { $lt: s.effectiveFrom }, $or: [{ effectiveTo: null }, { effectiveTo: { $gte: s.effectiveFrom } }] }, { $set: { effectiveTo: addDays(s.effectiveFrom, -1) } });
    await this.employees.updateOne({ _id: s.employeeId }, { $set: { salaryStructureId: s._id } });
  }

  private async salaryFor(orgId: Types.ObjectId, employeeId: Types.ObjectId, periodEnd: string): Promise<any | null> {
    return this.salaries.findOne({ organizationId: orgId, employeeId, status: 'approved', effectiveFrom: { $lte: periodEnd }, $or: [{ effectiveTo: null }, { effectiveTo: { $exists: false } }, { effectiveTo: { $gte: periodEnd } }] }).sort({ effectiveFrom: -1 }).lean();
  }

  // ------------------------------------------------------------------ statutory rules (configured, validated)

  async listRules(ctx: Ctx): Promise<any[]> {
    PermissionsService.require(ctx, 'payroll', 'view');
    return serialize(await this.rules.find({ organizationId: ctx.orgOid }).sort({ code: 1 }).lean());
  }

  async saveRule(ctx: Ctx, b: z.infer<typeof statutoryInput>): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'configure', 'organization');
    // Any change invalidates the previous validation: someone must validate again before it applies.
    const doc = await this.rules.findOneAndUpdate({ organizationId: ctx.orgOid, code: b.code }, { $set: { ...b, active: false, validatedBy: null, validatedAt: null } }, { upsert: true, new: true }).lean();
    await this.audit.record(ctx, { action: 'payroll.rule_save', resourceType: 'statutory_rule', resourceId: b.code });
    return serialize(doc);
  }

  async validateRule(ctx: Ctx, code: string): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'configure', 'organization');
    const doc = await this.rules.findOneAndUpdate({ organizationId: ctx.orgOid, code }, { $set: { active: true, validatedBy: ctx.userOid, validatedAt: new Date() } }, { new: true }).lean();
    if (!doc) throw notFound('Rule');
    await this.audit.record(ctx, { action: 'payroll.rule_validate', resourceType: 'statutory_rule', resourceId: code });
    return serialize(doc);
  }

  // ------------------------------------------------------------------ runs

  async listRuns(ctx: Ctx): Promise<any[]> {
    PermissionsService.require(ctx, 'payroll', 'view', 'organization');
    return serialize(await this.runs.find({ organizationId: ctx.orgOid }).sort({ periodStart: -1 }).limit(36).lean());
  }

  async openRun(ctx: Ctx, period: string): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'manage', 'organization');
    if (!PERIOD_RE.test(period)) throw badRequest('PERIOD_INVALID', 'Use YYYY-MM.', 'period');
    const [y, m] = period.split('-').map(Number);
    const start = `${period}-01`;
    const end = `${period}-${String(new Date(Date.UTC(y, m, 0)).getUTCDate()).padStart(2, '0')}`;
    if (await this.runs.exists({ organizationId: ctx.orgOid, periodStart: start, status: { $ne: 'cancelled' } })) throw conflict('RUN_EXISTS', `Payroll for ${period} already exists.`);
    const label = new Date(Date.UTC(y, m - 1, 1)).toLocaleString('en-IN', { month: 'short', year: 'numeric', timeZone: 'UTC' });
    const run = await this.runs.create({ organizationId: ctx.orgOid, periodStart: start, periodEnd: end, label, stage: 'collect', status: 'open', preparedBy: ctx.userOid });
    await this.audit.record(ctx, { action: 'payroll.open', resourceType: 'payroll_run', resourceId: run._id });
    return serialize(run.toObject());
  }

  private async runFor(ctx: Ctx, id: string): Promise<any> {
    const run = await this.runs.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!run) throw notFound('Payroll run');
    return run;
  }

  private assertEditable(run: any): void {
    if (['finalized', 'paid'].includes(run.status)) throw conflict('PAYROLL_LOCKED', 'This payroll is finalized and locked. Use an adjustment or reversal.');
    if (['pending_approval', 'approved'].includes(run.status)) throw conflict('PAYROLL_IN_APPROVAL', 'This payroll is in approval. Withdraw it to change it.');
  }

  /** Collect approved attendance, leave and compensation, calculate every line, flag anomalies. */
  async calculate(ctx: Ctx, id: string): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'manage', 'organization');
    const run = await this.runFor(ctx, id);
    this.assertEditable(run);
    const org = await this.orgSettings.get(ctx.orgOid);
    const basis: string = org.settings?.payroll?.lopBasis ?? 'working_days';
    const version = (run.calculationVersion ?? 0) + 1;
    const days = daysBetween(run.periodStart, run.periodEnd);
    const working = org.workingDays ?? [1, 2, 3, 4, 5, 6];
    const hols = new Set((await this.holidays.find({ organizationId: ctx.orgOid, date: { $gte: run.periodStart, $lte: run.periodEnd }, locationIds: { $size: 0 }, optional: { $ne: true } }, { date: 1 }).lean<any[]>()).map((h) => h.date));
    const workingDays = days.filter((d) => working.includes(weekdayOf(d)) && !hols.has(d)).length;
    const periodDays = basis === 'calendar_days' ? days.length : basis === 'fixed_30' ? 30 : workingDays;

    const rules = await this.rules.find({ organizationId: ctx.orgOid, active: true, validatedAt: { $ne: null } }).lean<any[]>();
    const unpaidTypes = new Set((await this.leaveTypes.find({ organizationId: ctx.orgOid, paid: false }, { _id: 1 }).lean<any[]>()).map((t) => String(t._id)));
    const emps = await this.employees.find({ organizationId: ctx.orgOid, status: { $in: ['active', 'probation', 'notice', 'onboarding'] }, $or: [{ joiningDate: null }, { joiningDate: { $lte: new Date(`${run.periodEnd}T23:59:59Z`) } }] }).lean<any[]>();
    const prevRun = await this.runs.findOne({ organizationId: ctx.orgOid, periodStart: { $lt: run.periodStart }, status: { $in: ['finalized', 'paid'] } }).sort({ periodStart: -1 }).lean<any>();
    const prevLines = prevRun ? await this.lines.find({ runId: prevRun._id }, { employeeId: 1, net: 1 }).lean<any[]>() : [];
    const prevNet = new Map(prevLines.map((l) => [String(l.employeeId), l.net]));
    const bankSeen = new Map<string, string[]>();
    const attendanceEnabled = this.orgSettings.features(org).attendance !== false;

    let totals = { employees: 0, gross: 0, deductions: 0, net: 0, employerCost: 0 };
    let anomalyCount = 0;
    await this.lines.deleteMany({ runId: run._id });

    for (const e of emps) {
      const salary = await this.salaryFor(ctx.orgOid, e._id, run.periodEnd);
      const anomalies: { code: string; message: string; severity: string }[] = [];
      const recs = await this.attendance.find({ organizationId: ctx.orgOid, employeeId: e._id, workDate: { $gte: run.periodStart, $lte: run.periodEnd } }, { status: 1, overtimeMinutes: 1 }).lean<any[]>();
      const leaveReqs = await this.leaves.find({ organizationId: ctx.orgOid, employeeId: e._id, status: 'approved', startDate: { $lte: run.periodEnd }, endDate: { $gte: run.periodStart } }).lean<any[]>();
      const count = (s: string) => recs.filter((r) => r.status === s).length;
      let unpaid = 0;
      let paidLeave = 0;
      for (const l of leaveReqs) {
        const overlap = daysBetween(l.startDate > run.periodStart ? l.startDate : run.periodStart, l.endDate < run.periodEnd ? l.endDate : run.periodEnd).filter((d) => working.includes(weekdayOf(d)) && !hols.has(d)).length * (l.partialDay !== 'none' ? 0.5 : 1);
        if (unpaidTypes.has(String(l.leaveTypeId))) unpaid += overlap;
        else paidLeave += overlap;
      }
      // Joiners and leavers mid-period: days outside employment are unpaid.
      let outside = 0;
      if (e.joiningDate) outside += days.filter((d) => d < new Date(e.joiningDate).toISOString().slice(0, 10) && working.includes(weekdayOf(d)) && !hols.has(d)).length;
      if (e.exitDate) outside += days.filter((d) => d > new Date(e.exitDate).toISOString().slice(0, 10) && working.includes(weekdayOf(d)) && !hols.has(d)).length;
      const lop = r2(lopDays({ absentDays: count('absent'), unpaidLeaveDays: unpaid, halfDays: count('half_day') }) + outside);
      const payable = Math.max(0, periodDays - lop);
      const inputs = { periodDays, payableDays: payable, lopDays: lop, presentDays: count('present') + count('late'), paidLeaveDays: paidLeave, unpaidLeaveDays: unpaid, absentDays: count('absent'), overtimeMinutes: recs.reduce((a, r) => a + (r.overtimeMinutes ?? 0), 0) };

      if (!salary) {
        anomalies.push({ code: 'NO_SALARY', message: 'No approved salary structure for this period.', severity: 'high' });
        await this.lines.create({ organizationId: ctx.orgOid, runId: run._id, employeeId: e._id, inputs, earnings: [], deductions: [], employerContributions: [], gross: 0, totalDeductions: 0, net: 0, anomalies, previousNet: prevNet.get(String(e._id)), calculationVersion: version, paymentStatus: 'on_hold' });
        anomalyCount++;
        continue;
      }
      const adj = await this.adjustments.find({ organizationId: ctx.orgOid, employeeId: e._id, status: 'pending', $or: [{ appliesToRunId: run._id }, { appliesToRunId: null }] }).lean<any[]>();
      const line = calculateLine(salary.components, { periodDays, payableDays: payable, adjustments: adj.map((a) => ({ amount: a.amount, reason: a.reason })) }, rules);
      if (org.settings?.payroll?.roundNetPay !== false) line.net = Math.round(line.net);

      if (line.net < 0) anomalies.push({ code: 'NEGATIVE_NET', message: `Net pay is negative (${line.net}).`, severity: 'high' });
      const prev = prevNet.get(String(e._id));
      if (prev && Math.abs(line.net - prev) / prev > 0.2) anomalies.push({ code: 'SUDDEN_CHANGE', message: `Net pay changed ${Math.round(((line.net - prev) / prev) * 100)}% from last period (${prev} → ${line.net}).`, severity: 'medium' });
      if (attendanceEnabled && !recs.length && !leaveReqs.length && !e.joiningDate?.toISOString?.().startsWith(run.periodStart.slice(0, 7))) anomalies.push({ code: 'MISSING_ATTENDANCE', message: 'No attendance recorded this period.', severity: 'medium' });
      const bank = e.sensitive?.bank;
      if (!bank?.accountLast4) anomalies.push({ code: 'NO_BANK_DETAILS', message: 'No bank account on file.', severity: 'medium' });
      else {
        const k = `${bank.ifsc}:${bank.accountLast4}:${(bank.accountName ?? '').toLowerCase()}`;
        bankSeen.set(k, [...(bankSeen.get(k) ?? []), String(e._id)]);
      }
      const l = await this.lines.create({ organizationId: ctx.orgOid, runId: run._id, employeeId: e._id, salaryStructureId: salary._id, salaryVersion: salary.version, inputs, ...line, anomalies, previousNet: prev, calculationVersion: version });
      if (anomalies.length) anomalyCount++;
      totals = {
        employees: totals.employees + 1,
        gross: r2(totals.gross + line.gross),
        deductions: r2(totals.deductions + line.totalDeductions),
        net: r2(totals.net + line.net),
        employerCost: r2(totals.employerCost + line.gross + line.employerContributions.reduce((a, c) => a + c.amount, 0)),
      };
      void l;
    }
    // Duplicate bank details across employees.
    for (const [, ids] of bankSeen) {
      if (ids.length < 2) continue;
      await this.lines.updateMany({ runId: run._id, employeeId: { $in: ids.map(oid) } }, { $push: { anomalies: { code: 'DUPLICATE_BANK', message: `Same bank details as ${ids.length - 1} other employee(s).`, severity: 'high' } } });
      anomalyCount += ids.length;
    }
    await this.runs.updateOne({ _id: run._id }, { $set: { stage: 'review', status: 'calculated', calculationVersion: version, totals, anomalies: anomalyCount } });
    await this.audit.record(ctx, { action: 'payroll.calculate', resourceType: 'payroll_run', resourceId: run._id, changes: { calculationVersion: { from: run.calculationVersion ?? 0, to: version }, net: { from: run.totals?.net ?? null, to: totals.net } } });
    return this.get(ctx, id);
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'view', 'organization');
    const run = await this.runFor(ctx, id);
    const prev = await this.runs.findOne({ organizationId: ctx.orgOid, periodStart: { $lt: run.periodStart }, status: { $in: ['finalized', 'paid'] } }).sort({ periodStart: -1 }).lean<any>();
    return { ...serialize(run), previous: prev ? { id: String(prev._id), label: prev.label, totals: prev.totals } : null };
  }

  async linesOf(ctx: Ctx, id: string, onlyAnomalies = false): Promise<any[]> {
    PermissionsService.require(ctx, 'payroll', 'view', 'organization');
    await this.runFor(ctx, id);
    const filter: Record<string, unknown> = { runId: oid(id) };
    if (onlyAnomalies) filter['anomalies.0'] = { $exists: true };
    const rows = await this.lines.find(filter).lean<any[]>();
    const emps = await this.employees.find({ _id: { $in: rows.map((r) => r.employeeId) } }, { firstName: 1, lastName: 1, employeeCode: 1, departmentId: 1 }).lean<any[]>();
    const e = new Map(emps.map((x) => [String(x._id), x]));
    return serialize(rows)
      .map((r: any) => ({ ...r, employeeName: `${e.get(r.employeeId)?.firstName ?? ''} ${e.get(r.employeeId)?.lastName ?? ''}`.trim(), employeeCode: e.get(r.employeeId)?.employeeCode, diff: r.previousNet != null ? r2(r.net - r.previousNet) : null }))
      .sort((a: any, b: any) => (b.anomalies?.length ?? 0) - (a.anomalies?.length ?? 0) || a.employeeName.localeCompare(b.employeeName));
  }

  /** Sends the calculated run for approval: preparer -> reviewer -> final approver (self-approval blocked). */
  async submit(ctx: Ctx, id: string): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'manage', 'organization');
    const run = await this.runFor(ctx, id);
    if (run.status !== 'calculated') throw conflict('PAYROLL_NOT_CALCULATED', 'Calculate the payroll before sending it for approval.');
    const blocking = await this.lines.countDocuments({ runId: run._id, 'anomalies.severity': 'high' });
    const r = await this.runs.updateOne({ _id: run._id, status: 'calculated' }, { $set: { status: 'pending_approval', stage: 'approve' } });
    if (!r.modifiedCount) throw conflict('PAYROLL_CHANGED', 'The payroll changed. Refresh and try again.');
    const a = await this.approvals.start(ctx, {
      requestType: 'payroll',
      requestId: run._id,
      title: `Payroll ${run.label}`,
      summary: `${run.totals?.employees ?? 0} employees · net ${run.totals?.net ?? 0}${blocking ? ` · ${blocking} high-severity anomalies` : ''}`,
      amount: run.totals?.net,
      link: `/money/payroll/${id}`,
    });
    await this.runs.updateOne({ _id: run._id }, { $set: { approvalId: a._id } });
    await this.audit.record(ctx, { action: 'payroll.submit', resourceType: 'payroll_run', resourceId: id });
    return this.get(ctx, id);
  }

  /**
   * Finalize: only an approved run; locks it and generates payslips. Never optimistic:
   * the controller requires re-authentication and the client shows a pending state until this returns.
   */
  async finalize(ctx: Ctx, id: string): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'manage', 'organization');
    const run = await this.runFor(ctx, id);
    if (run.status !== 'approved') throw conflict('PAYROLL_NOT_APPROVED', 'Payroll must be approved before it can be finalized.');
    const r = await this.runs.updateOne({ _id: run._id, status: 'approved' }, { $set: { status: 'finalized', stage: 'pay', finalizedBy: ctx.userOid, finalizedAt: new Date(), lockedAt: new Date() } });
    if (!r.modifiedCount) throw conflict('PAYROLL_CHANGED', 'This payroll was already finalized.');
    await this.adjustments.updateMany({ organizationId: ctx.orgOid, status: 'pending', $or: [{ appliesToRunId: run._id }, { appliesToRunId: null }], employeeId: { $in: await this.lines.distinct('employeeId', { runId: run._id }) } }, { $set: { status: 'applied', appliesToRunId: run._id } });
    const generated = await this.generatePayslips(ctx, run);
    await this.audit.record(ctx, { action: 'payroll.finalize', resourceType: 'payroll_run', resourceId: id, changes: { payslips: { from: null, to: generated } } });
    const payrollPeople = await this.users.find({ organizationId: ctx.orgOid, role: { $in: ['super_admin'] }, status: 'active' }, { _id: 1 }).lean<any[]>();
    await this.notifications.notify(ctx.orgOid, payrollPeople.map((u) => u._id), { event: 'payroll_finalized', title: `Payroll ${run.label} finalized`, body: `${generated} payslips published.`, link: `/money/payroll/${id}` });
    return this.get(ctx, id);
  }

  private async generatePayslips(ctx: Ctx, run: any): Promise<number> {
    const org = await this.orgs.findById(ctx.orgOid).lean<any>();
    const rows = await this.lines.find({ runId: run._id, paymentStatus: { $ne: 'on_hold' } }).lean<any[]>();
    let n = 0;
    for (const l of rows) {
      if (await this.payslips.exists({ runId: run._id, employeeId: l.employeeId })) continue;
      const e = await this.employees.findById(l.employeeId).lean<any>();
      const dept = e?.departmentId ? await this.departments.findById(e.departmentId, { name: 1 }).lean<any>() : null;
      const ref = `${run.periodStart.slice(0, 7)}-${e?.employeeCode}`;
      const pdf = await renderPayslip({
        organization: { name: org.name, legalName: org.legalName, address: org.offices?.[0]?.address },
        employee: { name: `${e.firstName} ${e.lastName ?? ''}`.trim(), code: e.employeeCode, designation: e.designation, department: dept?.name, bankLast4: e.sensitive?.bank?.accountLast4, panLast4: e.sensitive?.tax?.panLast4 },
        period: run.label,
        currency: org.currency ?? 'INR',
        inputs: { periodDays: l.inputs.periodDays, payableDays: l.inputs.payableDays, lopDays: l.inputs.lopDays },
        earnings: l.earnings,
        deductions: l.deductions,
        gross: l.gross,
        totalDeductions: l.totalDeductions,
        net: l.net,
        reference: ref,
      });
      const slip = await this.payslips.create({ organizationId: ctx.orgOid, runId: run._id, lineId: l._id, employeeId: l.employeeId, period: run.periodStart.slice(0, 7), net: l.net, publishedAt: new Date() });
      const file = await this.files.storeGenerated(ctx.orgOid, { buffer: pdf, name: `Payslip-${ref}.pdf`, mimeType: 'application/pdf', purpose: 'payslip', ownerEmployeeId: l.employeeId, linked: { type: 'payslip', id: slip._id }, uploadedBy: ctx.userOid });
      await this.payslips.updateOne({ _id: slip._id }, { $set: { fileId: file._id } });
      await this.lines.updateOne({ _id: l._id }, { $set: { payslipId: slip._id } });
      const u = await this.users.findOne({ organizationId: ctx.orgOid, employeeId: l.employeeId }, { _id: 1 }).lean<any>();
      if (u) await this.notifications.notify(ctx.orgOid, [u._id], { event: 'payslip_available', title: `Your payslip for ${run.label} is ready`, link: '/money/payslips' });
      n++;
    }
    return n;
  }

  /** Payment status is updated only with a payment reference per line (verified process). */
  async recordPayments(ctx: Ctx, id: string, payments: { lineId: string; status: 'paid' | 'failed'; paymentReference: string }[]): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'manage', 'organization');
    const run = await this.runFor(ctx, id);
    if (!['finalized', 'paid'].includes(run.status)) throw conflict('PAYROLL_NOT_FINALIZED', 'Finalize the payroll before recording payments.');
    for (const p of payments) {
      await this.lines.updateOne({ _id: oid(p.lineId), runId: run._id }, { $set: { paymentStatus: p.status, paymentReference: p.paymentReference } });
    }
    const unpaid = await this.lines.countDocuments({ runId: run._id, paymentStatus: { $in: ['pending', 'failed'] } });
    if (!unpaid) await this.runs.updateOne({ _id: run._id }, { $set: { status: 'paid', paidAt: new Date() } });
    await this.audit.record(ctx, { action: 'payroll.payments', resourceType: 'payroll_run', resourceId: id, changes: { recorded: { from: null, to: payments.length } } });
    return this.get(ctx, id);
  }

  /** Corrections after finalization: audited adjustment or reversal carried into the next run. */
  async adjust(ctx: Ctx, b: { runId: string; employeeId: string; kind: 'adjustment' | 'reversal'; amount: number; reason: string }): Promise<any> {
    PermissionsService.require(ctx, 'payroll', 'manage', 'organization');
    const run = await this.runFor(ctx, b.runId);
    if (!['finalized', 'paid'].includes(run.status)) throw conflict('PAYROLL_NOT_LOCKED', 'Only finalized payroll needs an adjustment. Recalculate this run instead.');
    const line = await this.lines.findOne({ runId: run._id, employeeId: oid(b.employeeId) }).lean<any>();
    if (!line) throw notFound('Payroll line');
    const amount = b.kind === 'reversal' ? -Math.abs(b.amount) : b.amount;
    const adj = await this.adjustments.create({ organizationId: ctx.orgOid, runId: run._id, lineId: line._id, employeeId: line.employeeId, kind: b.kind, amount: r2(amount), reason: b.reason, createdBy: ctx.userOid });
    await this.audit.record(ctx, { action: `payroll.${b.kind}`, resourceType: 'payroll_run', resourceId: b.runId, changes: { amount: { from: null, to: amount }, reason: { from: null, to: b.reason } } });
    return serialize(adj.toObject());
  }

  /** Bank transfer file. Decrypts account numbers only here; every export is audited. */
  async bankFile(ctx: Ctx, id: string): Promise<string> {
    PermissionsService.require(ctx, 'payroll', 'export', 'organization');
    const run = await this.runFor(ctx, id);
    if (!['finalized', 'paid'].includes(run.status)) throw conflict('PAYROLL_NOT_FINALIZED', 'Finalize the payroll first.');
    const rows = await this.lines.find({ runId: run._id, paymentStatus: { $ne: 'on_hold' }, net: { $gt: 0 } }).lean<any[]>();
    const key = secretOf(this.env, 'ENCRYPTION_KEY');
    const out = ['employee_code,name,account_name,account_number,ifsc,amount,reference'];
    for (const l of rows) {
      const e = await this.employees.findById(l.employeeId).lean<any>();
      const b = e?.sensitive?.bank;
      const acct = b?.accountNumberEnc ? decrypt(b.accountNumberEnc, key) : '';
      const cell = (s: unknown) => `"${String(s ?? '').replace(/"/g, '""')}"`;
      out.push([e.employeeCode, `${e.firstName} ${e.lastName ?? ''}`.trim(), b?.accountName, acct, b?.ifsc, l.net.toFixed(2), `SAL-${run.periodStart.slice(0, 7)}-${e.employeeCode}`].map(cell).join(','));
    }
    await this.audit.record(ctx, { action: 'payroll.bank_export', resourceType: 'payroll_run', resourceId: id, changes: { rows: { from: null, to: rows.length } } });
    return out.join('\n');
  }

  // ------------------------------------------------------------------ payslips

  async myPayslips(ctx: Ctx, employeeId?: string): Promise<any[]> {
    const id = employeeId ?? ctx.user.employeeId;
    if (!id) return [];
    if (id !== ctx.user.employeeId && !(await this.scope.covers(ctx, 'payroll', 'view', id))) throw notFound('Employee');
    const rows = await this.payslips.find({ organizationId: ctx.orgOid, employeeId: oid(id) }).sort({ period: -1 }).limit(36).lean<any[]>();
    return serialize(rows);
  }

  async markViewed(ctx: Ctx, id: string): Promise<void> {
    await this.payslips.updateOne({ _id: oid(id), employeeId: ctx.employeeOid, viewedAt: null }, { $set: { viewedAt: new Date() } });
  }
}
