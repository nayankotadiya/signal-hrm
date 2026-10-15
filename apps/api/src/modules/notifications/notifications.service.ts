import { Inject, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import * as webpush from 'web-push';
import type { Ctx } from '../../common/auth/context';
import { badRequest, ListQuery, notFound, oid, Paged } from '../../common/http/validation';
import { MailService } from '../../common/mail/mail.service';
import { OrgSettingsService } from '../../common/org/org-settings.service';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
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
  'database_storage_critical',
  'attendance_checkout_reminder',
  'attendance_check_in',
  'attendance_check_out',
] as const;
export type NotificationEvent = (typeof NOTIFICATION_EVENTS)[number] | string;
export const CHANNELS = ['in_app', 'email', 'push', 'whatsapp', 'sms'] as const;

export const EMAIL_BY_DEFAULT = new Set([
  'security_alert',
  'approval_pending',
  'leave_submitted',
  'leave_decided',
  'expense_decided',
  'payslip_available',
  'backup_failure',
  'system_incident',
  'document_ack_required',
  'travel_decided',
  'database_storage_critical',
  'attendance_checkout_reminder',
  'attendance_check_in',
  'attendance_check_out',
  'task_assigned',
  'meeting_scheduled',
  'announcement',
]);

export function getEventEmailStyle(event: string): { badge: string; badgeColor: string; badgeBg: string; linkText: string } {
  switch (event) {
    case 'attendance_check_in':
      return { badge: 'Check-In Confirmed', badgeColor: '#166534', badgeBg: '#dcfce7', linkText: 'View Attendance' };
    case 'attendance_check_out':
      return { badge: 'Check-Out Confirmed', badgeColor: '#1e40af', badgeBg: '#dbeafe', linkText: 'View Attendance Summary' };
    case 'attendance_checkout_reminder':
      return { badge: '7:00 PM Check-Out Reminder', badgeColor: '#b45309', badgeBg: '#fef3c7', linkText: 'Check Out Now' };
    case 'attendance_reminder':
      return { badge: 'Attendance Reminder', badgeColor: '#b45309', badgeBg: '#fef3c7', linkText: 'Open Attendance' };
    case 'leave_submitted':
      return { badge: 'Leave Submitted', badgeColor: '#6b21a8', badgeBg: '#f3e8ff', linkText: 'View Leave Request' };
    case 'leave_decided':
      return { badge: 'Leave Status Update', badgeColor: '#0369a1', badgeBg: '#e0f2fe', linkText: 'View Leaves' };
    case 'payroll_finalized':
    case 'payslip_available':
      return { badge: 'Payroll & Payslip', badgeColor: '#047857', badgeBg: '#d1fae5', linkText: 'View Payslip' };
    case 'task_assigned':
    case 'task_overdue':
      return { badge: 'Task Notification', badgeColor: '#4338ca', badgeBg: '#e0e7ff', linkText: 'View Task' };
    case 'security_alert':
    case 'system_incident':
      return { badge: 'Security Notice', badgeColor: '#b91c1c', badgeBg: '#fee2e2', linkText: 'Review Security Alert' };
    case 'announcement':
      return { badge: 'Company Announcement', badgeColor: '#0f172a', badgeBg: '#f1f5f9', linkText: 'Read Announcement' };
    default:
      return {
        badge: event.replace(/_/g, ' ').toUpperCase(),
        badgeColor: '#e50914',
        badgeBg: '#fee2e2',
        linkText: 'Open in HRM',
      };
  }
}

export function buildBulletproofEmailHtml(opts: {
  title: string;
  body?: string;
  badge?: string;
  badgeColor?: string;
  badgeBg?: string;
  link?: string;
  linkText?: string;
  recipientName?: string;
  recipientEmail?: string;
  publicWebUrl?: string;
}): string {
  const badgeText = opts.badge || 'Notification';
  const badgeColor = opts.badgeColor || '#e50914';
  const badgeBg = opts.badgeBg || '#fee2e2';
  const linkText = opts.linkText || 'Open in Bulletproof HRM';
  const year = new Date().getFullYear();
  const ctaUrl = opts.link
    ? `${opts.publicWebUrl || ''}${opts.link.startsWith('/') ? '' : '/'}${opts.link}`
    : null;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${opts.title}</title>
</head>
<body style="margin: 0; padding: 0; background-color: #f1f5f9; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; -webkit-font-smoothing: antialiased;">
  <table role="presentation" width="100%" border="0" cellspacing="0" cellpadding="0" style="background-color: #f1f5f9; padding: 32px 16px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" border="0" cellspacing="0" cellpadding="0" style="max-width: 580px; background-color: #ffffff; border-radius: 16px; overflow: hidden; box-shadow: 0 4px 20px rgba(0, 0, 0, 0.06); border: 1px solid #e2e8f0;">
          <tr>
            <td style="background-color: #0b0f19; padding: 26px 32px; text-align: center; border-bottom: 3px solid #e50914;">
              <a href="https://bulletproofbrands.in" target="_blank" style="text-decoration: none; display: inline-block;">
                <img src="https://bulletproofbrands.in/cdn/shop/files/bpb-brand-logo_png.png?v=1790428996" alt="Bulletproof Brands" width="220" style="display: block; max-width: 220px; height: auto; border: 0; margin: 0 auto;" />
              </a>
              <div style="margin-top: 8px; font-size: 11px; font-weight: 700; letter-spacing: 2px; color: #94a3b8; text-transform: uppercase;">
                IMPOSSIBLE TO IGNORE
              </div>
            </td>
          </tr>
          <tr>
            <td style="padding: 36px 32px 28px 32px;">
              <div style="margin-bottom: 18px;">
                <span style="display: inline-block; padding: 5px 12px; background: ${badgeBg}; color: ${badgeColor}; border-radius: 6px; font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;">${badgeText}</span>
              </div>
              <h1 style="margin: 0 0 16px 0; color: #0f172a; font-size: 20px; font-weight: 700; line-height: 1.4;">${opts.title}</h1>
              ${opts.body ? `<div style="font-size: 15px; color: #334155; line-height: 1.65; margin: 0 0 24px 0;">${opts.body.replace(/\n/g, '<br/>')}</div>` : ''}
              ${ctaUrl ? `<div style="margin: 28px 0 10px 0;">
                <a href="${ctaUrl}" style="display: inline-block; padding: 11px 24px; background: #0b0f19; color: #ffffff; text-decoration: none; border-radius: 8px; font-weight: 600; font-size: 14px; border: 1px solid #e50914; box-shadow: 0 2px 6px rgba(0,0,0,0.12);">${linkText} &rarr;</a>
              </div>` : ''}
            </td>
          </tr>
          <tr>
            <td style="background-color: #f8fafc; padding: 22px 32px; border-top: 1px solid #e2e8f0; text-align: center;">
              <p style="margin: 0 0 6px 0; color: #64748b; font-size: 12px; font-weight: 600;">
                Bulletproof Brands HRM &bull; Workforce Management
              </p>
              <p style="margin: 0; color: #94a3b8; font-size: 11px; line-height: 1.5;">
                This automated notification was sent to <strong style="color: #64748b;">${opts.recipientEmail || opts.recipientName || 'you'}</strong>.<br/>
                &copy; ${year} Bulletproof Brands. All rights reserved.
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

export interface NotifyInput {
  event: NotificationEvent;
  title: string;
  body?: string;
  link?: string;
  priority?: 'normal' | 'high' | 'essential';
  data?: Record<string, unknown>;
}

@Injectable()
export class NotificationsService implements OnModuleInit {
  private readonly logger = new Logger('Notifications');

  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly realtime: RealtimeService,
    private readonly mail: MailService,
    private readonly orgSettings: OrgSettingsService,
    private readonly jobs: JobsService,
    @InjectModel('Notification') private readonly notifications: Model<any>,
    @InjectModel('NotificationPreference') private readonly prefs: Model<any>,
    @InjectModel('NotificationTemplate') private readonly templates: Model<any>,
    @InjectModel('NotificationDelivery') private readonly deliveries: Model<any>,
    @InjectModel('PushSubscription') private readonly pushSubs: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  onModuleInit(): void {
    if (this.env.VAPID_PUBLIC_KEY && this.env.VAPID_PRIVATE_KEY) {
      try {
        webpush.setVapidDetails(this.env.VAPID_SUBJECT, this.env.VAPID_PUBLIC_KEY, this.env.VAPID_PRIVATE_KEY);
      } catch (err: any) {
        this.logger.warn(`Failed to initialize VAPID details: ${err.message}`);
      }
    }
  }

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
        const email = essential ? true : (ch.email !== undefined ? !!ch.email : EMAIL_BY_DEFAULT.has(input.event));
        const push = essential || ch.push !== false;
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
        if (push) {
          void this.sendWebPush(orgId, userId, input, notificationId).catch(() => undefined);
        }
      }
      if (unique.length) void this.deliverQueued().catch(() => undefined);
    } catch (e) {
      this.logger.error(`notify(${input.event}) failed: ${(e as Error).message}`);
    }
  }

  getVapidPublicKey(): { publicKey: string } {
    return { publicKey: this.env.VAPID_PUBLIC_KEY };
  }

  async subscribePush(
    ctx: Ctx,
    subscription: { endpoint: string; keys: { p256dh: string; auth: string }; userAgent?: string },
  ): Promise<{ success: boolean }> {
    await this.pushSubs.updateOne(
      { organizationId: ctx.orgOid, endpoint: subscription.endpoint },
      {
        $set: {
          organizationId: ctx.orgOid,
          userId: ctx.userOid,
          endpoint: subscription.endpoint,
          keys: subscription.keys,
          userAgent: subscription.userAgent,
          lastActiveAt: new Date(),
        },
      },
      { upsert: true },
    );
    return { success: true };
  }

  async unsubscribePush(ctx: Ctx, endpoint: string): Promise<{ success: boolean }> {
    await this.pushSubs.deleteOne({ organizationId: ctx.orgOid, endpoint, userId: ctx.userOid });
    return { success: true };
  }

  private async sendWebPush(
    orgId: Types.ObjectId,
    userId: Types.ObjectId,
    input: NotifyInput,
    notificationId?: Types.ObjectId,
  ): Promise<void> {
    const subs = await this.pushSubs.find({ organizationId: orgId, userId }).lean<any[]>();
    if (!subs.length) return;

    const payload = JSON.stringify({
      title: input.title,
      body: input.body ?? '',
      icon: '/icons/Icon-192.png',
      badge: '/icons/Icon-192.png',
      data: {
        link: input.link ?? '/notifications',
        event: input.event,
        notificationId: notificationId ? String(notificationId) : undefined,
      },
    });

    for (const sub of subs) {
      if (!sub.endpoint || !sub.keys?.p256dh || !sub.keys?.auth) continue;
      try {
        await webpush.sendNotification(
          {
            endpoint: sub.endpoint,
            keys: {
              p256dh: sub.keys.p256dh,
              auth: sub.keys.auth,
            },
          },
          payload,
        );
      } catch (err: any) {
        if (err.statusCode === 404 || err.statusCode === 410) {
          await this.pushSubs.deleteOne({ _id: sub._id }).catch(() => undefined);
        }
      }
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
          const vars: Record<string, string> = { name: user.fullName || user.email, title: n.title, body: n.body ?? '', link: n.link ?? '' };
          const fill = (s: string) => s.replace(/\{\{(\w+)\}\}/g, (_m, k) => vars[k] ?? '');
          const subject = tpl?.subject ? fill(tpl.subject) : `[Bulletproof Brands] ${n.title}`;
          const rawBody = tpl?.body ? fill(tpl.body) : (n.body ?? '');
          const text = `${n.title}\n\n${rawBody}${n.link ? `\n\nLink: ${this.env.PUBLIC_WEB_URL}${n.link.startsWith('/') ? '' : '/'}${n.link}` : ''}\n\nBulletproof Brands - IMPOSSIBLE TO IGNORE`;
          const style = getEventEmailStyle(d.event);
          const html = buildBulletproofEmailHtml({
            title: n.title,
            body: rawBody,
            badge: style.badge,
            badgeColor: style.badgeColor,
            badgeBg: style.badgeBg,
            link: n.link,
            linkText: style.linkText,
            recipientName: user.fullName,
            recipientEmail: user.email,
            publicWebUrl: this.env.PUBLIC_WEB_URL,
          });

          await this.mail.send({ to: user.email, subject, text, html });
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
      events: NOTIFICATION_EVENTS.map((e) => {
        const isEss = essential.includes(e);
        const stored = p?.channels?.[e];
        return {
          event: e,
          essential: isEss,
          channels: {
            in_app: isEss ? true : (stored?.in_app ?? true),
            email: isEss ? true : (stored?.email !== undefined ? stored.email : EMAIL_BY_DEFAULT.has(e)),
          },
        };
      }),
      availableChannels: ['in_app', 'email', ...(this.mail.configured ? [] : [])],
    };
  }

  async setPreferences(ctx: Ctx, channels: Record<string, Record<string, boolean>>): Promise<any> {
    const org = await this.orgSettings.get(ctx.orgOid);
    const essential: string[] = org?.settings?.notifications?.essentialEvents ?? [];
    const setUpdates: Record<string, any> = {};
    for (const [event, ch] of Object.entries(channels)) {
      if (!NOTIFICATION_EVENTS.includes(event as any)) continue;
      const isEss = essential.includes(event);
      if (ch.in_app !== undefined) {
        setUpdates[`channels.${event}.in_app`] = isEss ? true : !!ch.in_app;
      }
      if (ch.email !== undefined) {
        setUpdates[`channels.${event}.email`] = isEss ? true : !!ch.email;
      }
      if (ch.push !== undefined) {
        setUpdates[`channels.${event}.push`] = isEss ? true : !!ch.push;
      }
    }
    if (Object.keys(setUpdates).length > 0) {
      await this.prefs.updateOne(
        { organizationId: ctx.orgOid, userId: ctx.userOid },
        { $set: setUpdates },
        { upsert: true },
      );
    }
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
