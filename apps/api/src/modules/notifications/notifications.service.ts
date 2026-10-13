import { Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import type { Ctx } from '../../common/auth/context';
import { badRequest, ListQuery, notFound, oid, Paged } from '../../common/http/validation';
import { MailService } from '../../common/mail/mail.service';
import { OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { JobsService } from '../system/jobs.service';
import { RealtimeService } from './realtime.service';

/** Structure section 20 events. */
export const NOTIFICATION_EVENTS = [
  'invitation_created',
  'security_alert',
  'attendance_reminder',
  'attendance_exception',
  'leave_submitted',
  'leave_decided',
  'expense_submitted',
  'expense_decided',
  'task_assigned',
  'task_overdue',
  'meeting_scheduled',
  'document_ack_required',
  'approval_pending',
  'approval_decided',
  'payroll_finalized',
  'payslip_available',
  'backup_failure',
  'storage_warning',
  'system_incident',
  'moderation_escalation',
  'announcement',
  'kudos',
  'lead_assigned',
  'follow_up_due',
  'travel_decided',
] as const;
export type NotificationEvent = (typeof NOTIFICATION_EVENTS)[number] | string;
export const CHANNELS = ['in_app', 'email', 'push', 'whatsapp', 'sms'] as const;

const EMAIL_BY_DEFAULT = new Set(['security_alert', 'approval_pending', 'leave_decided', 'expense_decided', 'payslip_available', 'backup_failure', 'system_incident', 'document_ack_required', 'travel_decided']);

export interface NotifyInput {
  event: NotificationEvent;
  title: string;
  body?: string;
  link?: string;
  priority?: 'normal' | 'high' | 'essential';
  data?: Record<string, unknown>;
}

@Injectable()
export class NotificationsService {
  private readonly logger = new Logger('Notifications');

  constructor(
    private readonly realtime: RealtimeService,
    private readonly mail: MailService,
    private readonly orgSettings: OrgSettingsService,
    private readonly jobs: JobsService,
    @InjectModel('Notification') private readonly notifications: Model<any>,
    @InjectModel('NotificationPreference') private readonly prefs: Model<any>,
    @InjectModel('NotificationTemplate') private readonly templates: Model<any>,
    @InjectModel('NotificationDelivery') private readonly deliveries: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  private async isEssential(orgId: Types.ObjectId, input: NotifyInput): Promise<boolean> {
    if (input.priority === 'essential') return true;
    const org = await this.orgSettings.get(orgId);
    return (org?.settings?.notifications?.essentialEvents ?? []).includes(input.event);
  }

  /** Sends to each user on their enabled channels. Essential events ignore opt-outs. Never throws. */
  async notify(orgId: Types.ObjectId, userIds: (Types.ObjectId | string)[], input: NotifyInput): Promise<void> {
    try {
      const unique = [...new Set(userIds.filter(Boolean).map(String))].map((i) => new Types.ObjectId(i));
      if (!unique.length) return;
      const essential = await this.isEssential(orgId, input);
      const prefRows = await this.prefs.find({ organizationId: orgId, userId: { $in: unique } }).lean<any[]>();
      const prefBy = new Map(prefRows.map((p) => [String(p.userId), p.channels ?? {}]));
      for (const userId of unique) {
        const ch = prefBy.get(String(userId))?.[input.event] ?? {};
        const inApp = essential || ch.in_app !== false;
        const email = essential ? true : (ch.email ?? EMAIL_BY_DEFAULT.has(String(input.event)));
        let notificationId: Types.ObjectId | undefined;
        if (inApp) {
          const n = await this.notifications.create({ organizationId: orgId, userId, event: input.event, title: input.title, body: input.body, link: input.link, priority: input.priority ?? 'normal', data: input.data });
          notificationId = n._id;
          this.realtime.toUser(String(userId), 'notification', serialize(n.toObject()));
          await this.deliveries.create({ organizationId: orgId, notificationId, userId, event: input.event, channel: 'in_app', status: 'sent', attempts: 1, sentAt: new Date() });
        }
        if (email) {
          await this.deliveries.create({ organizationId: orgId, notificationId, userId, event: input.event, channel: 'email', status: 'queued', nextAttemptAt: new Date() });
        }
      }
      if (unique.length) void this.deliverQueued().catch(() => undefined);
    } catch (e) {
      this.logger.error(`notify(${input.event}) failed: ${(e as Error).message}`);
    }
  }

  /** Email worker with retries (5 attempts, exponential backoff). Content is rebuilt, never stored in logs. */
  @Cron('*/1 * * * *')
  async deliverQueued(): Promise<void> {
    await this.jobs.run('notifications.deliver', async () => {
      const due = await this.deliveries.find({ channel: 'email', status: 'queued', nextAttemptAt: { $lte: new Date() } }).limit(50).lean<any[]>();
      let sent = 0;
      for (const d of due) {
        const claimed = await this.deliveries.findOneAndUpdate({ _id: d._id, status: 'queued', attempts: d.attempts }, { $inc: { attempts: 1 }, $set: { nextAttemptAt: new Date(Date.now() + 60_000) } });
        if (!claimed) continue;
        try {
          const [user, n] = await Promise.all([this.users.findById(d.userId, { email: 1, fullName: 1 }).lean<any>(), d.notificationId ? this.notifications.findById(d.notificationId).lean<any>() : null]);
          if (!this.mail.canSend) {
            await this.deliveries.updateOne({ _id: d._id }, { $set: { status: 'skipped', error: 'email_not_configured' } });
            continue;
          }
          if (!user?.email || !n) {
            await this.deliveries.updateOne({ _id: d._id }, { $set: { status: 'skipped', error: 'no_email_or_content' } });
            continue;
          }
          const tpl = await this.templates.findOne({ organizationId: d.organizationId, event: d.event, channel: 'email', active: true }).lean<any>();
          const vars: Record<string, string> = { name: user.fullName, title: n.title, body: n.body ?? '', link: n.link ?? '' };
          const fill = (s: string) => s.replace(/\{\{(\w+)\}\}/g, (_m, k) => vars[k] ?? '');
          await this.mail.send({ to: user.email, subject: tpl?.subject ? fill(tpl.subject) : n.title, text: tpl?.body ? fill(tpl.body) : `${n.title}\n\n${n.body ?? ''}` });
          await this.deliveries.updateOne({ _id: d._id }, { $set: { status: 'sent', sentAt: new Date(), error: null } });
          sent++;
        } catch (e) {
          const attempts = d.attempts + 1;
          await this.deliveries.updateOne(
            { _id: d._id },
            attempts >= 5
              ? { $set: { status: 'failed', error: (e as Error).message.slice(0, 200) } }
              : { $set: { status: 'queued', error: (e as Error).message.slice(0, 200), nextAttemptAt: new Date(Date.now() + 2 ** attempts * 60_000) } },
          );
        }
      }
      return `${sent}/${due.length} sent`;
    });
  }

  // ------------------------------------------------------------------ user-facing

  async list(ctx: Ctx, q: ListQuery & { unread?: boolean }): Promise<Paged<any> & { unread: number }> {
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid, userId: ctx.userOid };
    if (q.unread) filter.readAt = null;
    const [items, total, unread] = await Promise.all([
      this.notifications.find(filter).sort({ createdAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean(),
      this.notifications.countDocuments(filter),
      this.notifications.countDocuments({ organizationId: ctx.orgOid, userId: ctx.userOid, readAt: null }),
    ]);
    return { items: serialize(items), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total, unread };
  }

  async markRead(ctx: Ctx, ids: string[] | 'all'): Promise<{ unread: number }> {
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid, userId: ctx.userOid, readAt: null };
    if (ids !== 'all') filter._id = { $in: ids.map(oid) };
    await this.notifications.updateMany(filter, { $set: { readAt: new Date() } });
    const unread = await this.notifications.countDocuments({ organizationId: ctx.orgOid, userId: ctx.userOid, readAt: null });
    this.realtime.toUser(ctx.user.userId, 'notification:unread', { unread });
    return { unread };
  }

  async getPreferences(ctx: Ctx): Promise<any> {
    const p = await this.prefs.findOne({ organizationId: ctx.orgOid, userId: ctx.userOid }).lean<any>();
    const org = await this.orgSettings.get(ctx.orgOid);
    const essential: string[] = org?.settings?.notifications?.essentialEvents ?? [];
    return {
      events: NOTIFICATION_EVENTS.map((e) => ({
        event: e,
        essential: essential.includes(e),
        channels: { in_app: p?.channels?.[e]?.in_app ?? true, email: p?.channels?.[e]?.email ?? EMAIL_BY_DEFAULT.has(e) },
      })),
      availableChannels: ['in_app', 'email', ...(this.mail.configured ? [] : [])],
    };
  }

  async setPreferences(ctx: Ctx, channels: Record<string, Record<string, boolean>>): Promise<any> {
    const org = await this.orgSettings.get(ctx.orgOid);
    const essential: string[] = org?.settings?.notifications?.essentialEvents ?? [];
    const clean: Record<string, Record<string, boolean>> = {};
    for (const [event, ch] of Object.entries(channels)) {
      if (!NOTIFICATION_EVENTS.includes(event as any)) throw badRequest('UNKNOWN_EVENT', `Unknown event ${event}.`);
      // Essential security and system notices can't be switched off.
      clean[event] = essential.includes(event) ? { in_app: true, email: true } : { in_app: ch.in_app !== false, email: !!ch.email };
    }
    await this.prefs.updateOne({ organizationId: ctx.orgOid, userId: ctx.userOid }, { $set: { channels: clean } }, { upsert: true });
    return this.getPreferences(ctx);
  }

  async deliveryHistory(ctx: Ctx, q: ListQuery): Promise<Paged<any>> {
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!ctx.authz.can('notifications', 'configure')) filter.userId = ctx.userOid;
    if (q.status) filter.status = q.status;
    const [items, total] = await Promise.all([
      this.deliveries.find(filter).sort({ createdAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean(),
      this.deliveries.countDocuments(filter),
    ]);
    return { items: serialize(items), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  async templatesList(ctx: Ctx): Promise<any[]> {
    return serialize(await this.templates.find({ organizationId: ctx.orgOid }).sort({ event: 1 }).lean());
  }

  async upsertTemplate(ctx: Ctx, t: { event: string; channel: string; subject?: string; body: string; active?: boolean }): Promise<any> {
    const doc = await this.templates.findOneAndUpdate({ organizationId: ctx.orgOid, event: t.event, channel: t.channel }, { $set: { subject: t.subject, body: t.body, active: t.active ?? true } }, { upsert: true, new: true }).lean();
    return serialize(doc);
  }

  async deleteTemplate(ctx: Ctx, id: string): Promise<void> {
    const r = await this.templates.deleteOne({ _id: oid(id), organizationId: ctx.orgOid });
    if (!r.deletedCount) throw notFound('Template');
  }

  /** Delivery health for system checks: failure rate over the last hour. */
  async deliveryStats(): Promise<{ sent: number; failed: number; queued: number }> {
    const since = new Date(Date.now() - 3600_000);
    const [sent, failed, queued] = await Promise.all([
      this.deliveries.countDocuments({ channel: 'email', status: 'sent', updatedAt: { $gt: since } }),
      this.deliveries.countDocuments({ channel: 'email', status: 'failed', updatedAt: { $gt: since } }),
      this.deliveries.countDocuments({ channel: 'email', status: 'queued', nextAttemptAt: { $lt: new Date(Date.now() - 15 * 60_000) } }),
    ]);
    return { sent, failed, queued };
  }
}
