import { Injectable } from '@nestjs/common';
import { Model } from 'mongoose';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest } from '../../common/http/validation';
import { localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel } from '../../database/model';

export type Severity = 'info' | 'warning' | 'critical';

export interface AttentionItem {
  key: string; // stable id, used for snoozing
  severity: Severity;
  title: string;
  detail?: string;
  count: number;
  link: string; // in-app route
  snoozable: boolean;
}

/**
 * Needs-attention engine. Every item is computed from live records and gated by permission;
 * nothing is shown when the underlying count is zero. Critical items cannot be snoozed.
 */
@Injectable()
export class AttentionService {
  constructor(
    private readonly scope: ScopeService,
    private readonly audit: AuditService,
    private readonly settings: OrgSettingsService,
    @InjectModel('Snooze') private readonly snoozes: Model<any>,
    @InjectModel('Approval') private readonly approvals: Model<any>,
    @InjectModel('AttendanceFlag') private readonly flags: Model<any>,
    @InjectModel('Attendance') private readonly attendance: Model<any>,
    @InjectModel('DocumentAck') private readonly acks: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('PayrollRun') private readonly runs: Model<any>,
    @InjectModel('BackupRecord') private readonly backups: Model<any>,
    @InjectModel('SecurityAlert') private readonly alerts: Model<any>,
    @InjectModel('ModerationReport') private readonly reports: Model<any>,
    @InjectModel('IntegrationConnection') private readonly integrations: Model<any>,
    @InjectModel('NotificationDelivery') private readonly deliveries: Model<any>,
    @InjectModel('Task') private readonly tasks: Model<any>,
    @InjectModel('Lead') private readonly leads: Model<any>,
    @InjectModel('Document') private readonly documents: Model<any>,
    @InjectModel('JobRun') private readonly jobRuns: Model<any>,
  ) {}

  async compute(ctx: Ctx, includeSnoozed = false): Promise<{ items: AttentionItem[]; snoozed: { key: string; until: string; reason: string }[] }> {
    const can = (r: Parameters<Ctx['authz']['can']>[0], a: Parameters<Ctx['authz']['can']>[1], s?: Parameters<Ctx['authz']['can']>[2]) => ctx.authz.can(r, a, s);
    const org = await this.settings.get(ctx.orgOid);
    const tz = org?.timezone ?? 'Asia/Kolkata';
    const today = localParts(new Date(), tz).day;
    const now = new Date();
    const items: AttentionItem[] = [];
    const add = (i: Omit<AttentionItem, 'snoozable'> & { snoozable?: boolean }) => {
      if (i.count > 0) items.push({ snoozable: i.severity !== 'critical', ...i });
    };
    const o = ctx.orgOid;
    const jobs: Promise<void>[] = [];
    const run = (fn: () => Promise<void>) => jobs.push(fn().catch(() => undefined));

    // --- personal
    run(async () => {
      const [pending, overdue] = await Promise.all([
        this.approvals.countDocuments({ organizationId: o, status: 'pending', currentApproverIds: ctx.userOid }),
        this.approvals.countDocuments({ organizationId: o, status: 'pending', currentApproverIds: ctx.userOid, dueAt: { $lt: now } }),
      ]);
      add({ key: 'approvals.overdue', severity: 'warning', title: 'Overdue approvals', detail: 'Requests past their response time.', count: overdue, link: '/approvals?filter=overdue' });
      add({ key: 'approvals.pending', severity: 'info', title: 'Waiting for your approval', count: pending - overdue, link: '/approvals' });
    });
    if (ctx.employeeOid) {
      const emp = ctx.employeeOid;
      run(async () => {
        const n = await this.attendance.countDocuments({ organizationId: o, employeeId: emp, workDate: { $lt: today, $gte: shiftDay(today, -7) }, 'checkIn.at': { $exists: true }, 'checkOut.at': { $exists: false }, status: { $ne: 'pending_correction' } });
        add({ key: 'me.missing_checkout', severity: 'warning', title: 'Missing check-out', detail: 'Request a correction so your hours are counted.', count: n, link: '/attendance?view=history' });
      });
      run(async () => {
        const n = await this.acks.countDocuments({ organizationId: o, employeeId: emp, acknowledgedAt: null });
        add({ key: 'me.policy_ack', severity: 'info', title: 'Policies to acknowledge', count: n, link: '/documents?filter=to_acknowledge' });
      });
      run(async () => {
        const n = await this.tasks.countDocuments({ organizationId: o, assigneeIds: emp, status: { $nin: ['completed', 'cancelled'] }, dueDate: { $lt: today } });
        add({ key: 'me.tasks_overdue', severity: 'warning', title: 'Overdue tasks', count: n, link: '/tasks?filter=overdue' });
      });
      if (can('crm', 'view')) {
        run(async () => {
          const n = await this.leads.countDocuments({ organizationId: o, ownerEmployeeId: emp, status: { $nin: ['won', 'lost'] }, nextFollowUpAt: { $lt: now } });
          add({ key: 'me.lead_followups', severity: 'warning', title: 'Lead follow-ups due', count: n, link: '/crm?filter=followup_due' });
        });
      }
    }

    // --- team / organization
    if (can('attendance', 'approve', 'team')) {
      run(async () => {
        const f = await this.scope.filter(ctx, 'attendance', 'approve');
        const n = await this.flags.countDocuments({ organizationId: o, status: 'open', ...f });
        add({ key: 'attendance.flags', severity: 'warning', title: 'Attendance patterns to review', detail: 'Flagged for review only. Nothing was changed automatically.', count: n, link: '/attendance/review' });
      });
    }
    if (can('employees', 'edit', 'team')) {
      run(async () => {
        const f = await this.scope.filter(ctx, 'employees', 'edit', '_id');
        const soon = new Date(now.getTime() + 14 * 86400_000);
        const n = await this.employees.countDocuments({ organizationId: o, ...f, 'probation.status': { $in: ['on_probation', 'extended'] }, 'probation.endsOn': { $lte: soon } });
        add({ key: 'people.probation', severity: 'info', title: 'Probation reviews due', detail: 'Ending within 14 days or already past.', count: n, link: '/people?filter=probation_due' });
      });
      run(async () => {
        const n = await this.employees.countDocuments({ organizationId: o, status: { $in: ['active', 'onboarding', 'probation', 'notice'] }, userId: { $exists: false } });
        if (can('users', 'create', 'organization')) add({ key: 'people.no_account', severity: 'info', title: 'Employees without an account', detail: 'Invite them so they can sign in.', count: n, link: '/people?filter=no_account' });
      });
    }
    if (can('documents', 'manage', 'organization')) {
      run(async () => {
        const n = await this.documents.countDocuments({ organizationId: o, status: 'active', expiryDate: { $gte: today, $lte: shiftDay(today, 30) } });
        add({ key: 'documents.expiring', severity: 'info', title: 'Documents expiring in 30 days', count: n, link: '/documents?filter=expiring' });
      });
    }
    if (can('payroll', 'view', 'organization')) {
      run(async () => {
        const runs = await this.runs.find({ organizationId: o, status: { $in: ['calculated', 'in_review', 'pending_approval', 'approved'] } }, { status: 1, periodStart: 1, anomalies: 1 }).lean<any[]>();
        add({ key: 'payroll.open_runs', severity: 'info', title: 'Payroll runs in progress', detail: runs.map((r) => `${String(r.periodStart).slice(0, 7)}: ${String(r.status).replace('_', ' ')}`).join(', '), count: runs.length, link: '/payroll' });
      });
    }
    if (can('security', 'view', 'organization')) {
      run(async () => {
        const [crit, other] = await Promise.all([
          this.alerts.countDocuments({ organizationId: o, status: 'open', severity: { $in: ['high', 'critical'] } }),
          this.alerts.countDocuments({ organizationId: o, status: 'open', severity: { $in: ['low', 'medium'] } }),
        ]);
        add({ key: 'security.alerts_high', severity: 'critical', title: 'High-severity security alerts', count: crit, link: '/security' });
        add({ key: 'security.alerts', severity: 'warning', title: 'Security alerts to review', count: other, link: '/security' });
      });
    }
    if (can('moderation', 'view', 'organization')) {
      run(async () => {
        const n = await this.reports.countDocuments({ organizationId: o, status: { $in: ['open', 'escalated'] } });
        add({ key: 'moderation.open', severity: 'warning', title: 'Reports waiting for moderation', count: n, link: '/moderation' });
      });
    }
    if (can('integrations', 'view', 'organization')) {
      run(async () => {
        const n = await this.integrations.countDocuments({ organizationId: o, status: { $in: ['error', 'expired'] } });
        add({ key: 'integrations.broken', severity: 'warning', title: 'Integrations need reconnecting', count: n, link: '/settings/integrations' });
      });
    }
    if (can('notifications', 'manage', 'organization')) {
      run(async () => {
        const n = await this.deliveries.countDocuments({ organizationId: o, status: 'failed', updatedAt: { $gt: new Date(now.getTime() - 86400_000) } });
        add({ key: 'notifications.failed', severity: 'warning', title: 'Emails that failed to send (24h)', count: n, link: '/settings/notifications?tab=deliveries' });
      });
    }
    if (can('backups', 'view', 'organization')) {
      run(async () => {
        const last = await this.backups.findOne({ status: 'verified' }).sort({ verifiedAt: -1 }).lean<any>();
        const failed = await this.backups.countDocuments({ status: 'failed', startedAt: { $gt: last?.verifiedAt ?? new Date(0) } });
        const stale = !last || now.getTime() - new Date(last.verifiedAt).getTime() > 36 * 3600_000;
        add({ key: 'backups.stale', severity: 'critical', title: last ? 'No verified backup in the last 36 hours' : 'No verified backup yet', count: stale ? 1 : 0, link: '/system/backups' });
        add({ key: 'backups.failed', severity: 'warning', title: 'Backups failed since the last verified one', count: failed, link: '/system/backups' });
      });
    }
    if (can('system', 'view', 'organization')) {
      run(async () => {
        const rows = await this.jobRuns.aggregate([{ $sort: { startedAt: -1 } }, { $group: { _id: '$job', status: { $first: '$status' } } }, { $match: { status: 'failed' } }]);
        add({ key: 'system.jobs_failed', severity: 'warning', title: 'Background jobs failing', detail: rows.map((r: any) => r._id).join(', '), count: rows.length, link: '/system' });
      });
    }

    await Promise.all(jobs);

    const snoozes = await this.snoozes.find({ organizationId: o, userId: ctx.userOid, until: { $gt: now } }).lean<any[]>();
    const snoozedKeys = new Set(snoozes.map((s) => s.itemKey));
    const order: Record<Severity, number> = { critical: 0, warning: 1, info: 2 };
    const visible = items.filter((i) => includeSnoozed || !i.snoozable || !snoozedKeys.has(i.key)).sort((a, b) => order[a.severity] - order[b.severity] || b.count - a.count);
    return { items: visible, snoozed: snoozes.map((s) => ({ key: s.itemKey, until: new Date(s.until).toISOString(), reason: s.reason })) };
  }

  async snooze(ctx: Ctx, key: string, hours: number, reason: string): Promise<void> {
    if (key.startsWith('security.alerts_high') || key.startsWith('backups.stale')) throw badRequest('NOT_SNOOZABLE', 'Critical items cannot be snoozed.');
    const until = new Date(Date.now() + hours * 3600_000);
    await this.snoozes.updateOne({ organizationId: ctx.orgOid, userId: ctx.userOid, itemKey: key }, { $set: { until, reason } }, { upsert: true });
    await this.audit.record(ctx, { action: 'attention.snooze', resourceType: 'attention', resourceId: key, changes: { until: { from: null, to: until }, reason: { from: null, to: reason } } });
  }

  async unsnooze(ctx: Ctx, key: string): Promise<void> {
    await this.snoozes.deleteOne({ organizationId: ctx.orgOid, userId: ctx.userOid, itemKey: key });
    await this.audit.record(ctx, { action: 'attention.unsnooze', resourceType: 'attention', resourceId: key });
  }
}

export function shiftDay(day: string, delta: number): string {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10);
}

