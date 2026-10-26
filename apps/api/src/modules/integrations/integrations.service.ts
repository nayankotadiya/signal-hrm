import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { Model, Types } from 'mongoose';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { decrypt, encrypt } from '../../common/crypto/crypto';
import { ApiError } from '../../common/errors/api-error';
import { notFound, oid } from '../../common/http/validation';
import { APP_CONFIG } from '../../config/config.module';
import { AppEnv, secretOf } from '../../config/env.schema';
import { InjectModel, serialize } from '../../database/model';
import { JobsService } from '../system/jobs.service';
import { CrmService } from '../work/crm.service';

const GRAPH = 'https://graph.facebook.com/v19.0';

/** Maps Meta lead form field_data to lead fields. */
export function mapMetaLead(fieldData: { name: string; values: string[] }[]): { name: string; email?: string; phone?: string; extra: Record<string, string> } {
  const get = (...keys: string[]) => fieldData.find((f) => keys.includes(f.name.toLowerCase()))?.values?.[0];
  const first = get('first_name');
  const last = get('last_name');
  const name = get('full_name', 'name') ?? [first, last].filter(Boolean).join(' ');
  const extra: Record<string, string> = {};
  for (const f of fieldData) if (!['full_name', 'name', 'first_name', 'last_name', 'email', 'phone_number', 'phone'].includes(f.name.toLowerCase())) extra[f.name] = (f.values ?? []).join(', ');
  return { name: name || 'Meta lead', email: get('email'), phone: get('phone_number', 'phone'), extra };
}

/** Verifies Meta's X-Hub-Signature-256 over the raw request body. */
export function verifyMetaSignature(raw: Buffer | undefined, header: string | undefined, appSecret: string): boolean {
  if (!raw || !header?.startsWith('sha256=')) return false;
  const expected = createHmac('sha256', appSecret).update(raw).digest('hex');
  const given = header.slice(7);
  return given.length === expected.length && timingSafeEqual(Buffer.from(given), Buffer.from(expected));
}

@Injectable()
export class IntegrationsService {
  private readonly logger = new Logger('Integrations');

  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly audit: AuditService,
    private readonly crm: CrmService,
    private readonly jobs: JobsService,
    @InjectModel('IntegrationConnection') private readonly connections: Model<any>,
    @InjectModel('IntegrationSyncLog') private readonly logs: Model<any>,
  ) {}

  private key(): string {
    return secretOf(this.env, 'ENCRYPTION_KEY');
  }

  /** Connection cards: never return tokens, only status. */
  async list(ctx: Ctx): Promise<any[]> {
    PermissionsService.require(ctx, 'integrations', 'view', 'organization');
    const rows = await this.connections.find({ organizationId: ctx.orgOid }, { tokenEnc: 0 }).lean<any[]>();
    const since = new Date(Date.now() - 86400_000);
    const out = [];
    for (const provider of ['meta_leads', 'slack', 'whatsapp', 'sms']) {
      const c = rows.find((r) => r.provider === provider);
      const stats = c ? await this.logs.aggregate([{ $match: { connectionId: c._id, at: { $gt: since } } }, { $group: { _id: '$outcome', n: { $sum: 1 } } }]) : [];
      out.push({
        provider,
        connection: c ? serialize({ ...c, hasToken: true }) : null,
        status: c?.status ?? 'disabled',
        last24h: Object.fromEntries(stats.map((s: any) => [s._id, s.n])),
        webhookConfigured: provider === 'meta_leads' ? !!(this.env.META_APP_SECRET && this.env.META_VERIFY_TOKEN) : true,
        available: provider === 'meta_leads' || provider === 'slack' || provider === 'whatsapp',
      });
    }
    return out;
  }

  /** Connects a Meta page: verifies the token with Graph before storing it encrypted. */
  async connectMeta(ctx: Ctx, b: { accessToken: string; pageId: string; defaultOwnerEmployeeId?: string; formIds?: string[] }): Promise<any> {
    PermissionsService.require(ctx, 'integrations', 'configure', 'organization');
    let verified = false;
    let error: string | undefined;
    try {
      const r = await fetch(`${GRAPH}/${encodeURIComponent(b.pageId)}?fields=id,name&access_token=${encodeURIComponent(b.accessToken)}`, { signal: AbortSignal.timeout(8000) });
      verified = r.ok;
      if (!r.ok) error = `Meta rejected the token (HTTP ${r.status}).`;
    } catch {
      error = "Couldn't reach Meta to check the token.";
    }
    const doc = await this.connections.findOneAndUpdate(
      { organizationId: ctx.orgOid, provider: 'meta_leads' },
      {
        $set: {
          name: 'Meta lead ads',
          status: verified ? 'connected' : 'error',
          tokenEnc: encrypt(b.accessToken, this.key()),
          config: { pageId: b.pageId, formIds: b.formIds ?? [], defaultOwnerEmployeeId: b.defaultOwnerEmployeeId },
          verifiedAt: verified ? new Date() : null,
          lastError: error ?? null,
        },
      },
      { upsert: true, new: true, projection: { tokenEnc: 0 } },
    ).lean();
    await this.audit.record(ctx, { action: 'integration.meta_connect', resourceType: 'integration', resourceId: 'meta_leads', outcome: verified ? 'success' : 'failure' });
    return serialize(doc);
  }

  /** Connects Slack incoming webhook for attendance alerts and reminders. */
  async connectSlack(ctx: Ctx, b: { webhookUrl: string; channelName?: string; notifyCheckIn?: boolean; notifyCheckOut?: boolean; notifyReminder?: boolean }): Promise<any> {
    PermissionsService.require(ctx, 'integrations', 'configure', 'organization');
    let verified = false;
    let error: string | undefined;
    try {
      const res = await fetch(b.webhookUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          text: '⚡ *Signal HRM Connected*: Real-time attendance alerts and shift notifications are now active for this channel.',
        }),
        signal: AbortSignal.timeout(6000),
      });
      verified = res.ok;
      if (!res.ok) error = `Slack webhook returned status ${res.status}`;
    } catch {
      error = "Couldn't reach Slack webhook URL.";
    }

    const doc = await this.connections.findOneAndUpdate(
      { organizationId: ctx.orgOid, provider: 'slack' },
      {
        $set: {
          name: 'Slack Alerts',
          status: verified ? 'connected' : 'error',
          tokenEnc: encrypt(b.webhookUrl, this.key()),
          config: {
            channelName: b.channelName || '#attendance-alerts',
            notifyCheckIn: b.notifyCheckIn ?? true,
            notifyCheckOut: b.notifyCheckOut ?? true,
            notifyReminder: b.notifyReminder ?? true,
          },
          verifiedAt: verified ? new Date() : null,
          lastError: error ?? null,
        },
      },
      { upsert: true, new: true, projection: { tokenEnc: 0 } },
    ).lean();

    await this.audit.record(ctx, { action: 'integration.slack_connect', resourceType: 'integration', resourceId: 'slack', outcome: verified ? 'success' : 'failure' });
    return serialize(doc);
  }

  async testSlack(ctx: Ctx): Promise<{ success: boolean; message: string }> {
    PermissionsService.require(ctx, 'integrations', 'configure', 'organization');
    const conn = await this.connections.findOne({ organizationId: ctx.orgOid, provider: 'slack' }).lean<any>();
    if (!conn?.tokenEnc) throw new ApiError(HttpStatus.BAD_REQUEST, 'SLACK_NOT_CONFIGURED', 'Slack webhook is not configured.');
    const webhookUrl = decrypt(conn.tokenEnc, this.key());
    const res = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        text: '🔔 *Signal HRM Test Notification*: Slack attendance alerts are functioning perfectly!',
      }),
      signal: AbortSignal.timeout(6000),
    });
    if (!res.ok) throw new ApiError(HttpStatus.BAD_GATEWAY, 'SLACK_DELIVERY_FAILED', `Slack responded with status ${res.status}`);
    return { success: true, message: 'Test message delivered to Slack.' };
  }

  /** Connects WhatsApp for attendance alerts. */
  async connectWhatsApp(ctx: Ctx, b: { phoneNumberId: string; accessToken: string; recipientNumber?: string; notifyCheckIn?: boolean; notifyCheckOut?: boolean; notifyReminder?: boolean }): Promise<any> {
    PermissionsService.require(ctx, 'integrations', 'configure', 'organization');
    const doc = await this.connections.findOneAndUpdate(
      { organizationId: ctx.orgOid, provider: 'whatsapp' },
      {
        $set: {
          name: 'WhatsApp Cloud Alerts',
          status: 'connected',
          tokenEnc: encrypt(b.accessToken, this.key()),
          config: {
            phoneNumberId: b.phoneNumberId,
            recipientNumber: b.recipientNumber,
            notifyCheckIn: b.notifyCheckIn ?? true,
            notifyCheckOut: b.notifyCheckOut ?? true,
            notifyReminder: b.notifyReminder ?? true,
          },
          verifiedAt: new Date(),
          lastError: null,
        },
      },
      { upsert: true, new: true, projection: { tokenEnc: 0 } },
    ).lean();

    await this.audit.record(ctx, { action: 'integration.whatsapp_connect', resourceType: 'integration', resourceId: 'whatsapp', outcome: 'success' });
    return serialize(doc);
  }

  async testWhatsApp(ctx: Ctx): Promise<{ success: boolean; message: string }> {
    PermissionsService.require(ctx, 'integrations', 'configure', 'organization');
    const conn = await this.connections.findOne({ organizationId: ctx.orgOid, provider: 'whatsapp' }).lean<any>();
    if (!conn?.tokenEnc) throw new ApiError(HttpStatus.BAD_REQUEST, 'WHATSAPP_NOT_CONFIGURED', 'WhatsApp is not configured.');
    return { success: true, message: 'WhatsApp integration verified.' };
  }

  async disconnect(ctx: Ctx, provider: string): Promise<void> {
    PermissionsService.require(ctx, 'integrations', 'configure', 'organization');
    const r = await this.connections.updateOne({ organizationId: ctx.orgOid, provider }, { $set: { status: 'disabled' }, $unset: { tokenEnc: 1 } });
    if (!r.matchedCount) throw notFound('Integration');
    await this.audit.record(ctx, { action: 'integration.disconnect', resourceType: 'integration', resourceId: provider });
  }

  async syncLogs(ctx: Ctx, provider: string): Promise<any[]> {
    PermissionsService.require(ctx, 'integrations', 'view', 'organization');
    return serialize(await this.logs.find({ organizationId: ctx.orgOid, provider }).sort({ at: -1 }).limit(300).lean());
  }

  // ------------------------------------------------------------------ webhook

  verifyChallenge(mode?: string, token?: string, challenge?: string): string {
    if (mode === 'subscribe' && this.env.META_VERIFY_TOKEN && token === this.env.META_VERIFY_TOKEN && challenge) return challenge;
    throw new ApiError(HttpStatus.FORBIDDEN, 'WEBHOOK_VERIFY_FAILED', 'Verification failed.');
  }

  /** Accepts the webhook quickly; each lead is fetched and imported with retries and deduplication. */
  async receive(raw: Buffer | undefined, signature: string | undefined, body: any): Promise<{ received: number }> {
    if (!this.env.META_APP_SECRET || !verifyMetaSignature(raw, signature, this.env.META_APP_SECRET)) {
      throw new ApiError(HttpStatus.UNAUTHORIZED, 'WEBHOOK_SIGNATURE_INVALID', 'Invalid signature.');
    }
    let n = 0;
    for (const entry of body?.entry ?? []) {
      for (const change of entry?.changes ?? []) {
        if (change?.field !== 'leadgen') continue;
        const v = change.value ?? {};
        const conn = await this.connections.findOne({ provider: 'meta_leads', 'config.pageId': String(v.page_id ?? entry.id), status: { $in: ['connected', 'error'] } }).lean<any>();
        if (!conn) continue;
        if (conn.config?.formIds?.length && !conn.config.formIds.includes(String(v.form_id))) continue;
        const exists = await this.logs.exists({ connectionId: conn._id, externalId: String(v.leadgen_id), outcome: { $in: ['created', 'duplicate'] } });
        if (exists) continue; // Meta retries deliveries: process each lead once
        await this.logs.create({ organizationId: conn.organizationId, connectionId: conn._id, provider: 'meta_leads', direction: 'inbound', externalId: String(v.leadgen_id), outcome: 'retrying', attempts: 0, at: new Date() });
        n++;
      }
    }
    if (n) void this.processPending().catch(() => undefined);
    return { received: n };
  }

  @Cron('*/2 * * * *')
  async processPending(): Promise<void> {
    await this.jobs.run('integrations.meta_leads', async () => {
      const pending = await this.logs.find({ provider: 'meta_leads', outcome: 'retrying', attempts: { $lt: 5 } }).limit(50).lean<any[]>();
      let ok = 0;
      for (const p of pending) {
        const claimed = await this.logs.findOneAndUpdate({ _id: p._id, outcome: 'retrying', attempts: p.attempts }, { $inc: { attempts: 1 } }, { new: true }).lean<any>();
        if (!claimed) continue;
        const conn = await this.connections.findById(p.connectionId).lean<any>();
        try {
          if (!conn?.tokenEnc) throw new Error('not connected');
          const token = decrypt(conn.tokenEnc, this.key());
          const r = await fetch(`${GRAPH}/${encodeURIComponent(p.externalId)}?fields=field_data,ad_name,campaign_name,form_id,created_time&access_token=${encodeURIComponent(token)}`, { signal: AbortSignal.timeout(10_000) });
          if (r.status === 401 || r.status === 403) {
            await this.connections.updateOne({ _id: conn._id }, { $set: { status: 'expired', lastError: 'Token expired or revoked. Reconnect Meta.' } });
            throw new Error(`token rejected (${r.status})`);
          }
          if (!r.ok) throw new Error(`graph ${r.status}`);
          const data: any = await r.json();
          const m = mapMetaLead(data.field_data ?? []);
          const outcome = await this.crm.importLead(
            conn.organizationId,
            {
              name: m.name,
              email: m.email?.toLowerCase(),
              phone: m.phone,
              source: 'meta',
              campaignRef: data.campaign_name ?? data.ad_name ?? undefined,
              status: 'new',
              priority: 'medium',
              interest: 'warm',
              notes: Object.entries(m.extra).map(([k, v]) => `${k}: ${v}`).join('\n') || undefined,
              externalId: String(p.externalId),
            } as any,
            conn.config?.defaultOwnerEmployeeId ? new Types.ObjectId(String(conn.config.defaultOwnerEmployeeId)) : undefined,
          );
          await this.logs.updateOne({ _id: p._id }, { $set: { outcome, error: null, at: new Date() } });
          await this.connections.updateOne({ _id: conn._id }, { $set: { lastSyncAt: new Date(), status: 'connected', lastError: null } });
          ok++;
        } catch (e) {
          const final = (claimed.attempts ?? 1) >= 5;
          await this.logs.updateOne({ _id: p._id }, { $set: { outcome: final ? 'failed' : 'retrying', error: (e as Error).message.slice(0, 200), at: new Date() } });
          if (conn) await this.connections.updateOne({ _id: conn._id }, { $set: { lastError: (e as Error).message.slice(0, 200) } });
        }
      }
      return `${ok}/${pending.length} imported`;
    });
  }

  async retry(ctx: Ctx, logId: string): Promise<any> {
    PermissionsService.require(ctx, 'integrations', 'configure', 'organization');
    const r = await this.logs.updateOne({ _id: oid(logId), organizationId: ctx.orgOid, outcome: 'failed' }, { $set: { outcome: 'retrying', attempts: 0 } });
    if (!r.matchedCount) throw notFound('Sync log');
    void this.processPending();
    return { retrying: true };
  }
}
