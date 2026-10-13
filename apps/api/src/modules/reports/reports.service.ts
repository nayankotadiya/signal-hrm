import { Injectable } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { Action, Resource } from '../../common/authz/catalog';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, dayString, notFound, objectId, oid } from '../../common/http/validation';
import { addDays, localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { JobsService } from '../system/jobs.service';

export const reportFilters = z.object({
  from: dayString.optional(),
  to: dayString.optional(),
  departmentId: objectId.optional(),
  teamId: objectId.optional(),
  employeeId: objectId.optional(),
  locationId: objectId.optional(),
  status: z.string().max(40).optional(),
});
export type ReportFilters = z.infer<typeof reportFilters>;

export interface Column {
  key: string;
  label: string;
  type?: 'text' | 'number' | 'money' | 'date' | 'percent' | 'minutes';
}
export interface ReportResult {
  key: string;
  title: string;
  category: string;
  chart: 'line' | 'bar' | 'stacked' | 'doughnut' | 'funnel' | 'heatmap' | 'timeline' | 'table';
  columns: Column[];
  rows: Record<string, unknown>[];
  /** Plain-language summary for screen readers and the report header. */
  summary: string;
  /** For charts: which column is the label and which are values. */
  x?: string;
  y?: string[];
  generatedAt: string;
}

interface Def {
  title: string;
  category: string;
  resource: Resource;
  action?: Action;
  /** Report needs organization scope (e.g. payroll, system). */
  orgOnly?: boolean;
  run: (ctx: Ctx, f: Required<Pick<ReportFilters, 'from' | 'to'>> & ReportFilters, emp: Types.ObjectId[] | null) => Promise<Omit<ReportResult, 'key' | 'title' | 'category' | 'generatedAt'>>;
}

const pct = (a: number, b: number): number => (b ? Math.round((a * 1000) / b) / 10 : 0);
const r2 = (n: number): number => Math.round(n * 100) / 100;

@Injectable()
export class ReportsService {
  private defs: Record<string, Def>;

  constructor(
    private readonly scope: ScopeService,
    private readonly audit: AuditService,
    private readonly orgSettings: OrgSettingsService,
    private readonly jobs: JobsService,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('EmployeeHistory') private readonly history: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('Team') private readonly teams: Model<any>,
    @InjectModel('Checklist') private readonly checklists: Model<any>,
    @InjectModel('Document') private readonly documents: Model<any>,
    @InjectModel('Attendance') private readonly attendance: Model<any>,
    @InjectModel('AttendanceCorrection') private readonly corrections: Model<any>,
    @InjectModel('AttendanceFlag') private readonly flags: Model<any>,
    @InjectModel('LeaveRequest') private readonly leaves: Model<any>,
    @InjectModel('LeaveType') private readonly leaveTypes: Model<any>,
    @InjectModel('LeaveBalance') private readonly balances: Model<any>,
    @InjectModel('Expense') private readonly expenses: Model<any>,
    @InjectModel('ExpenseCategory') private readonly categories: Model<any>,
    @InjectModel('TravelRequest') private readonly travel: Model<any>,
    @InjectModel('PayrollRun') private readonly runs: Model<any>,
    @InjectModel('PayrollLine') private readonly lines: Model<any>,
    @InjectModel('PayrollAdjustment') private readonly adjustments: Model<any>,
    @InjectModel('Payslip') private readonly payslips: Model<any>,
    @InjectModel('Task') private readonly tasks: Model<any>,
    @InjectModel('Lead') private readonly leads: Model<any>,
    @InjectModel('Meeting') private readonly meetings: Model<any>,
    @InjectModel('RequestMetric') private readonly metrics: Model<any>,
    @InjectModel('ErrorLog') private readonly errors: Model<any>,
    @InjectModel('LoginEvent') private readonly logins: Model<any>,
    @InjectModel('BackupRecord') private readonly backups: Model<any>,
    @InjectModel('JobRun') private readonly jobRuns: Model<any>,
    @InjectModel('NotificationDelivery') private readonly deliveries: Model<any>,
    @InjectModel('AuditLog') private readonly auditLogs: Model<any>,
    @InjectModel('File') private readonly files: Model<any>,
    @InjectModel('SavedReport') private readonly saved: Model<any>,
  ) {
    this.defs = this.build();
  }

  // ------------------------------------------------------------------ helpers

  private async names(ids: unknown[]): Promise<Map<string, string>> {
    const rows = await this.employees.find({ _id: { $in: ids.filter(Boolean) } }, { firstName: 1, lastName: 1 }).lean<any[]>();
    return new Map(rows.map((e) => [String(e._id), `${e.firstName} ${e.lastName ?? ''}`.trim()]));
  }

  private async deptNames(orgId: Types.ObjectId): Promise<Map<string, string>> {
    const rows = await this.departments.find({ organizationId: orgId }, { name: 1 }).lean<any[]>();
    return new Map(rows.map((d) => [String(d._id), d.name]));
  }

  /** Employees the caller may report on for this resource, narrowed by the global filters. */
  private async employeeSet(ctx: Ctx, resource: Resource, action: Action, f: ReportFilters): Promise<Types.ObjectId[] | null> {
    const s = PermissionsService.require(ctx, resource, action);
    let ids = await this.scope.employeeIds(ctx, s === 'own' ? 'own' : s, resource, action);
    if (f.departmentId || f.teamId || f.locationId || f.employeeId) {
      const q: Record<string, unknown> = { organizationId: ctx.orgOid };
      if (f.departmentId) q.departmentId = oid(f.departmentId);
      if (f.teamId) q.teamId = oid(f.teamId);
      if (f.locationId) q.locationId = oid(f.locationId);
      if (f.employeeId) q._id = oid(f.employeeId);
      if (ids) q._id = f.employeeId ? { $in: ids.filter((i) => String(i) === f.employeeId) } : { $in: ids };
      ids = await this.employees.distinct('_id', q);
    }
    return ids;
  }

  private empMatch(ids: Types.ObjectId[] | null, field = 'employeeId'): Record<string, unknown> {
    return ids ? { [field]: { $in: ids } } : {};
  }

  // ------------------------------------------------------------------ catalog

  list(ctx: Ctx): { key: string; title: string; category: string }[] {
    return Object.entries(this.defs)
      .filter(([, d]) => ctx.authz.can(d.resource, d.action ?? 'view', d.orgOnly ? 'organization' : undefined) && ctx.authz.can('reports', 'view'))
      .map(([key, d]) => ({ key, title: d.title, category: d.category }));
  }

  async run(ctx: Ctx, key: string, filters: ReportFilters): Promise<ReportResult> {
    const d = this.defs[key];
    if (!d) throw notFound('Report');
    PermissionsService.require(ctx, 'reports', 'view');
    PermissionsService.require(ctx, d.resource, d.action ?? 'view', d.orgOnly ? 'organization' : undefined);
    const org = await this.orgSettings.get(ctx.orgOid);
    const today = localParts(new Date(), org.timezone).day;
    const f = { ...filters, from: filters.from ?? addDays(today, -29), to: filters.to ?? today };
    if (f.to < f.from) throw badRequest('DATES_INVALID', 'The end date is before the start.', 'to');
    if (Date.parse(f.to) - Date.parse(f.from) > 400 * 86400_000) throw badRequest('RANGE_TOO_LONG', 'Pick a range of at most 400 days.', 'from');
    const emp = d.orgOnly ? null : await this.employeeSet(ctx, d.resource, d.action ?? 'view', f);
    const res = await d.run(ctx, f, emp);
    return { key, title: d.title, category: d.category, generatedAt: new Date().toISOString(), ...res };
  }

  toCsv(r: ReportResult): string {
    const cell = (v: unknown) => {
      const s = v == null ? '' : v instanceof Date ? v.toISOString() : String(v);
      // Neutralise spreadsheet formula injection.
      const safe = /^[=+\-@]/.test(s) ? `'${s}` : s;
      return `"${safe.replace(/"/g, '""')}"`;
    };
    return [r.columns.map((c) => cell(c.label)).join(','), ...r.rows.map((row) => r.columns.map((c) => cell(row[c.key])).join(','))].join('\n');
  }

  async export(ctx: Ctx, key: string, filters: ReportFilters): Promise<{ csv: string; filename: string }> {
    PermissionsService.require(ctx, 'reports', 'export');
    const r = await this.run(ctx, key, filters);
    await this.audit.record(ctx, { action: 'report.export', resourceType: 'report', resourceId: key, changes: { rows: { from: null, to: r.rows.length } } });
    return { csv: this.toCsv(r), filename: `${key}-${filters.from ?? ''}-${filters.to ?? ''}.csv` };
  }

  // ------------------------------------------------------------------ saved views and pinned cards

  async listSaved(ctx: Ctx): Promise<any[]> {
    return serialize(await this.saved.find({ organizationId: ctx.orgOid, ownerId: ctx.userOid }).sort({ pinned: -1, name: 1 }).lean());
  }

  async save(ctx: Ctx, b: { name: string; reportKey: string; filters: ReportFilters; chart?: string; fields?: string[]; pinned?: boolean; schedule?: { cron?: string; emailTo?: string[]; format?: string } }, id?: string): Promise<any> {
    if (!this.defs[b.reportKey]) throw notFound('Report');
    if (id) {
      const r = await this.saved.updateOne({ _id: oid(id), organizationId: ctx.orgOid, ownerId: ctx.userOid }, { $set: b });
      if (!r.matchedCount) throw notFound('Saved report');
    } else id = String((await this.saved.create({ ...b, organizationId: ctx.orgOid, ownerId: ctx.userOid }))._id);
    return serialize(await this.saved.findById(id).lean());
  }

  async deleteSaved(ctx: Ctx, id: string): Promise<void> {
    const r = await this.saved.deleteOne({ _id: oid(id), organizationId: ctx.orgOid, ownerId: ctx.userOid });
    if (!r.deletedCount) throw notFound('Saved report');
  }

  // ------------------------------------------------------------------ definitions

  private build(): Record<string, Def> {
    const S = this;
    return {
      // ---------------- HR
      headcount_by_department: {
        title: 'Headcount by department',
        category: 'HR',
        resource: 'employees',
        async run(ctx, f, emp) {
          const rows = await S.employees.aggregate([{ $match: { organizationId: ctx.orgOid, status: { $nin: ['exited', 'archived'] }, ...S.empMatch(emp, '_id') } }, { $group: { _id: '$departmentId', n: { $sum: 1 } } }, { $sort: { n: -1 } }]);
          const dn = await S.deptNames(ctx.orgOid);
          const out = rows.map((r: any) => ({ department: dn.get(String(r._id)) ?? 'No department', headcount: r.n }));
          const total = out.reduce((a, r) => a + r.headcount, 0);
          return { chart: 'bar', x: 'department', y: ['headcount'], columns: [{ key: 'department', label: 'Department' }, { key: 'headcount', label: 'Headcount', type: 'number' }], rows: out, summary: `${total} people across ${out.length} departments${out[0] ? `; ${out[0].department} is largest with ${out[0].headcount}` : ''}.` };
        },
      },
      joiners_exits: {
        title: 'Joiners and exits',
        category: 'HR',
        resource: 'employees',
        async run(ctx, f, emp) {
          const rows = await S.history.aggregate([
            { $match: { organizationId: ctx.orgOid, type: { $in: ['joined', 'exit'] }, effectiveOn: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...S.empMatch(emp) } },
            { $group: { _id: { m: { $dateToString: { format: '%Y-%m', date: '$effectiveOn' } }, t: '$type' }, n: { $sum: 1 } } },
            { $sort: { '_id.m': 1 } },
          ]);
          const months = [...new Set(rows.map((r: any) => r._id.m))];
          const out = months.map((m) => ({ month: m, joiners: rows.find((r: any) => r._id.m === m && r._id.t === 'joined')?.n ?? 0, exits: rows.find((r: any) => r._id.m === m && r._id.t === 'exit')?.n ?? 0 }));
          const j = out.reduce((a, r) => a + r.joiners, 0);
          const x = out.reduce((a, r) => a + r.exits, 0);
          return { chart: 'bar', x: 'month', y: ['joiners', 'exits'], columns: [{ key: 'month', label: 'Month' }, { key: 'joiners', label: 'Joiners', type: 'number' }, { key: 'exits', label: 'Exits', type: 'number' }], rows: out, summary: `${j} joined and ${x} left between ${f.from} and ${f.to}.` };
        },
      },
      employment_status: {
        title: 'Employment status',
        category: 'HR',
        resource: 'employees',
        async run(ctx, _f, emp) {
          const rows = await S.employees.aggregate([{ $match: { organizationId: ctx.orgOid, ...S.empMatch(emp, '_id') } }, { $group: { _id: '$status', n: { $sum: 1 } } }, { $sort: { n: -1 } }]);
          const out = rows.map((r: any) => ({ status: r._id, count: r.n }));
          return { chart: 'doughnut', x: 'status', y: ['count'], columns: [{ key: 'status', label: 'Status' }, { key: 'count', label: 'People', type: 'number' }], rows: out, summary: out.map((r) => `${r.count} ${r.status}`).join(', ') + '.' };
        },
      },
      turnover: {
        title: 'Employee turnover',
        category: 'HR',
        resource: 'employees',
        async run(ctx, f, emp) {
          const exits = await S.history.countDocuments({ organizationId: ctx.orgOid, type: 'exit', effectiveOn: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...S.empMatch(emp) });
          const active = await S.employees.countDocuments({ organizationId: ctx.orgOid, status: { $nin: ['exited', 'archived'] }, ...S.empMatch(emp, '_id') });
          const avg = active + exits / 2;
          const rate = pct(exits, avg);
          return { chart: 'table', columns: [{ key: 'metric', label: 'Metric' }, { key: 'value', label: 'Value' }], rows: [{ metric: 'Exits', value: exits }, { metric: 'Current headcount', value: active }, { metric: 'Turnover', value: `${rate}%` }], summary: `Turnover was ${rate}% (${exits} exits) for the period.` };
        },
      },
      onboarding_progress: {
        title: 'Onboarding progress',
        category: 'HR',
        resource: 'employees',
        async run(ctx, _f, emp) {
          const rows = await S.checklists.find({ organizationId: ctx.orgOid, kind: 'onboarding', status: 'open', ...S.empMatch(emp) }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.employeeId));
          const out = rows.map((r) => ({ employee: n.get(String(r.employeeId)) ?? '', done: r.items.filter((i: any) => i.done).length, total: r.items.length, progress: pct(r.items.filter((i: any) => i.done).length, r.items.length) })).sort((a, b) => a.progress - b.progress);
          return { chart: 'bar', x: 'employee', y: ['progress'], columns: [{ key: 'employee', label: 'Employee' }, { key: 'done', label: 'Done', type: 'number' }, { key: 'total', label: 'Steps', type: 'number' }, { key: 'progress', label: 'Progress', type: 'percent' }], rows: out, summary: `${out.length} people are onboarding${out[0] ? `; ${out[0].employee} is least complete at ${out[0].progress}%` : ''}.` };
        },
      },
      document_expiry: {
        title: 'Document expiry',
        category: 'HR',
        resource: 'documents',
        async run(ctx, f, emp) {
          const rows = await S.documents.find({ organizationId: ctx.orgOid, status: 'active', expiryDate: { $gte: f.from, $lte: addDays(f.to, 90) }, ...(emp ? { relatedEmployeeId: { $in: emp } } : {}) }).sort({ expiryDate: 1 }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.relatedEmployeeId));
          const out = rows.map((r) => ({ title: r.title, employee: n.get(String(r.relatedEmployeeId)) ?? '-', category: r.category, expiryDate: r.expiryDate }));
          return { chart: 'timeline', columns: [{ key: 'expiryDate', label: 'Expires', type: 'date' }, { key: 'title', label: 'Document' }, { key: 'employee', label: 'Employee' }, { key: 'category', label: 'Category' }], rows: out, summary: `${out.length} document(s) expire by ${addDays(f.to, 90)}.` };
        },
      },
      employee_directory: {
        title: 'Employee directory',
        category: 'HR',
        resource: 'employees',
        async run(ctx, _f, emp) {
          const rows = await S.employees.find({ organizationId: ctx.orgOid, status: { $nin: ['exited', 'archived'] }, ...S.empMatch(emp, '_id') }, { sensitive: 0 }).sort({ firstName: 1 }).limit(5000).lean<any[]>();
          const dn = await S.deptNames(ctx.orgOid);
          const out = rows.map((e) => ({ code: e.employeeCode, name: `${e.firstName} ${e.lastName ?? ''}`.trim(), designation: e.designation ?? '', department: dn.get(String(e.departmentId)) ?? '', email: e.contactEmail ?? '', status: e.status, joiningDate: e.joiningDate ? new Date(e.joiningDate).toISOString().slice(0, 10) : '' }));
          return { chart: 'table', columns: [{ key: 'code', label: 'ID' }, { key: 'name', label: 'Name' }, { key: 'designation', label: 'Designation' }, { key: 'department', label: 'Department' }, { key: 'email', label: 'Email' }, { key: 'status', label: 'Status' }, { key: 'joiningDate', label: 'Joined', type: 'date' }], rows: out, summary: `${out.length} employees.` };
        },
      },

      // ---------------- Attendance
      attendance_daily: {
        title: 'Daily attendance',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.attendance.aggregate([{ $match: { organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, ...S.empMatch(emp) } }, { $group: { _id: { d: '$workDate', s: '$status' }, n: { $sum: 1 } } }, { $sort: { '_id.d': 1 } }]);
          const days = [...new Set(rows.map((r: any) => r._id.d))];
          const get = (d: string, s: string) => rows.find((r: any) => r._id.d === d && r._id.s === s)?.n ?? 0;
          const out = days.map((d) => ({ day: d, present: get(d, 'present'), late: get(d, 'late'), half_day: get(d, 'half_day'), absent: get(d, 'absent'), on_leave: get(d, 'on_leave'), incomplete: get(d, 'incomplete') }));
          const avgPresent = out.length ? Math.round(out.reduce((a, r) => a + r.present + r.late, 0) / out.length) : 0;
          return { chart: 'stacked', x: 'day', y: ['present', 'late', 'half_day', 'absent', 'on_leave', 'incomplete'], columns: [{ key: 'day', label: 'Day', type: 'date' }, { key: 'present', label: 'Present', type: 'number' }, { key: 'late', label: 'Late', type: 'number' }, { key: 'half_day', label: 'Half day', type: 'number' }, { key: 'absent', label: 'Absent', type: 'number' }, { key: 'on_leave', label: 'On leave', type: 'number' }, { key: 'incomplete', label: 'Incomplete', type: 'number' }], rows: out, summary: `On average ${avgPresent} people were in per day over ${out.length} days.` };
        },
      },
      attendance_monthly: {
        title: 'Monthly attendance by employee',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.attendance.aggregate([
            { $match: { organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, ...S.empMatch(emp) } },
            { $group: { _id: '$employeeId', present: { $sum: { $cond: [{ $in: ['$status', ['present', 'late']] }, 1, 0] } }, late: { $sum: { $cond: [{ $eq: ['$status', 'late'] }, 1, 0] } }, absent: { $sum: { $cond: [{ $eq: ['$status', 'absent'] }, 1, 0] } }, halfDay: { $sum: { $cond: [{ $eq: ['$status', 'half_day'] }, 1, 0] } }, leave: { $sum: { $cond: [{ $eq: ['$status', 'on_leave'] }, 1, 0] } }, worked: { $sum: '$workedMinutes' }, overtime: { $sum: '$overtimeMinutes' } } },
          ]);
          const n = await S.names(rows.map((r: any) => r._id));
          const out = rows.map((r: any) => ({ employee: n.get(String(r._id)) ?? '', present: r.present, late: r.late, halfDay: r.halfDay, absent: r.absent, leave: r.leave, workedHours: r2(r.worked / 60), overtimeHours: r2(r.overtime / 60) })).sort((a: any, b: any) => a.employee.localeCompare(b.employee));
          return { chart: 'table', columns: [{ key: 'employee', label: 'Employee' }, { key: 'present', label: 'Present', type: 'number' }, { key: 'late', label: 'Late', type: 'number' }, { key: 'halfDay', label: 'Half days', type: 'number' }, { key: 'absent', label: 'Absent', type: 'number' }, { key: 'leave', label: 'Leave', type: 'number' }, { key: 'workedHours', label: 'Worked h', type: 'number' }, { key: 'overtimeHours', label: 'Overtime h', type: 'number' }], rows: out, summary: `${out.length} employees; ${out.reduce((a: number, r: any) => a + r.absent, 0)} absence days in total.` };
        },
      },
      attendance_by_department: {
        title: 'Attendance by department',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.attendance.aggregate([
            { $match: { organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, ...S.empMatch(emp) } },
            { $lookup: { from: 'employees', localField: 'employeeId', foreignField: '_id', as: 'e' } },
            { $unwind: '$e' },
            { $group: { _id: '$e.departmentId', present: { $sum: { $cond: [{ $in: ['$status', ['present', 'late', 'half_day']] }, 1, 0] } }, total: { $sum: { $cond: [{ $in: ['$status', ['present', 'late', 'half_day', 'absent']] }, 1, 0] } } } },
          ]);
          const dn = await S.deptNames(ctx.orgOid);
          const out = rows.map((r: any) => ({ department: dn.get(String(r._id)) ?? 'No department', rate: pct(r.present, r.total), presentDays: r.present, workingDays: r.total })).sort((a: any, b: any) => b.rate - a.rate);
          return { chart: 'bar', x: 'department', y: ['rate'], columns: [{ key: 'department', label: 'Department' }, { key: 'rate', label: 'Attendance', type: 'percent' }, { key: 'presentDays', label: 'Present days', type: 'number' }, { key: 'workingDays', label: 'Expected days', type: 'number' }], rows: out, summary: out.length ? `${out[0].department} has the highest attendance at ${out[0].rate}%.` : 'No attendance in this period.' };
        },
      },
      attendance_exceptions: {
        title: 'Attendance exceptions',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const fl = await S.flags.find({ organizationId: ctx.orgOid, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...S.empMatch(emp) }).sort({ createdAt: -1 }).limit(2000).lean<any[]>();
          const inc = await S.attendance.find({ organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, status: { $in: ['incomplete', 'pending_correction'] }, ...S.empMatch(emp) }).limit(2000).lean<any[]>();
          const n = await S.names([...fl.map((x) => x.employeeId), ...inc.map((x) => x.employeeId)]);
          const out = [
            ...fl.map((x) => ({ date: new Date(x.createdAt).toISOString().slice(0, 10), employee: n.get(String(x.employeeId)) ?? '', exception: x.type.replace(/_/g, ' '), status: x.status })),
            ...inc.map((x) => ({ date: x.workDate, employee: n.get(String(x.employeeId)) ?? '', exception: x.status.replace(/_/g, ' '), status: 'open' })),
          ].sort((a, b) => b.date.localeCompare(a.date));
          return { chart: 'table', columns: [{ key: 'date', label: 'Date', type: 'date' }, { key: 'employee', label: 'Employee' }, { key: 'exception', label: 'Exception' }, { key: 'status', label: 'Status' }], rows: out, summary: `${out.length} exception(s): ${fl.length} flagged pattern(s), ${inc.length} incomplete day(s).` };
        },
      },
      worked_hours: {
        title: 'Worked hours',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.attendance.aggregate([{ $match: { organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, ...S.empMatch(emp) } }, { $group: { _id: '$workDate', worked: { $sum: '$workedMinutes' }, people: { $sum: { $cond: [{ $gt: ['$workedMinutes', 0] }, 1, 0] } } } }, { $sort: { _id: 1 } }]);
          const out = rows.map((r: any) => ({ day: r._id, hours: r2(r.worked / 60), avgHours: r.people ? r2(r.worked / 60 / r.people) : 0 }));
          return { chart: 'line', x: 'day', y: ['avgHours'], columns: [{ key: 'day', label: 'Day', type: 'date' }, { key: 'hours', label: 'Total hours', type: 'number' }, { key: 'avgHours', label: 'Average per person', type: 'number' }], rows: out, summary: `Average ${out.length ? r2(out.reduce((a: number, r: any) => a + r.avgHours, 0) / out.length) : 0} hours per person per day.` };
        },
      },
      overtime: {
        title: 'Overtime',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.attendance.aggregate([{ $match: { organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, overtimeMinutes: { $gt: 0 }, ...S.empMatch(emp) } }, { $group: { _id: '$employeeId', minutes: { $sum: '$overtimeMinutes' }, days: { $sum: 1 } } }, { $sort: { minutes: -1 } }]);
          const n = await S.names(rows.map((r: any) => r._id));
          const out = rows.map((r: any) => ({ employee: n.get(String(r._id)) ?? '', hours: r2(r.minutes / 60), days: r.days }));
          return { chart: 'bar', x: 'employee', y: ['hours'], columns: [{ key: 'employee', label: 'Employee' }, { key: 'hours', label: 'Overtime hours', type: 'number' }, { key: 'days', label: 'Days', type: 'number' }], rows: out, summary: `${r2(out.reduce((a: number, r: any) => a + r.hours, 0))} overtime hours across ${out.length} people.` };
        },
      },
      shift_compliance: {
        title: 'Shift compliance',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.attendance.aggregate([{ $match: { organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, 'checkIn.at': { $exists: true }, ...S.empMatch(emp) } }, { $group: { _id: '$employeeId', days: { $sum: 1 }, late: { $sum: { $cond: [{ $gt: ['$lateMinutes', 0] }, 1, 0] } }, early: { $sum: { $cond: [{ $gt: ['$earlyLeaveMinutes', 15] }, 1, 0] } }, lateMin: { $sum: '$lateMinutes' } } }]);
          const n = await S.names(rows.map((r: any) => r._id));
          const out = rows.map((r: any) => ({ employee: n.get(String(r._id)) ?? '', days: r.days, lateDays: r.late, earlyLeaves: r.early, onTime: pct(r.days - r.late, r.days), avgLateMin: r.late ? Math.round(r.lateMin / r.late) : 0 })).sort((a: any, b: any) => a.onTime - b.onTime);
          return { chart: 'bar', x: 'employee', y: ['onTime'], columns: [{ key: 'employee', label: 'Employee' }, { key: 'days', label: 'Days', type: 'number' }, { key: 'lateDays', label: 'Late', type: 'number' }, { key: 'earlyLeaves', label: 'Left early', type: 'number' }, { key: 'onTime', label: 'On time', type: 'percent' }, { key: 'avgLateMin', label: 'Avg minutes late', type: 'minutes' }], rows: out, summary: `Overall on-time rate ${pct(out.reduce((a: number, r: any) => a + r.days - r.lateDays, 0), out.reduce((a: number, r: any) => a + r.days, 0))}%.` };
        },
      },
      correction_history: {
        title: 'Correction history',
        category: 'Attendance',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.corrections.find({ organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, ...S.empMatch(emp) }).sort({ workDate: -1 }).limit(2000).lean<any[]>();
          const n = await S.names(rows.map((r) => r.employeeId));
          const out = rows.map((r) => ({ date: r.workDate, employee: n.get(String(r.employeeId)) ?? '', kind: r.kind.replace(/_/g, ' '), status: r.status, reason: r.reason }));
          return { chart: 'table', columns: [{ key: 'date', label: 'Date', type: 'date' }, { key: 'employee', label: 'Employee' }, { key: 'kind', label: 'Kind' }, { key: 'status', label: 'Status' }, { key: 'reason', label: 'Reason' }], rows: out, summary: `${out.length} correction(s); ${out.filter((r) => r.status === 'approved').length} approved.` };
        },
      },

      // ---------------- Leave
      leave_by_type: {
        title: 'Leave by type',
        category: 'Leave',
        resource: 'leave',
        async run(ctx, f, emp) {
          const rows = await S.leaves.aggregate([{ $match: { organizationId: ctx.orgOid, status: 'approved', startDate: { $lte: f.to }, endDate: { $gte: f.from }, ...S.empMatch(emp) } }, { $group: { _id: '$leaveTypeId', days: { $sum: '$units' }, requests: { $sum: 1 } } }]);
          const types = new Map((await S.leaveTypes.find({ organizationId: ctx.orgOid }).lean<any[]>()).map((t) => [String(t._id), t.name]));
          const out = rows.map((r: any) => ({ type: types.get(String(r._id)) ?? '', days: r.days, requests: r.requests })).sort((a: any, b: any) => b.days - a.days);
          return { chart: 'doughnut', x: 'type', y: ['days'], columns: [{ key: 'type', label: 'Leave type' }, { key: 'days', label: 'Days', type: 'number' }, { key: 'requests', label: 'Requests', type: 'number' }], rows: out, summary: `${out.reduce((a: number, r: any) => a + r.days, 0)} leave days approved${out[0] ? `, mostly ${out[0].type}` : ''}.` };
        },
      },
      leave_balances: {
        title: 'Leave balances',
        category: 'Leave',
        resource: 'leave',
        async run(ctx, f, emp) {
          const year = Number(f.to.slice(0, 4));
          const rows = await S.balances.find({ organizationId: ctx.orgOid, year, ...S.empMatch(emp) }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.employeeId));
          const types = new Map((await S.leaveTypes.find({ organizationId: ctx.orgOid }).lean<any[]>()).map((t) => [String(t._id), t.code]));
          const out = rows.map((r) => ({ employee: n.get(String(r.employeeId)) ?? '', type: types.get(String(r.leaveTypeId)) ?? '', entitled: r.entitled, carried: r.carriedForward, adjusted: r.adjusted, used: r.used, pending: r.pending, available: r2(r.entitled + r.carriedForward + r.adjusted - r.used - r.pending) })).sort((a, b) => a.employee.localeCompare(b.employee) || a.type.localeCompare(b.type));
          return { chart: 'table', columns: [{ key: 'employee', label: 'Employee' }, { key: 'type', label: 'Type' }, { key: 'entitled', label: 'Entitled', type: 'number' }, { key: 'carried', label: 'Carried', type: 'number' }, { key: 'adjusted', label: 'Adjusted', type: 'number' }, { key: 'used', label: 'Used', type: 'number' }, { key: 'pending', label: 'Pending', type: 'number' }, { key: 'available', label: 'Available', type: 'number' }], rows: out, summary: `${year} balances for ${new Set(out.map((r) => r.employee)).size} employees.` };
        },
      },
      leave_usage_by_employee: {
        title: 'Leave usage by employee',
        category: 'Leave',
        resource: 'leave',
        async run(ctx, f, emp) {
          const rows = await S.leaves.aggregate([{ $match: { organizationId: ctx.orgOid, status: 'approved', startDate: { $lte: f.to }, endDate: { $gte: f.from }, ...S.empMatch(emp) } }, { $group: { _id: '$employeeId', days: { $sum: '$units' }, requests: { $sum: 1 } } }, { $sort: { days: -1 } }]);
          const n = await S.names(rows.map((r: any) => r._id));
          const out = rows.map((r: any) => ({ employee: n.get(String(r._id)) ?? '', days: r.days, requests: r.requests }));
          return { chart: 'bar', x: 'employee', y: ['days'], columns: [{ key: 'employee', label: 'Employee' }, { key: 'days', label: 'Days', type: 'number' }, { key: 'requests', label: 'Requests', type: 'number' }], rows: out, summary: `${out.length} people took leave in this period.` };
        },
      },
      leave_by_department: {
        title: 'Leave by department',
        category: 'Leave',
        resource: 'leave',
        async run(ctx, f, emp) {
          const rows = await S.leaves.aggregate([
            { $match: { organizationId: ctx.orgOid, status: 'approved', startDate: { $lte: f.to }, endDate: { $gte: f.from }, ...S.empMatch(emp) } },
            { $lookup: { from: 'employees', localField: 'employeeId', foreignField: '_id', as: 'e' } },
            { $unwind: '$e' },
            { $group: { _id: '$e.departmentId', days: { $sum: '$units' } } },
            { $sort: { days: -1 } },
          ]);
          const dn = await S.deptNames(ctx.orgOid);
          const out = rows.map((r: any) => ({ department: dn.get(String(r._id)) ?? 'No department', days: r.days }));
          return { chart: 'bar', x: 'department', y: ['days'], columns: [{ key: 'department', label: 'Department' }, { key: 'days', label: 'Leave days', type: 'number' }], rows: out, summary: out[0] ? `${out[0].department} took the most leave (${out[0].days} days).` : 'No leave in this period.' };
        },
      },
      leave_pending_rejected: {
        title: 'Pending and rejected leave',
        category: 'Leave',
        resource: 'leave',
        async run(ctx, f, emp) {
          const rows = await S.leaves.find({ organizationId: ctx.orgOid, status: { $in: ['pending', 'rejected', 'clarification'] }, startDate: { $lte: f.to }, endDate: { $gte: f.from }, ...S.empMatch(emp) }).sort({ startDate: 1 }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.employeeId));
          const out = rows.map((r) => ({ employee: n.get(String(r.employeeId)) ?? '', from: r.startDate, to: r.endDate, days: r.units, status: r.status, comment: r.decisionComment ?? '' }));
          return { chart: 'table', columns: [{ key: 'employee', label: 'Employee' }, { key: 'from', label: 'From', type: 'date' }, { key: 'to', label: 'To', type: 'date' }, { key: 'days', label: 'Days', type: 'number' }, { key: 'status', label: 'Status' }, { key: 'comment', label: 'Comment' }], rows: out, summary: `${out.filter((r) => r.status === 'pending').length} pending and ${out.filter((r) => r.status === 'rejected').length} rejected.` };
        },
      },
      absence_trends: {
        title: 'Absence trends',
        category: 'Leave',
        resource: 'attendance',
        async run(ctx, f, emp) {
          const rows = await S.attendance.aggregate([{ $match: { organizationId: ctx.orgOid, workDate: { $gte: f.from, $lte: f.to }, status: { $in: ['absent', 'on_leave'] }, ...S.empMatch(emp) } }, { $group: { _id: { m: { $substrBytes: ['$workDate', 0, 7] }, s: '$status' }, n: { $sum: 1 } } }, { $sort: { '_id.m': 1 } }]);
          const months = [...new Set(rows.map((r: any) => r._id.m))];
          const out = months.map((m) => ({ month: m, absent: rows.find((r: any) => r._id.m === m && r._id.s === 'absent')?.n ?? 0, onLeave: rows.find((r: any) => r._id.m === m && r._id.s === 'on_leave')?.n ?? 0 }));
          return { chart: 'line', x: 'month', y: ['absent', 'onLeave'], columns: [{ key: 'month', label: 'Month' }, { key: 'absent', label: 'Absent days', type: 'number' }, { key: 'onLeave', label: 'Leave days', type: 'number' }], rows: out, summary: `${out.reduce((a, r) => a + r.absent, 0)} unplanned absence days in the period.` };
        },
      },

      // ---------------- Expenses
      expenses_by_category: {
        title: 'Expenses by category',
        category: 'Expenses',
        resource: 'expenses',
        async run(ctx, f, emp) {
          const rows = await S.expenses.aggregate([{ $match: { organizationId: ctx.orgOid, expenseDate: { $gte: f.from, $lte: f.to }, status: { $in: ['submitted', 'approved'] }, ...S.empMatch(emp) } }, { $group: { _id: '$categoryId', total: { $sum: '$amount' }, count: { $sum: 1 } } }, { $sort: { total: -1 } }]);
          const cats = new Map((await S.categories.find({ organizationId: ctx.orgOid }).lean<any[]>()).map((c) => [String(c._id), c.name]));
          const out = rows.map((r: any) => ({ category: cats.get(String(r._id)) ?? 'Other', total: r2(r.total), claims: r.count }));
          return { chart: 'doughnut', x: 'category', y: ['total'], columns: [{ key: 'category', label: 'Category' }, { key: 'total', label: 'Total', type: 'money' }, { key: 'claims', label: 'Claims', type: 'number' }], rows: out, summary: `${r2(out.reduce((a: number, r: any) => a + r.total, 0))} claimed${out[0] ? `; ${out[0].category} is the largest` : ''}.` };
        },
      },
      expenses_by_employee: {
        title: 'Expenses by employee',
        category: 'Expenses',
        resource: 'expenses',
        async run(ctx, f, emp) {
          const rows = await S.expenses.aggregate([{ $match: { organizationId: ctx.orgOid, expenseDate: { $gte: f.from, $lte: f.to }, status: { $in: ['submitted', 'approved'] }, ...S.empMatch(emp) } }, { $group: { _id: '$employeeId', total: { $sum: '$amount' }, count: { $sum: 1 } } }, { $sort: { total: -1 } }]);
          const n = await S.names(rows.map((r: any) => r._id));
          const out = rows.map((r: any) => ({ employee: n.get(String(r._id)) ?? '', total: r2(r.total), claims: r.count }));
          return { chart: 'bar', x: 'employee', y: ['total'], columns: [{ key: 'employee', label: 'Employee' }, { key: 'total', label: 'Total', type: 'money' }, { key: 'claims', label: 'Claims', type: 'number' }], rows: out, summary: `${out.length} people claimed expenses.` };
        },
      },
      expenses_by_department: {
        title: 'Expenses by department',
        category: 'Expenses',
        resource: 'expenses',
        async run(ctx, f, emp) {
          const rows = await S.expenses.aggregate([
            { $match: { organizationId: ctx.orgOid, expenseDate: { $gte: f.from, $lte: f.to }, status: { $in: ['submitted', 'approved'] }, ...S.empMatch(emp) } },
            { $lookup: { from: 'employees', localField: 'employeeId', foreignField: '_id', as: 'e' } },
            { $unwind: '$e' },
            { $group: { _id: '$e.departmentId', total: { $sum: '$amount' } } },
            { $sort: { total: -1 } },
          ]);
          const dn = await S.deptNames(ctx.orgOid);
          const out = rows.map((r: any) => ({ department: dn.get(String(r._id)) ?? 'No department', total: r2(r.total) }));
          return { chart: 'bar', x: 'department', y: ['total'], columns: [{ key: 'department', label: 'Department' }, { key: 'total', label: 'Total', type: 'money' }], rows: out, summary: out[0] ? `${out[0].department} spent the most (${out[0].total}).` : 'No expenses in this period.' };
        },
      },
      pending_reimbursements: {
        title: 'Pending reimbursements',
        category: 'Expenses',
        resource: 'expenses',
        async run(ctx, _f, emp) {
          const rows = await S.expenses.find({ organizationId: ctx.orgOid, status: 'approved', reimbursementStatus: { $in: ['pending', 'scheduled'] }, ...S.empMatch(emp) }).sort({ expenseDate: 1 }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.employeeId));
          const out = rows.map((r) => ({ employee: n.get(String(r.employeeId)) ?? '', date: r.expenseDate, amount: r.amount, status: r.reimbursementStatus }));
          return { chart: 'table', columns: [{ key: 'employee', label: 'Employee' }, { key: 'date', label: 'Expense date', type: 'date' }, { key: 'amount', label: 'Amount', type: 'money' }, { key: 'status', label: 'Reimbursement' }], rows: out, summary: `${r2(out.reduce((a, r) => a + r.amount, 0))} waiting to be reimbursed across ${out.length} expense(s).` };
        },
      },
      expenses_approved_vs_rejected: {
        title: 'Approved versus rejected claims',
        category: 'Expenses',
        resource: 'expenses',
        async run(ctx, f, emp) {
          const rows = await S.expenses.aggregate([{ $match: { organizationId: ctx.orgOid, expenseDate: { $gte: f.from, $lte: f.to }, status: { $in: ['approved', 'rejected', 'submitted'] }, ...S.empMatch(emp) } }, { $group: { _id: '$status', count: { $sum: 1 }, total: { $sum: '$amount' } } }]);
          const out = rows.map((r: any) => ({ status: r._id, claims: r.count, total: r2(r.total) }));
          return { chart: 'doughnut', x: 'status', y: ['claims'], columns: [{ key: 'status', label: 'Status' }, { key: 'claims', label: 'Claims', type: 'number' }, { key: 'total', label: 'Total', type: 'money' }], rows: out, summary: out.map((r) => `${r.claims} ${r.status}`).join(', ') + '.' };
        },
      },
      expenses_monthly: {
        title: 'Monthly expense trend',
        category: 'Expenses',
        resource: 'expenses',
        async run(ctx, f, emp) {
          const rows = await S.expenses.aggregate([{ $match: { organizationId: ctx.orgOid, expenseDate: { $gte: f.from, $lte: f.to }, status: { $in: ['submitted', 'approved'] }, ...S.empMatch(emp) } }, { $group: { _id: { $substrBytes: ['$expenseDate', 0, 7] }, total: { $sum: '$amount' } } }, { $sort: { _id: 1 } }]);
          const out = rows.map((r: any) => ({ month: r._id, total: r2(r.total) }));
          return { chart: 'line', x: 'month', y: ['total'], columns: [{ key: 'month', label: 'Month' }, { key: 'total', label: 'Total', type: 'money' }], rows: out, summary: out.length ? `Highest month: ${out.slice().sort((a: any, b: any) => b.total - a.total)[0].month}.` : 'No expenses in this period.' };
        },
      },
      travel_summary: {
        title: 'Travel expense summary',
        category: 'Expenses',
        resource: 'travel',
        async run(ctx, f, emp) {
          const rows = await S.travel.find({ organizationId: ctx.orgOid, departureDate: { $gte: f.from, $lte: f.to }, ...S.empMatch(emp) }).sort({ departureDate: -1 }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.employeeId));
          const out = rows.map((r) => ({ employee: n.get(String(r.employeeId)) ?? '', destination: r.destination, departure: r.departureDate, status: r.status, estimated: r.estimatedCost, actual: r.actualCost ?? null }));
          return { chart: 'table', columns: [{ key: 'employee', label: 'Employee' }, { key: 'destination', label: 'Destination' }, { key: 'departure', label: 'Departure', type: 'date' }, { key: 'status', label: 'Status' }, { key: 'estimated', label: 'Estimated', type: 'money' }, { key: 'actual', label: 'Actual', type: 'money' }], rows: out, summary: `${out.length} trips; estimated ${r2(out.reduce((a, r) => a + (r.estimated ?? 0), 0))}, settled ${r2(out.reduce((a, r) => a + (r.actual ?? 0), 0))}.` };
        },
      },

      // ---------------- Payroll (restricted)
      payroll_by_period: {
        title: 'Payroll by period',
        category: 'Payroll',
        resource: 'payroll',
        orgOnly: true,
        async run(ctx, f) {
          const rows = await S.runs.find({ organizationId: ctx.orgOid, periodStart: { $gte: f.from.slice(0, 7) + '-01', $lte: f.to } }).sort({ periodStart: 1 }).lean<any[]>();
          const out = rows.map((r) => ({ period: r.label, status: r.status, employees: r.totals?.employees ?? 0, gross: r.totals?.gross ?? 0, deductions: r.totals?.deductions ?? 0, net: r.totals?.net ?? 0, employerCost: r.totals?.employerCost ?? 0 }));
          return { chart: 'bar', x: 'period', y: ['gross', 'net'], columns: [{ key: 'period', label: 'Period' }, { key: 'status', label: 'Status' }, { key: 'employees', label: 'Employees', type: 'number' }, { key: 'gross', label: 'Gross', type: 'money' }, { key: 'deductions', label: 'Deductions', type: 'money' }, { key: 'net', label: 'Net', type: 'money' }, { key: 'employerCost', label: 'Employer cost', type: 'money' }], rows: out, summary: `${out.length} payroll period(s); net total ${r2(out.reduce((a, r) => a + r.net, 0))}.` };
        },
      },
      payroll_components: {
        title: 'Salary component totals',
        category: 'Payroll',
        resource: 'payroll',
        orgOnly: true,
        async run(ctx, f) {
          const runIds = await S.runs.distinct('_id', { organizationId: ctx.orgOid, periodStart: { $gte: f.from.slice(0, 7) + '-01', $lte: f.to }, status: { $in: ['finalized', 'paid'] } });
          const [e, d] = await Promise.all([
            S.lines.aggregate([{ $match: { runId: { $in: runIds } } }, { $unwind: '$earnings' }, { $group: { _id: '$earnings.name', total: { $sum: '$earnings.amount' } } }, { $sort: { total: -1 } }]),
            S.lines.aggregate([{ $match: { runId: { $in: runIds } } }, { $unwind: '$deductions' }, { $group: { _id: '$deductions.name', total: { $sum: '$deductions.amount' } } }, { $sort: { total: -1 } }]),
          ]);
          const out = [...e.map((r: any) => ({ component: r._id, kind: 'Earning', total: r2(r.total) })), ...d.map((r: any) => ({ component: r._id, kind: 'Deduction', total: r2(r.total) }))];
          return { chart: 'bar', x: 'component', y: ['total'], columns: [{ key: 'component', label: 'Component' }, { key: 'kind', label: 'Kind' }, { key: 'total', label: 'Total', type: 'money' }], rows: out, summary: `${runIds.length} finalized run(s) in the period.` };
        },
      },
      payroll_payment_status: {
        title: 'Payment status',
        category: 'Payroll',
        resource: 'payroll',
        orgOnly: true,
        async run(ctx, f) {
          const runIds = await S.runs.distinct('_id', { organizationId: ctx.orgOid, periodStart: { $gte: f.from.slice(0, 7) + '-01', $lte: f.to } });
          const rows = await S.lines.aggregate([{ $match: { runId: { $in: runIds } } }, { $group: { _id: '$paymentStatus', count: { $sum: 1 }, net: { $sum: '$net' } } }]);
          const out = rows.map((r: any) => ({ status: r._id, lines: r.count, net: r2(r.net) }));
          return { chart: 'doughnut', x: 'status', y: ['lines'], columns: [{ key: 'status', label: 'Status' }, { key: 'lines', label: 'Employees', type: 'number' }, { key: 'net', label: 'Net', type: 'money' }], rows: out, summary: out.map((r) => `${r.lines} ${r.status}`).join(', ') + '.' };
        },
      },
      payroll_adjustments: {
        title: 'Payroll adjustments',
        category: 'Payroll',
        resource: 'payroll',
        orgOnly: true,
        async run(ctx, f) {
          const rows = await S.adjustments.find({ organizationId: ctx.orgOid, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } }).sort({ createdAt: -1 }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.employeeId));
          const out = rows.map((r) => ({ date: new Date(r.createdAt).toISOString().slice(0, 10), employee: n.get(String(r.employeeId)) ?? '', kind: r.kind, amount: r.amount, status: r.status, reason: r.reason }));
          return { chart: 'table', columns: [{ key: 'date', label: 'Date', type: 'date' }, { key: 'employee', label: 'Employee' }, { key: 'kind', label: 'Kind' }, { key: 'amount', label: 'Amount', type: 'money' }, { key: 'status', label: 'Status' }, { key: 'reason', label: 'Reason' }], rows: out, summary: `${out.length} adjustment(s).` };
        },
      },
      payslip_status: {
        title: 'Payslip generation status',
        category: 'Payroll',
        resource: 'payroll',
        orgOnly: true,
        async run(ctx, f) {
          const runs = await S.runs.find({ organizationId: ctx.orgOid, periodStart: { $gte: f.from.slice(0, 7) + '-01', $lte: f.to } }).lean<any[]>();
          const out = [];
          for (const r of runs) {
            const lines = await S.lines.countDocuments({ runId: r._id, paymentStatus: { $ne: 'on_hold' } });
            const slips = await S.payslips.countDocuments({ runId: r._id });
            const viewed = await S.payslips.countDocuments({ runId: r._id, viewedAt: { $ne: null } });
            out.push({ period: r.label, status: r.status, expected: lines, generated: slips, viewed });
          }
          return { chart: 'table', columns: [{ key: 'period', label: 'Period' }, { key: 'status', label: 'Run' }, { key: 'expected', label: 'Expected', type: 'number' }, { key: 'generated', label: 'Generated', type: 'number' }, { key: 'viewed', label: 'Viewed', type: 'number' }], rows: out, summary: `${out.reduce((a, r) => a + r.generated, 0)} payslips generated.` };
        },
      },

      // ---------------- Tasks
      tasks_by_status: {
        title: 'Tasks by status',
        category: 'Tasks',
        resource: 'tasks',
        async run(ctx, _f, emp) {
          const rows = await S.tasks.aggregate([{ $match: { organizationId: ctx.orgOid, ...(emp ? { assigneeIds: { $in: emp } } : {}) } }, { $group: { _id: '$status', n: { $sum: 1 } } }]);
          const out = rows.map((r: any) => ({ status: r._id.replace('_', ' '), tasks: r.n }));
          return { chart: 'doughnut', x: 'status', y: ['tasks'], columns: [{ key: 'status', label: 'Status' }, { key: 'tasks', label: 'Tasks', type: 'number' }], rows: out, summary: out.map((r) => `${r.tasks} ${r.status}`).join(', ') + '.' };
        },
      },
      tasks_by_assignee: {
        title: 'Tasks by assignee',
        category: 'Tasks',
        resource: 'tasks',
        async run(ctx, _f, emp) {
          const rows = await S.tasks.aggregate([{ $match: { organizationId: ctx.orgOid, status: { $nin: ['cancelled'] }, ...(emp ? { assigneeIds: { $in: emp } } : {}) } }, { $unwind: '$assigneeIds' }, ...(emp ? [{ $match: { assigneeIds: { $in: emp } } }] : []), { $group: { _id: '$assigneeIds', open: { $sum: { $cond: [{ $ne: ['$status', 'completed'] }, 1, 0] } }, done: { $sum: { $cond: [{ $eq: ['$status', 'completed'] }, 1, 0] } } } }, { $sort: { open: -1 } }]);
          const n = await S.names(rows.map((r: any) => r._id));
          const out = rows.map((r: any) => ({ employee: n.get(String(r._id)) ?? '', open: r.open, completed: r.done }));
          return { chart: 'stacked', x: 'employee', y: ['open', 'completed'], columns: [{ key: 'employee', label: 'Assignee' }, { key: 'open', label: 'Open', type: 'number' }, { key: 'completed', label: 'Completed', type: 'number' }], rows: out, summary: out[0] ? `${out[0].employee} has the most open tasks (${out[0].open}).` : 'No tasks.' };
        },
      },
      tasks_overdue: {
        title: 'Overdue tasks',
        category: 'Tasks',
        resource: 'tasks',
        async run(ctx, f, emp) {
          const today = f.to;
          const rows = await S.tasks.find({ organizationId: ctx.orgOid, dueDate: { $lt: today }, status: { $nin: ['completed', 'cancelled'] }, ...(emp ? { assigneeIds: { $in: emp } } : {}) }).sort({ dueDate: 1 }).limit(1000).lean<any[]>();
          const n = await S.names(rows.flatMap((r) => r.assigneeIds ?? []));
          const out = rows.map((r) => ({ title: r.title, assignees: (r.assigneeIds ?? []).map((a: any) => n.get(String(a))).filter(Boolean).join(', '), dueDate: r.dueDate, daysLate: Math.round((Date.parse(today) - Date.parse(r.dueDate)) / 86400_000), priority: r.priority }));
          return { chart: 'table', columns: [{ key: 'title', label: 'Task' }, { key: 'assignees', label: 'Assignees' }, { key: 'dueDate', label: 'Due', type: 'date' }, { key: 'daysLate', label: 'Days late', type: 'number' }, { key: 'priority', label: 'Priority' }], rows: out, summary: `${out.length} overdue task(s).` };
        },
      },
      task_completion: {
        title: 'Completion rate and time',
        category: 'Tasks',
        resource: 'tasks',
        async run(ctx, f, emp) {
          const match = { organizationId: ctx.orgOid, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, status: { $ne: 'cancelled' }, ...(emp ? { assigneeIds: { $in: emp } } : {}) };
          const rows = await S.tasks.aggregate([{ $match: match }, { $group: { _id: { $dateToString: { format: '%Y-%m', date: '$createdAt' } }, created: { $sum: 1 }, completed: { $sum: { $cond: [{ $eq: ['$status', 'completed'] }, 1, 0] } }, hours: { $sum: { $cond: [{ $eq: ['$status', 'completed'] }, { $divide: [{ $subtract: ['$completedAt', '$createdAt'] }, 3_600_000] }, 0] } } } }, { $sort: { _id: 1 } }]);
          const out = rows.map((r: any) => ({ month: r._id, created: r.created, completed: r.completed, rate: pct(r.completed, r.created), avgDays: r.completed ? r2(r.hours / r.completed / 24) : 0 }));
          return { chart: 'line', x: 'month', y: ['rate'], columns: [{ key: 'month', label: 'Month' }, { key: 'created', label: 'Created', type: 'number' }, { key: 'completed', label: 'Completed', type: 'number' }, { key: 'rate', label: 'Completion', type: 'percent' }, { key: 'avgDays', label: 'Avg days to complete', type: 'number' }], rows: out, summary: `Completion rate ${pct(out.reduce((a: number, r: any) => a + r.completed, 0), out.reduce((a: number, r: any) => a + r.created, 0))}% for tasks created in the period.` };
        },
      },
      workload_by_team: {
        title: 'Workload by team',
        category: 'Tasks',
        resource: 'tasks',
        async run(ctx, _f, emp) {
          const rows = await S.tasks.aggregate([
            { $match: { organizationId: ctx.orgOid, status: { $nin: ['completed', 'cancelled'] }, ...(emp ? { assigneeIds: { $in: emp } } : {}) } },
            { $unwind: '$assigneeIds' },
            { $lookup: { from: 'employees', localField: 'assigneeIds', foreignField: '_id', as: 'e' } },
            { $unwind: '$e' },
            { $group: { _id: '$e.teamId', open: { $sum: 1 } } },
            { $sort: { open: -1 } },
          ]);
          const teams = new Map((await S.teams.find({ organizationId: ctx.orgOid }, { name: 1 }).lean<any[]>()).map((t) => [String(t._id), t.name]));
          const out = rows.map((r: any) => ({ team: teams.get(String(r._id)) ?? 'No team', openTasks: r.open }));
          return { chart: 'bar', x: 'team', y: ['openTasks'], columns: [{ key: 'team', label: 'Team' }, { key: 'openTasks', label: 'Open tasks', type: 'number' }], rows: out, summary: out[0] ? `${out[0].team} carries the most open work.` : 'No open tasks.' };
        },
      },
      tasks_completed: {
        title: 'Tasks completed in period',
        category: 'Tasks',
        resource: 'tasks',
        async run(ctx, f, emp) {
          const rows = await S.tasks.find({ organizationId: ctx.orgOid, status: 'completed', completedAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...(emp ? { assigneeIds: { $in: emp } } : {}) }).sort({ completedAt: -1 }).limit(2000).lean<any[]>();
          const n = await S.names(rows.flatMap((r) => r.assigneeIds ?? []));
          const out = rows.map((r) => ({ completedOn: new Date(r.completedAt).toISOString().slice(0, 10), title: r.title, assignees: (r.assigneeIds ?? []).map((a: any) => n.get(String(a))).filter(Boolean).join(', '), priority: r.priority }));
          return { chart: 'table', columns: [{ key: 'completedOn', label: 'Completed', type: 'date' }, { key: 'title', label: 'Task' }, { key: 'assignees', label: 'Assignees' }, { key: 'priority', label: 'Priority' }], rows: out, summary: `${out.length} task(s) completed.` };
        },
      },

      // ---------------- CRM
      leads_by_source: {
        title: 'Leads by source',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, f, emp) {
          const rows = await S.leads.aggregate([{ $match: { organizationId: ctx.orgOid, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...S.empMatch(emp, 'ownerEmployeeId') } }, { $group: { _id: '$source', n: { $sum: 1 }, won: { $sum: { $cond: [{ $eq: ['$status', 'won'] }, 1, 0] } } } }, { $sort: { n: -1 } }]);
          const out = rows.map((r: any) => ({ source: r._id, leads: r.n, won: r.won, conversion: pct(r.won, r.n) }));
          return { chart: 'doughnut', x: 'source', y: ['leads'], columns: [{ key: 'source', label: 'Source' }, { key: 'leads', label: 'Leads', type: 'number' }, { key: 'won', label: 'Won', type: 'number' }, { key: 'conversion', label: 'Conversion', type: 'percent' }], rows: out, summary: out[0] ? `${out[0].source} brought the most leads (${out[0].leads}).` : 'No leads in this period.' };
        },
      },
      leads_by_status: {
        title: 'Leads by status',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, _f, emp) {
          const rows = await S.leads.aggregate([{ $match: { organizationId: ctx.orgOid, ...S.empMatch(emp, 'ownerEmployeeId') } }, { $group: { _id: '$status', n: { $sum: 1 }, value: { $sum: { $ifNull: ['$estimatedValue', 0] } } } }, { $sort: { n: -1 } }]);
          const out = rows.map((r: any) => ({ status: r._id.replace('_', ' '), leads: r.n, value: r2(r.value) }));
          return { chart: 'bar', x: 'status', y: ['leads'], columns: [{ key: 'status', label: 'Status' }, { key: 'leads', label: 'Leads', type: 'number' }, { key: 'value', label: 'Pipeline value', type: 'money' }], rows: out, summary: `${out.reduce((a: number, r: any) => a + r.leads, 0)} leads in the pipeline.` };
        },
      },
      lead_funnel: {
        title: 'Lead conversion funnel',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, f, emp) {
          const order = ['new', 'contacted', 'interested', 'qualified', 'meeting_scheduled', 'proposal', 'won'];
          const rows = await S.leads.find({ organizationId: ctx.orgOid, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...S.empMatch(emp, 'ownerEmployeeId') }, { status: 1 }).lean<any[]>();
          // A lead counts at every stage it has reached.
          const reached = (s: string) => rows.filter((r) => order.indexOf(r.status) >= order.indexOf(s)).length;
          const out = order.map((s) => ({ stage: s.replace('_', ' '), leads: reached(s), ofTotal: pct(reached(s), rows.length) }));
          return { chart: 'funnel', x: 'stage', y: ['leads'], columns: [{ key: 'stage', label: 'Stage' }, { key: 'leads', label: 'Leads', type: 'number' }, { key: 'ofTotal', label: 'Of all leads', type: 'percent' }], rows: out, summary: `${pct(reached('won'), rows.length)}% of ${rows.length} leads were won.` };
        },
      },
      lead_response_time: {
        title: 'Lead response time',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, f, emp) {
          const rows = await S.leads.find({ organizationId: ctx.orgOid, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, firstResponseAt: { $ne: null }, ...S.empMatch(emp, 'ownerEmployeeId') }, { ownerEmployeeId: 1, createdAt: 1, firstResponseAt: 1 }).lean<any[]>();
          const by = new Map<string, number[]>();
          for (const r of rows) by.set(String(r.ownerEmployeeId), [...(by.get(String(r.ownerEmployeeId)) ?? []), (new Date(r.firstResponseAt).getTime() - new Date(r.createdAt).getTime()) / 3_600_000]);
          const n = await S.names([...by.keys()].map((k) => (Types.ObjectId.isValid(k) ? new Types.ObjectId(k) : null)));
          const out = [...by.entries()].map(([k, v]) => ({ owner: n.get(k) ?? 'Unassigned', leads: v.length, avgHours: r2(v.reduce((a, b) => a + b, 0) / v.length) })).sort((a, b) => a.avgHours - b.avgHours);
          return { chart: 'bar', x: 'owner', y: ['avgHours'], columns: [{ key: 'owner', label: 'Owner' }, { key: 'leads', label: 'Leads', type: 'number' }, { key: 'avgHours', label: 'Avg hours to first response', type: 'number' }], rows: out, summary: out.length ? `Fastest: ${out[0].owner} (${out[0].avgHours} h).` : 'No responses recorded.' };
        },
      },
      follow_ups_due: {
        title: 'Follow-ups due',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, _f, emp) {
          const rows = await S.leads.find({ organizationId: ctx.orgOid, nextFollowUpAt: { $lte: new Date(Date.now() + 7 * 86400_000) }, status: { $nin: ['won', 'lost'] }, ...S.empMatch(emp, 'ownerEmployeeId') }).sort({ nextFollowUpAt: 1 }).lean<any[]>();
          const n = await S.names(rows.map((r) => r.ownerEmployeeId));
          const out = rows.map((r) => ({ lead: r.name, owner: n.get(String(r.ownerEmployeeId)) ?? '', due: new Date(r.nextFollowUpAt).toISOString(), status: r.status }));
          return { chart: 'table', columns: [{ key: 'lead', label: 'Lead' }, { key: 'owner', label: 'Owner' }, { key: 'due', label: 'Due', type: 'date' }, { key: 'status', label: 'Status' }], rows: out, summary: `${out.length} follow-up(s) due within a week.` };
        },
      },
      meetings_scheduled: {
        title: 'Meetings scheduled',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, f) {
          const rows = await S.meetings.aggregate([{ $match: { organizationId: ctx.orgOid, relatedLeadId: { $ne: null }, startAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } } }, { $group: { _id: { $dateToString: { format: '%Y-%m-%d', date: '$startAt' } }, n: { $sum: 1 } } }, { $sort: { _id: 1 } }]);
          const out = rows.map((r: any) => ({ day: r._id, meetings: r.n }));
          return { chart: 'bar', x: 'day', y: ['meetings'], columns: [{ key: 'day', label: 'Day', type: 'date' }, { key: 'meetings', label: 'Meetings', type: 'number' }], rows: out, summary: `${out.reduce((a: number, r: any) => a + r.meetings, 0)} lead meetings.` };
        },
      },
      won_lost: {
        title: 'Won and lost leads',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, f, emp) {
          const rows = await S.leads.aggregate([{ $match: { organizationId: ctx.orgOid, status: { $in: ['won', 'lost'] }, updatedAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...S.empMatch(emp, 'ownerEmployeeId') } }, { $group: { _id: { s: '$status', r: '$lostReason' }, n: { $sum: 1 }, value: { $sum: { $ifNull: ['$estimatedValue', 0] } } } }]);
          const out = rows.map((r: any) => ({ outcome: r._id.s, reason: r._id.r ?? '', leads: r.n, value: r2(r.value) }));
          return { chart: 'table', columns: [{ key: 'outcome', label: 'Outcome' }, { key: 'reason', label: 'Lost reason' }, { key: 'leads', label: 'Leads', type: 'number' }, { key: 'value', label: 'Value', type: 'money' }], rows: out, summary: `${out.filter((r) => r.outcome === 'won').reduce((a, r) => a + r.leads, 0)} won, ${out.filter((r) => r.outcome === 'lost').reduce((a, r) => a + r.leads, 0)} lost.` };
        },
      },
      campaign_performance: {
        title: 'Campaign performance',
        category: 'CRM',
        resource: 'crm',
        async run(ctx, f, emp) {
          const rows = await S.leads.aggregate([{ $match: { organizationId: ctx.orgOid, campaignRef: { $nin: [null, ''] }, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) }, ...S.empMatch(emp, 'ownerEmployeeId') } }, { $group: { _id: '$campaignRef', leads: { $sum: 1 }, qualified: { $sum: { $cond: [{ $in: ['$status', ['qualified', 'meeting_scheduled', 'proposal', 'won']] }, 1, 0] } }, won: { $sum: { $cond: [{ $eq: ['$status', 'won'] }, 1, 0] } } } }, { $sort: { leads: -1 } }]);
          const out = rows.map((r: any) => ({ campaign: r._id, leads: r.leads, qualified: r.qualified, won: r.won, conversion: pct(r.won, r.leads) }));
          return { chart: 'bar', x: 'campaign', y: ['leads', 'won'], columns: [{ key: 'campaign', label: 'Campaign' }, { key: 'leads', label: 'Leads', type: 'number' }, { key: 'qualified', label: 'Qualified', type: 'number' }, { key: 'won', label: 'Won', type: 'number' }, { key: 'conversion', label: 'Conversion', type: 'percent' }], rows: out, summary: out.length ? `${out.length} campaign(s) with leads.` : 'No campaign data available for this period.' };
        },
      },

      // ---------------- System (organization scope)
      api_latency: {
        title: 'API uptime and latency',
        category: 'System',
        resource: 'system',
        orgOnly: true,
        async run(_ctx, f) {
          const rows = await S.metrics.aggregate([{ $match: { minute: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } } }, { $group: { _id: { $dateToString: { format: '%Y-%m-%d', date: '$minute' } }, count: { $sum: '$count' }, errors: { $sum: '$errors' }, totalMs: { $sum: '$totalMs' }, p95: { $max: '$p95Ms' }, minutes: { $sum: 1 } } }, { $sort: { _id: 1 } }]);
          const out = rows.map((r: any) => ({ day: r._id, requests: r.count, errorRate: pct(r.errors, r.count), avgMs: r.count ? Math.round(r.totalMs / r.count) : 0, worstP95Ms: Math.round(r.p95 ?? 0), minutesWithTraffic: r.minutes }));
          return { chart: 'line', x: 'day', y: ['avgMs'], columns: [{ key: 'day', label: 'Day', type: 'date' }, { key: 'requests', label: 'Requests', type: 'number' }, { key: 'errorRate', label: 'Server errors', type: 'percent' }, { key: 'avgMs', label: 'Avg ms', type: 'number' }, { key: 'worstP95Ms', label: 'Worst p95 ms', type: 'number' }], rows: out, summary: out.length ? `Average latency ${Math.round(out.reduce((a: number, r: any) => a + r.avgMs, 0) / out.length)} ms.` : 'No traffic recorded yet.' };
        },
      },
      failed_requests: {
        title: 'Failed requests',
        category: 'System',
        resource: 'system',
        orgOnly: true,
        async run(_ctx, f) {
          const rows = await S.errors.aggregate([{ $match: { at: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } } }, { $group: { _id: { code: '$code', path: '$path' }, n: { $sum: 1 }, last: { $max: '$at' } } }, { $sort: { n: -1 } }, { $limit: 200 }]);
          const out = rows.map((r: any) => ({ code: r._id.code, path: r._id.path, count: r.n, last: r.last }));
          return { chart: 'table', columns: [{ key: 'code', label: 'Error' }, { key: 'path', label: 'Endpoint' }, { key: 'count', label: 'Count', type: 'number' }, { key: 'last', label: 'Last seen', type: 'date' }], rows: out, summary: `${out.reduce((a: number, r: any) => a + r.count, 0)} server errors.` };
        },
      },
      storage_usage: {
        title: 'Storage usage',
        category: 'System',
        resource: 'storage',
        orgOnly: true,
        async run(ctx) {
          const rows = await S.files.aggregate([{ $match: { organizationId: ctx.orgOid, status: 'stored' } }, { $group: { _id: '$purpose', bytes: { $sum: '$sizeBytes' }, files: { $sum: 1 } } }, { $sort: { bytes: -1 } }]);
          const out = rows.map((r: any) => ({ purpose: r._id, megabytes: r2(r.bytes / 1048576), files: r.files }));
          return { chart: 'doughnut', x: 'purpose', y: ['megabytes'], columns: [{ key: 'purpose', label: 'Kind' }, { key: 'megabytes', label: 'MB', type: 'number' }, { key: 'files', label: 'Files', type: 'number' }], rows: out, summary: `${r2(out.reduce((a: number, r: any) => a + r.megabytes, 0))} MB in ${out.reduce((a: number, r: any) => a + r.files, 0)} files.` };
        },
      },
      backup_history: {
        title: 'Backup history',
        category: 'System',
        resource: 'backups',
        orgOnly: true,
        async run(_ctx, f) {
          const rows = await S.backups.find({ startedAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } }).sort({ startedAt: -1 }).lean<any[]>();
          const out = rows.map((r) => ({ started: r.startedAt, kind: r.kind, status: r.status, sizeMb: r.sizeBytes ? r2(r.sizeBytes / 1048576) : null, verified: r.verifiedAt ?? null }));
          return { chart: 'timeline', columns: [{ key: 'started', label: 'Started', type: 'date' }, { key: 'kind', label: 'Kind' }, { key: 'status', label: 'Status' }, { key: 'sizeMb', label: 'MB', type: 'number' }, { key: 'verified', label: 'Verified', type: 'date' }], rows: out, summary: `${out.filter((r) => r.status === 'verified').length} verified of ${out.length} backups.` };
        },
      },
      login_security_events: {
        title: 'Login and security events',
        category: 'System',
        resource: 'security',
        orgOnly: true,
        async run(ctx, f) {
          const rows = await S.logins.aggregate([{ $match: { organizationId: ctx.orgOid, at: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } } }, { $group: { _id: { d: { $dateToString: { format: '%Y-%m-%d', date: '$at' } }, o: '$outcome' }, n: { $sum: 1 } } }, { $sort: { '_id.d': 1 } }]);
          const days = [...new Set(rows.map((r: any) => r._id.d))];
          const get = (d: string, o: string) => rows.find((r: any) => r._id.d === d && r._id.o === o)?.n ?? 0;
          const out = days.map((d) => ({ day: d, success: get(d, 'success'), failure: get(d, 'failure'), blocked: get(d, 'blocked') + get(d, 'locked') }));
          return { chart: 'stacked', x: 'day', y: ['success', 'failure', 'blocked'], columns: [{ key: 'day', label: 'Day', type: 'date' }, { key: 'success', label: 'Sign-ins', type: 'number' }, { key: 'failure', label: 'Failed', type: 'number' }, { key: 'blocked', label: 'Blocked or locked', type: 'number' }], rows: out, summary: `${out.reduce((a, r) => a + r.failure, 0)} failed sign-ins in the period.` };
        },
      },
      failed_jobs: {
        title: 'Failed background jobs',
        category: 'System',
        resource: 'system',
        orgOnly: true,
        async run(_ctx, f) {
          const rows = await S.jobRuns.find({ status: 'failed', startedAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } }).sort({ startedAt: -1 }).limit(500).lean<any[]>();
          const out = rows.map((r) => ({ job: r.job, at: r.startedAt, error: r.error }));
          return { chart: 'table', columns: [{ key: 'at', label: 'When', type: 'date' }, { key: 'job', label: 'Job' }, { key: 'error', label: 'Error' }], rows: out, summary: `${out.length} failed job run(s).` };
        },
      },
      notification_delivery: {
        title: 'Notification delivery',
        category: 'System',
        resource: 'notifications',
        orgOnly: true,
        async run(ctx, f) {
          const rows = await S.deliveries.aggregate([{ $match: { organizationId: ctx.orgOid, createdAt: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } } }, { $group: { _id: { c: '$channel', s: '$status' }, n: { $sum: 1 } } }]);
          const out = rows.map((r: any) => ({ channel: r._id.c, status: r._id.s, count: r.n }));
          return { chart: 'stacked', x: 'channel', y: ['count'], columns: [{ key: 'channel', label: 'Channel' }, { key: 'status', label: 'Status' }, { key: 'count', label: 'Count', type: 'number' }], rows: out, summary: `${out.filter((r) => r.status === 'failed').reduce((a, r) => a + r.count, 0)} failed deliveries.` };
        },
      },
      audit_events: {
        title: 'Audit events',
        category: 'System',
        resource: 'audit',
        orgOnly: true,
        async run(ctx, f) {
          const rows = await S.auditLogs.aggregate([{ $match: { organizationId: ctx.orgOid, at: { $gte: new Date(f.from), $lte: new Date(`${f.to}T23:59:59Z`) } } }, { $group: { _id: '$resourceType', n: { $sum: 1 }, denied: { $sum: { $cond: [{ $eq: ['$outcome', 'denied'] }, 1, 0] } } } }, { $sort: { n: -1 } }]);
          const out = rows.map((r: any) => ({ resource: r._id, events: r.n, denied: r.denied }));
          return { chart: 'bar', x: 'resource', y: ['events'], columns: [{ key: 'resource', label: 'Resource' }, { key: 'events', label: 'Events', type: 'number' }, { key: 'denied', label: 'Denied', type: 'number' }], rows: out, summary: `${out.reduce((a: number, r: any) => a + r.events, 0)} audited actions.` };
        },
      },
    };
  }
}
