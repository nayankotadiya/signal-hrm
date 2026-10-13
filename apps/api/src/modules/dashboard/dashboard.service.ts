import { Injectable } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import type { Ctx } from '../../common/auth/context';
import { ScopeService } from '../../common/authz/scope.service';
import { localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { HealthService } from '../../health/health.service';
import { FilesService } from '../files/files.service';
import { AttentionService, shiftDay } from './attention.service';

const ACTIVE = ['onboarding', 'active', 'probation', 'notice'];

/**
 * Dashboards are assembled from permissions, not role names: each section appears only when the
 * caller holds the grant that section needs. Every number comes from a live query; an empty
 * organization shows zeros and empty lists, never sample figures.
 */
@Injectable()
export class DashboardService {
  constructor(
    private readonly scope: ScopeService,
    private readonly settings: OrgSettingsService,
    private readonly attention: AttentionService,
    private readonly health: HealthService,
    private readonly files: FilesService,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Attendance') private readonly attendance: Model<any>,
    @InjectModel('LeaveBalance') private readonly balances: Model<any>,
    @InjectModel('LeaveType') private readonly leaveTypes: Model<any>,
    @InjectModel('LeaveRequest') private readonly leaveRequests: Model<any>,
    @InjectModel('Expense') private readonly expenses: Model<any>,
    @InjectModel('AttendanceCorrection') private readonly corrections: Model<any>,
    @InjectModel('Task') private readonly tasks: Model<any>,
    @InjectModel('Holiday') private readonly holidays: Model<any>,
    @InjectModel('Announcement') private readonly announcements: Model<any>,
    @InjectModel('HrEvent') private readonly events: Model<any>,
    @InjectModel('Payslip') private readonly payslips: Model<any>,
    @InjectModel('Approval') private readonly approvals: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('Lead') private readonly leads: Model<any>,
    @InjectModel('PayrollRun') private readonly runs: Model<any>,
    @InjectModel('BackupRecord') private readonly backups: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('LoginEvent') private readonly logins: Model<any>,
  ) {}

  async get(ctx: Ctx): Promise<Record<string, unknown>> {
    const org = await this.settings.get(ctx.orgOid);
    const tz = org?.timezone ?? 'Asia/Kolkata';
    const today = localParts(new Date(), tz).day;
    const can = ctx.authz.can.bind(ctx.authz);
    const [me, team, organization, system, attention] = await Promise.all([
      ctx.employeeOid ? this.mine(ctx, ctx.employeeOid, today) : Promise.resolve(null),
      can('attendance', 'view', 'team') && !can('attendance', 'view', 'organization') ? this.team(ctx, today) : Promise.resolve(null),
      can('employees', 'view', 'organization') ? this.organization(ctx, today) : Promise.resolve(null),
      can('system', 'view', 'organization') ? this.system(ctx) : Promise.resolve(null),
      this.attention.compute(ctx),
    ]);
    return { generatedAt: new Date().toISOString(), today, timezone: tz, me, team, organization, system, attention: attention.items, snoozed: attention.snoozed };
  }

  // ---------------------------------------------------------------- personal
  private async mine(ctx: Ctx, emp: Types.ObjectId, today: string) {
    const o = ctx.orgOid;
    const year = Number(today.slice(0, 4));
    const emp0 = await this.employees.findOne({ _id: emp, organizationId: o }, { locationId: 1, departmentId: 1, joiningDate: 1 }).lean<any>();
    const [att, bal, types, leavePending, expPending, corrPending, taskCounts, dueToday, holidays, news, events, payslip] = await Promise.all([
      this.attendance.findOne({ organizationId: o, employeeId: emp, workDate: today }, { 'checkIn.at': 1, 'checkOut.at': 1, 'checkIn.verification': 1, 'checkOut.verification': 1, status: 1, workedMinutes: 1, lateMinutes: 1 }).lean<any>(),
      this.balances.find({ organizationId: o, employeeId: emp, year }).lean<any[]>(),
      this.leaveTypes.find({ organizationId: o, active: true }, { code: 1, name: 1, color: 1 }).lean<any[]>(),
      this.leaveRequests.countDocuments({ organizationId: o, employeeId: emp, status: { $in: ['pending', 'clarification'] } }),
      this.expenses.countDocuments({ organizationId: o, employeeId: emp, status: 'submitted' }),
      this.corrections.countDocuments({ organizationId: o, employeeId: emp, status: 'pending' }),
      this.tasks.aggregate([{ $match: { organizationId: o, assigneeIds: emp, status: { $nin: ['completed', 'cancelled'] } } }, { $group: { _id: '$status', n: { $sum: 1 } } }]),
      this.tasks.find({ organizationId: o, assigneeIds: emp, status: { $nin: ['completed', 'cancelled'] }, dueDate: { $lte: today } }, { title: 1, dueDate: 1, priority: 1, status: 1 }).sort({ dueDate: 1 }).limit(5).lean<any[]>(),
      this.holidays.find({ organizationId: o, date: { $gte: today }, $or: [{ locationIds: { $size: 0 } }, { locationIds: emp0?.locationId ?? null }] }, { date: 1, name: 1, optional: 1 }).sort({ date: 1 }).limit(3).lean<any[]>(),
      this.announcements
        .find({ organizationId: o, kind: 'announcement', publishedAt: { $lte: new Date() }, $and: [{ $or: [{ expiresAt: null }, { expiresAt: { $gt: new Date() } }] }, { $or: [{ 'audience.departmentIds': { $size: 0 } }, { 'audience.departmentIds': emp0?.departmentId ?? null }, { audience: null }] }] }, { title: 1, publishedAt: 1, pinned: 1 })
        .sort({ pinned: -1, publishedAt: -1 })
        .limit(3)
        .lean<any[]>(),
      this.events.find({ organizationId: o, status: 'scheduled', startAt: { $gte: new Date() } }, { title: 1, startAt: 1, eventType: 1 }).sort({ startAt: 1 }).limit(3).lean<any[]>(),
      this.payslips.findOne({ organizationId: o, employeeId: emp, publishedAt: { $ne: null } }, { period: 1, net: 1, publishedAt: 1, viewedAt: 1 }).sort({ period: -1 }).lean<any>(),
    ]);
    const typeById = new Map(types.map((t) => [String(t._id), t]));
    return {
      attendance: att ? serialize(att) : null,
      leaveBalances: bal
        .filter((b) => typeById.has(String(b.leaveTypeId)))
        .map((b) => {
          const t = typeById.get(String(b.leaveTypeId));
          const total = (b.entitled ?? 0) + (b.carriedForward ?? 0) + (b.adjusted ?? 0);
          return { leaveTypeId: String(b.leaveTypeId), code: t.code, name: t.name, color: t.color, total, used: b.used ?? 0, pending: b.pending ?? 0, available: total - (b.used ?? 0) - (b.pending ?? 0) };
        }),
      pendingRequests: { leave: leavePending, expenses: expPending, corrections: corrPending },
      tasks: { byStatus: Object.fromEntries(taskCounts.map((t: any) => [t._id, t.n])), due: serialize(dueToday) },
      upcomingHolidays: serialize(holidays),
      announcements: serialize(news),
      upcomingEvents: serialize(events),
      latestPayslip: payslip ? serialize(payslip) : null,
    };
  }

  // ---------------------------------------------------------------- manager
  private async team(ctx: Ctx, today: string) {
    const ids = await this.scope.employeeIds(ctx, ctx.authz.scope('attendance', 'view')!, 'attendance', 'view');
    const empFilter = ids ? { _id: { $in: ids } } : {};
    const members = await this.employees.find({ organizationId: ctx.orgOid, status: { $in: ACTIVE }, ...empFilter }, { _id: 1 }).lean<any[]>();
    const memberIds = members.map((m) => m._id);
    const [todayRows, onLeave, taskCounts, approvalsWaiting] = await Promise.all([
      this.attendance.find({ organizationId: ctx.orgOid, workDate: today, employeeId: { $in: memberIds } }, { status: 1, 'checkIn.at': 1, lateMinutes: 1 }).lean<any[]>(),
      this.leaveRequests.countDocuments({ organizationId: ctx.orgOid, employeeId: { $in: memberIds }, status: 'approved', startDate: { $lte: today }, endDate: { $gte: today } }),
      this.tasks.aggregate([{ $match: { organizationId: ctx.orgOid, assigneeIds: { $in: memberIds }, status: { $nin: ['cancelled'] } } }, { $group: { _id: '$status', n: { $sum: 1 } } }]),
      this.approvals.countDocuments({ organizationId: ctx.orgOid, status: 'pending', currentApproverIds: ctx.userOid }),
    ]);
    const checkedIn = todayRows.filter((r) => r.checkIn?.at).length;
    const late = todayRows.filter((r) => (r.lateMinutes ?? 0) > 0).length;
    return {
      headcount: memberIds.length,
      today: { checkedIn, late, onLeave, notCheckedIn: Math.max(0, memberIds.length - checkedIn - onLeave) },
      tasksByStatus: Object.fromEntries(taskCounts.map((t: any) => [t._id, t.n])),
      approvalsWaiting,
      trend: await this.attendanceTrend(ctx, today, memberIds),
    };
  }

  // ---------------------------------------------------------------- HR / admin
  private async organization(ctx: Ctx, today: string) {
    const o = ctx.orgOid;
    const monthStart = `${today.slice(0, 7)}-01`;
    const can = ctx.authz.can.bind(ctx.authz);
    const [byStatus, byDept, depts, joiners, exits, todayRows, onLeave, leavePending, approvalsPending] = await Promise.all([
      this.employees.aggregate([{ $match: { organizationId: o } }, { $group: { _id: '$status', n: { $sum: 1 } } }]),
      this.employees.aggregate([{ $match: { organizationId: o, status: { $in: ACTIVE } } }, { $group: { _id: '$departmentId', n: { $sum: 1 } } }]),
      this.departments.find({ organizationId: o }, { name: 1 }).lean<any[]>(),
      this.employees.countDocuments({ organizationId: o, joiningDate: { $gte: new Date(`${monthStart}T00:00:00Z`) } }),
      this.employees.countDocuments({ organizationId: o, exitDate: { $gte: new Date(`${monthStart}T00:00:00Z`) } }),
      this.attendance.find({ organizationId: o, workDate: today }, { status: 1, 'checkIn.at': 1, lateMinutes: 1 }).lean<any[]>(),
      this.leaveRequests.countDocuments({ organizationId: o, status: 'approved', startDate: { $lte: today }, endDate: { $gte: today } }),
      this.leaveRequests.countDocuments({ organizationId: o, status: 'pending' }),
      this.approvals.countDocuments({ organizationId: o, status: 'pending' }),
    ]);
    const deptName = new Map(depts.map((d) => [String(d._id), d.name]));
    const statusMap = Object.fromEntries(byStatus.map((s: any) => [s._id, s.n]));
    const activeCount = ACTIVE.reduce((n, s) => n + (statusMap[s] ?? 0), 0);
    const checkedIn = todayRows.filter((r) => r.checkIn?.at).length;
    const out: Record<string, unknown> = {
      headcount: { active: activeCount, byStatus: statusMap, joinersThisMonth: joiners, exitsThisMonth: exits },
      byDepartment: byDept.map((d: any) => ({ departmentId: d._id ? String(d._id) : null, name: d._id ? (deptName.get(String(d._id)) ?? 'Unknown') : 'No department', count: d.n })).sort((a: any, b: any) => b.count - a.count),
      today: { checkedIn, late: todayRows.filter((r) => (r.lateMinutes ?? 0) > 0).length, onLeave, notCheckedIn: Math.max(0, activeCount - checkedIn - onLeave) },
      trend: await this.attendanceTrend(ctx, today),
      leavePending,
      approvalsPending,
    };
    if (can('expenses', 'view', 'organization')) {
      const rows = await this.expenses.aggregate([{ $match: { organizationId: o, expenseDate: { $gte: monthStart }, status: { $in: ['submitted', 'approved'] } } }, { $group: { _id: '$status', amount: { $sum: '$amount' }, n: { $sum: 1 } } }]);
      out.expensesThisMonth = Object.fromEntries(rows.map((r: any) => [r._id, { amount: r.amount, count: r.n }]));
    }
    if (can('crm', 'view', 'organization')) {
      const rows = await this.leads.aggregate([{ $match: { organizationId: o } }, { $group: { _id: '$status', n: { $sum: 1 } } }]);
      out.leadFunnel = Object.fromEntries(rows.map((r: any) => [r._id, r.n]));
    }
    if (can('payroll', 'view', 'organization')) {
      const run = await this.runs.findOne({ organizationId: o, status: { $ne: 'cancelled' } }, { periodStart: 1, periodEnd: 1, status: 1, totals: 1, anomalies: 1 }).sort({ periodStart: -1 }).lean<any>();
      out.latestPayroll = run ? serialize(run) : null;
    }
    return out;
  }

  /** Present-or-late count per day for the last 14 days (scoped list optional). */
  private async attendanceTrend(ctx: Ctx, today: string, employeeIds?: Types.ObjectId[]) {
    const from = shiftDay(today, -13);
    const match: Record<string, unknown> = { organizationId: ctx.orgOid, workDate: { $gte: from, $lte: today }, 'checkIn.at': { $exists: true } };
    if (employeeIds) match.employeeId = { $in: employeeIds };
    const rows = await this.attendance.aggregate([{ $match: match }, { $group: { _id: '$workDate', present: { $sum: 1 }, late: { $sum: { $cond: [{ $gt: ['$lateMinutes', 0] }, 1, 0] } } } }]);
    const byDay = new Map(rows.map((r: any) => [r._id, r]));
    return Array.from({ length: 14 }, (_, i) => {
      const d = shiftDay(from, i);
      const r: any = byDay.get(d);
      return { day: d, present: r?.present ?? 0, late: r?.late ?? 0 };
    });
  }

  // ---------------------------------------------------------------- Super Admin control center
  private async system(ctx: Ctx) {
    const since = new Date(Date.now() - 86400_000);
    const [health, lastBackup, lastVerified, storage, users, logins] = await Promise.all([
      this.health.summary(),
      this.backups.findOne({}, { kind: 1, status: 1, startedAt: 1, finishedAt: 1, sizeBytes: 1, error: 1 }).sort({ startedAt: -1 }).lean<any>(),
      this.backups.findOne({ status: 'verified' }, { verifiedAt: 1, sizeBytes: 1, restoreTestedAt: 1 }).sort({ verifiedAt: -1 }).lean<any>(),
      this.files.usage(ctx.orgOid).catch(() => null),
      this.users.aggregate([{ $match: { organizationId: ctx.orgOid } }, { $group: { _id: '$status', n: { $sum: 1 } } }]),
      this.logins.aggregate([{ $match: { organizationId: ctx.orgOid, at: { $gt: since } } }, { $group: { _id: '$outcome', n: { $sum: 1 } } }]),
    ]);
    return {
      health,
      backups: { last: lastBackup ? serialize(lastBackup) : null, lastVerified: lastVerified ? serialize(lastVerified) : null },
      storage,
      users: Object.fromEntries(users.map((u: any) => [u._id, u.n])),
      logins24h: Object.fromEntries(logins.map((l: any) => [l._id, l.n])),
    };
  }
}
