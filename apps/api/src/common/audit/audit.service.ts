import { Injectable, Logger } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { InjectModel } from '../../database/model';
import type { Ctx } from '../auth/context';

/** Fields never written to audit logs (secrets, codes, tokens, raw bank data). */
const SECRET_FIELDS = /(password|otp|code|token|secret|hash|recovery|accountNumber|panEnc|uanEnc|refresh)/i;

export interface AuditInput {
  action: string; // e.g. "leave.approve", "employee.update"
  resourceType: string;
  resourceId?: unknown;
  outcome?: 'success' | 'failure' | 'denied';
  changes?: Record<string, { from: unknown; to: unknown }>;
}

/** Computes changed-field metadata between two plain objects (top-level and one nested level). */
export function diff(before: Record<string, any> | null | undefined, after: Record<string, any>, fields?: string[]): Record<string, { from: unknown; to: unknown }> {
  const out: Record<string, { from: unknown; to: unknown }> = {};
  const keys = fields ?? Object.keys(after);
  for (const k of keys) {
    if (SECRET_FIELDS.test(k) || k === 'updatedAt' || k === 'createdAt') continue;
    const a = before?.[k];
    const b = after[k];
    if (JSON.stringify(a ?? null) !== JSON.stringify(b ?? null)) out[k] = { from: redact(k, a), to: redact(k, b) };
  }
  return out;
}

function redact(key: string, v: unknown): unknown {
  if (SECRET_FIELDS.test(key)) return '[redacted]';
  if (v && typeof v === 'object' && !Array.isArray(v) && !(v instanceof Date) && !(v instanceof Types.ObjectId)) {
    const o: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v)) o[k] = SECRET_FIELDS.test(k) ? '[redacted]' : val;
    return o;
  }
  return v;
}

/** MongoDB field names must not contain "." or start with "$": dotted paths become "a › b". */
export function safeKeys(changes: Record<string, { from: unknown; to: unknown }>): Record<string, { from: unknown; to: unknown }> {
  const out: Record<string, { from: unknown; to: unknown }> = {};
  for (const [k, v] of Object.entries(changes)) out[k.replace(/\./g, ' › ').replace(/^\$/, '＄')] = v;
  return out;
}

/** Append-only audit trail. Failing to write an audit record is logged loudly but never breaks the request. */
@Injectable()
export class AuditService {
  private readonly logger = new Logger('Audit');

  constructor(@InjectModel('AuditLog') private readonly logs: Model<any>) {}

  async record(ctx: Ctx | null, input: AuditInput, orgId?: Types.ObjectId | string): Promise<void> {
    try {
      await this.logs.create({
        organizationId: ctx?.orgOid ?? (orgId ? new Types.ObjectId(String(orgId)) : undefined),
        actorId: ctx?.userOid,
        actorName: ctx?.user.name,
        action: input.action,
        resourceType: input.resourceType,
        resourceId: input.resourceId != null ? String(input.resourceId) : undefined,
        outcome: input.outcome ?? 'success',
        changes: input.changes && Object.keys(input.changes).length ? safeKeys(input.changes) : undefined,
        correlationId: ctx?.correlationId,
        sessionId: ctx?.user.sessionId,
        ip: ctx?.ip,
        at: new Date(),
      });
    } catch (e) {
      this.logger.error(`Audit write failed for ${input.action}: ${(e as Error).message}`);
    }
  }
}
