import { HttpStatus, Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { ApiError } from '../../common/errors/api-error';
import { conflict, forbidden, notFound, oid } from '../../common/http/validation';
import { OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { NotificationsService } from '../notifications/notifications.service';
import { RealtimeService } from '../notifications/realtime.service';
import { JobsService } from '../system/jobs.service';

export type Decision = 'approve' | 'reject' | 'clarification';

/** Business modules register one handler per request type. Handlers must be idempotent. */
export interface ApprovalHandler {
  /** Runs before the approval is marked approved; throwing aborts the final approval with that error. */
  onApproved(approval: any, actor: Ctx | null): Promise<void>;
  onRejected(approval: any, actor: Ctx | null, comment?: string): Promise<void>;
  onClarification?(approval: any, actor: Ctx, comment?: string): Promise<void>;
  onCancelled?(approval: any, actor: Ctx): Promise<void>;
  /** Called when a stage completes but more remain (e.g. leave stays pending). */
  onStageAdvanced?(approval: any): Promise<void>;
}

export interface StartInput {
  requestType: string;
  requestId: Types.ObjectId;
  subjectEmployeeId?: Types.ObjectId;
  title: string;
  summary?: string;
  amount?: number;
  /** Values that rule matching and stage conditions read, e.g. { requireHr: true, leaveTypeId }. */
  attributes?: Record<string, unknown>;
  link?: string;
}

interface StageDef {
  name: string;
  approverType: 'manager' | 'department_head' | 'role' | 'users' | 'permission';
  role?: string;
  permission?: string;
  userIds?: Types.ObjectId[];
  mode?: 'single' | 'parallel_any' | 'parallel_all';
  condition?: { field?: string; op?: string; value?: unknown };
  dueHours?: number;
  escalateTo?: 'none' | 'manager_of_approver' | 'role' | 'users';
  escalateRole?: string;
  escalateUserIds?: Types.ObjectId[];
}

/** Starting defaults (structure section 19). Super Admin can replace them per organization. */
export const DEFAULT_CHAINS: Record<string, StageDef[]> = {
  leave: [
    { name: 'Manager', approverType: 'manager', dueHours: 48, escalateTo: 'role', escalateRole: 'hr' },
    { name: 'HR', approverType: 'role', role: 'hr', mode: 'parallel_any', condition: { field: 'requireHr', op: 'eq', value: true }, dueHours: 48 },
  ],
  expense: [{ name: 'Manager', approverType: 'manager', dueHours: 72, escalateTo: 'role', escalateRole: 'admin' }],
  travel: [{ name: 'Manager', approverType: 'manager', dueHours: 48, escalateTo: 'role', escalateRole: 'admin' }],
  attendance_correction: [{ name: 'Manager or HR', approverType: 'manager', dueHours: 48, escalateTo: 'role', escalateRole: 'hr' }],
  shift_change: [{ name: 'Manager', approverType: 'manager', dueHours: 24, escalateTo: 'role', escalateRole: 'hr' }],
  payroll: [
    { name: 'Reviewer', approverType: 'permission', permission: 'payroll:approve', mode: 'parallel_any', dueHours: 48 },
    { name: 'Final approver', approverType: 'role', role: 'super_admin', mode: 'parallel_any', dueHours: 48 },
  ],
  salary_change: [{ name: 'Compensation approver', approverType: 'permission', permission: 'salary:approve', mode: 'parallel_any', dueHours: 72 }],
  onboarding: [{ name: 'HR', approverType: 'role', role: 'hr', mode: 'parallel_any', dueHours: 72 }],
  offboarding: [
    { name: 'Manager', approverType: 'manager', dueHours: 48 },
    { name: 'HR', approverType: 'role', role: 'hr', mode: 'parallel_any', dueHours: 48 },
  ],
};

const FALLBACK_ROLES = ['hr', 'admin', 'super_admin'];

function matches(cond: StageDef['condition'], attrs: Record<string, unknown>): boolean {
  if (!cond?.field || !cond.op) return true;
  const v = attrs[cond.field];
  const w = cond.value;
  switch (cond.op) {
    case 'eq':
      return v === w;
    case 'ne':
      return v !== w;
    case 'gt':
      return Number(v) > Number(w);
    case 'gte':
      return Number(v) >= Number(w);
    case 'lt':
      return Number(v) < Number(w);
    case 'lte':
      return Number(v) <= Number(w);
    case 'in':
      return Array.isArray(w) && w.map(String).includes(String(v));
    default:
      return true;
  }
}

@Injectable()
export class ApprovalEngine {
  private readonly logger = new Logger('Approvals');
  private handlers = new Map<string, ApprovalHandler>();

  constructor(
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
    private readonly realtime: RealtimeService,
    private readonly orgSettings: OrgSettingsService,
    private readonly jobs: JobsService,
    @InjectModel('Approval') private readonly approvals: Model<any>,
    @InjectModel('ApprovalRule') private readonly rules: Model<any>,
    @InjectModel('ApprovalHistory') private readonly history: Model<any>,
    @InjectModel('Delegation') private readonly delegations: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Role') private readonly roles: Model<any>,
    @InjectModel('UserPermission') private readonly userPerms: Model<any>,
  ) {}

  register(requestType: string, handler: ApprovalHandler): void {
    this.handlers.set(requestType, handler);
  }

  // ------------------------------------------------------------------ starting

  async start(ctx: Ctx, input: StartInput): Promise<any> {
    const org = await this.orgSettings.get(ctx.orgOid);
    const subject = input.subjectEmployeeId ? await this.employees.findOne({ _id: input.subjectEmployeeId, organizationId: ctx.orgOid }).lean<any>() : null;
    const attrs = { ...(input.attributes ?? {}), amount: input.amount, departmentId: subject?.departmentId ? String(subject.departmentId) : undefined };

    const rule = await this.pickRule(ctx.orgOid, input.requestType, attrs);
    const preventSelf = rule ? rule.preventSelfApproval !== false : org?.settings?.approvals?.preventSelfApproval !== false;
    const defs: StageDef[] = (rule?.stages?.length ? rule.stages : DEFAULT_CHAINS[input.requestType]) ?? [{ name: 'Administrator', approverType: 'role', role: 'admin', mode: 'parallel_any' }];

    const stages: any[] = [];
    let strictSkipped = false;
    for (const def of defs) {
      if (!matches(def.condition, attrs)) continue;
      let approvers = await this.resolveApprovers(ctx.orgOid, def, subject);
      if (preventSelf) approvers = approvers.filter((a) => String(a) !== ctx.user.userId);
      if (!approvers.length) {
        if (def.approverType === 'manager' || def.approverType === 'department_head') {
          // Missing manager: HR, then admin, then Super Admin decide instead.
          approvers = await this.fallbackApprovers(ctx.orgOid, preventSelf ? ctx.userOid : undefined);
        } else {
          // A permission- or role-based step never falls back to people without that authority.
          strictSkipped = true;
          continue;
        }
      }
      stages.push({ name: def.name, mode: def.mode ?? 'single', approverIds: approvers, decisions: [], status: 'waiting', escalationLevel: 0, def });
    }
    if (!stages.length) {
      if (strictSkipped) {
        throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'NO_APPROVER', 'Nobody else holds the permission to approve this. Grant it to another person (you cannot approve your own request).');
      }
      // No silent approval: there is always at least one human decision.
      stages.push({ name: 'Administrator', mode: 'parallel_any', approverIds: await this.fallbackApprovers(ctx.orgOid, ctx.userOid), decisions: [], status: 'waiting', escalationLevel: 0 });
    }
    if (!stages[0].approverIds.length) {
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'NO_APPROVER', 'No one can approve this request yet. Ask an administrator to set up approvers.');
    }
    const hours = (stages[0].def?.dueHours ?? org?.settings?.approvals?.escalationHours ?? 48) as number;
    stages[0].status = 'active';
    stages[0].dueAt = new Date(Date.now() + hours * 3600_000);

    const current = await this.withDelegates(ctx.orgOid, stages[0].approverIds, input.requestType);
    const approval = await this.approvals.create({
      organizationId: ctx.orgOid,
      requestType: input.requestType,
      requestId: input.requestId,
      requestedBy: ctx.userOid,
      subjectEmployeeId: input.subjectEmployeeId,
      title: input.title,
      summary: input.summary,
      amount: input.amount,
      ruleId: rule?._id,
      stages: stages.map(({ def, ...s }) => s),
      currentStage: 0,
      currentApproverIds: current,
      status: 'pending',
      dueAt: stages[0].dueAt,
    });
    // Remember stage definitions for escalation without re-reading rules.
    (approval as any)._defs = stages.map((s) => s.def);
    await this.history.create({ organizationId: ctx.orgOid, approvalId: approval._id, stage: 0, actorId: ctx.userOid, action: 'submitted' });
    await this.notifyApprovers(ctx.orgOid, approval.toObject(), current, input.link);
    return approval.toObject();
  }

  private async pickRule(orgId: Types.ObjectId, requestType: string, attrs: Record<string, any>): Promise<any | null> {
    const rules = await this.rules.find({ organizationId: orgId, requestType, active: true }).sort({ priority: -1 }).lean<any[]>();
    for (const r of rules) {
      const m = r.match ?? {};
      if (m.departmentIds?.length && !m.departmentIds.map(String).includes(String(attrs.departmentId))) continue;
      if (m.minAmount != null && !(Number(attrs.amount) >= m.minAmount)) continue;
      if (m.maxAmount != null && !(Number(attrs.amount) <= m.maxAmount)) continue;
      if (m.leaveTypeIds?.length && !m.leaveTypeIds.map(String).includes(String(attrs.leaveTypeId))) continue;
      return r;
    }
    return null;
  }

  private async userOfEmployee(orgId: Types.ObjectId, employeeId?: Types.ObjectId | null): Promise<Types.ObjectId | null> {
    if (!employeeId) return null;
    const u = await this.users.findOne({ organizationId: orgId, employeeId, status: 'active' }, { _id: 1 }).lean<any>();
    return u?._id ?? null;
  }

  private async usersWithRole(orgId: Types.ObjectId, role: string): Promise<Types.ObjectId[]> {
    return (await this.users.find({ organizationId: orgId, role, status: 'active' }, { _id: 1 }).limit(50).lean<any[]>()).map((u) => u._id);
  }

  private async usersWithPermission(orgId: Types.ObjectId, permission: string): Promise<Types.ObjectId[]> {
    const rx = new RegExp(`^${permission.replace(':', '\\:')}:`);
    const roleKeys = (await this.roles.find({ organizationId: orgId, grants: rx }, { key: 1 }).lean<any[]>()).map((r) => r.key);
    const direct = (await this.userPerms.find({ organizationId: orgId, grant: rx }, { userId: 1 }).lean<any[]>()).map((p) => p.userId);
    const users = await this.users.find({ organizationId: orgId, status: 'active', $or: [{ role: { $in: roleKeys } }, { _id: { $in: direct } }] }, { _id: 1 }).limit(50).lean<any[]>();
    return users.map((u) => u._id);
  }

  async resolveApprovers(orgId: Types.ObjectId, def: StageDef, subject: any): Promise<Types.ObjectId[]> {
    switch (def.approverType) {
      case 'manager': {
        const u = await this.userOfEmployee(orgId, subject?.reportingManagerId);
        if (u) return [u];
        // No manager: department head, then fallbacks.
        if (subject?.departmentId) {
          const d = await this.departments.findById(subject.departmentId, { headEmployeeId: 1 }).lean<any>();
          const h = await this.userOfEmployee(orgId, d?.headEmployeeId);
          if (h) return [h];
        }
        return [];
      }
      case 'department_head': {
        const d = subject?.departmentId ? await this.departments.findById(subject.departmentId, { headEmployeeId: 1 }).lean<any>() : null;
        const h = await this.userOfEmployee(orgId, d?.headEmployeeId);
        return h ? [h] : [];
      }
      case 'role':
        return def.role ? this.usersWithRole(orgId, def.role) : [];
      case 'permission':
        return def.permission ? this.usersWithPermission(orgId, def.permission) : [];
      case 'users':
        return (def.userIds ?? []).map((u) => new Types.ObjectId(String(u)));
    }
  }

  private async fallbackApprovers(orgId: Types.ObjectId, exclude?: Types.ObjectId): Promise<Types.ObjectId[]> {
    for (const role of FALLBACK_ROLES) {
      const ids = (await this.usersWithRole(orgId, role)).filter((u) => !exclude || String(u) !== String(exclude));
      if (ids.length) return ids;
    }
    return [];
  }

  /** Approvers plus anyone they delegated to (active, unexpired delegations). */
  private async withDelegates(orgId: Types.ObjectId, approverIds: Types.ObjectId[], requestType: string): Promise<Types.ObjectId[]> {
    const now = new Date();
    const dels = await this.delegations
      .find({ organizationId: orgId, active: true, fromUserId: { $in: approverIds }, startsAt: { $lte: now }, endsAt: { $gt: now }, $or: [{ requestTypes: { $size: 0 } }, { requestTypes: requestType }] })
      .lean<any[]>();
    const all = new Map<string, Types.ObjectId>();
    for (const a of approverIds) all.set(String(a), a);
    for (const d of dels) all.set(String(d.toUserId), d.toUserId);
    return [...all.values()];
  }

  private async notifyApprovers(orgId: Types.ObjectId, approval: any, userIds: Types.ObjectId[], link?: string): Promise<void> {
    await this.notifications.notify(orgId, userIds, {
      event: 'approval_pending',
      title: `Approval needed: ${approval.title}`,
      body: approval.summary,
      link: link ?? `/approvals/${approval._id}`,
      data: { approvalId: String(approval._id), requestType: approval.requestType },
    });
    this.realtime.toUsers(userIds.map(String), 'approvals:changed', { approvalId: String(approval._id) });
  }

  // ------------------------------------------------------------------ deciding

  /**
   * Records a decision. Idempotent: the same person deciding the same stage twice (a retry) returns
   * the current state without applying anything again.
   */
  async decide(ctx: Ctx, approvalId: string, decision: Decision, comment?: string): Promise<any> {
    const approval = await this.approvals.findOne({ _id: oid(approvalId), organizationId: ctx.orgOid }).lean<any>();
    if (!approval) throw notFound('Approval');
    const stageIdx = approval.currentStage;
    const decisionKey = `${approval._id}:${stageIdx}:${ctx.user.userId}`;

    const already = await this.history.findOne({ organizationId: ctx.orgOid, decisionKey }).lean();
    if (already) return this.view(ctx, approvalId); // retry of a processed decision
    if (approval.status !== 'pending') throw conflict('APPROVAL_CLOSED', `This request is already ${approval.status}.`);

    const stage = approval.stages[stageIdx];
    const onBehalfOf = await this.actingFor(ctx, approval, stage);
    if (onBehalfOf === false) throw forbidden('NOT_APPROVER', "You're not an approver for this step.");

    const rule = approval.ruleId ? await this.rules.findById(approval.ruleId).lean<any>() : null;
    const org = await this.orgSettings.get(ctx.orgOid);
    const preventSelf = rule ? rule.preventSelfApproval !== false : org?.settings?.approvals?.preventSelfApproval !== false;
    const isSelf = String(approval.requestedBy) === ctx.user.userId || (!!approval.subjectEmployeeId && String(approval.subjectEmployeeId) === ctx.user.employeeId);
    if (preventSelf && isSelf) {
      throw forbidden('SELF_APPROVAL_BLOCKED', "You can't decide your own request. It has been sent to another approver.");
    }
    if (decision === 'reject' && rule?.requireRejectComment && !comment?.trim()) {
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'COMMENT_REQUIRED', 'Add a reason for the rejection.', [{ field: 'comment', message: 'Required' }]);
    }

    // Claim the decision (unique key) before applying effects.
    try {
      await this.history.create({
        organizationId: ctx.orgOid,
        approvalId: approval._id,
        stage: stageIdx,
        actorId: ctx.userOid,
        onBehalfOf: onBehalfOf ?? undefined,
        action: decision === 'approve' ? 'approved' : decision === 'reject' ? 'rejected' : 'clarification',
        comment,
        decisionKey,
      });
    } catch (e: any) {
      if (e?.code === 11000) return this.view(ctx, approvalId);
      throw e;
    }

    try {
      await this.apply(ctx, approval, stageIdx, decision, comment, onBehalfOf ?? undefined);
    } catch (e) {
      // Effects failed (e.g. the leave balance is no longer enough): undo the claim so it can be retried.
      await this.history.collection.deleteOne({ decisionKey });
      throw e;
    }
    await this.audit.record(ctx, { action: `approval.${decision}`, resourceType: approval.requestType, resourceId: approval.requestId, changes: comment ? { comment: { from: null, to: comment } } : undefined });
    return this.view(ctx, approvalId);
  }

  /** Returns undefined when acting for self, the delegator's id when acting as delegate, false when not allowed. */
  private async actingFor(ctx: Ctx, approval: any, stage: any): Promise<Types.ObjectId | undefined | false> {
    const approvers: string[] = (stage?.approverIds ?? []).map(String);
    if (approvers.includes(ctx.user.userId)) return undefined;
    const now = new Date();
    const d = await this.delegations
      .findOne({ organizationId: ctx.orgOid, active: true, toUserId: ctx.userOid, fromUserId: { $in: stage.approverIds }, startsAt: { $lte: now }, endsAt: { $gt: now }, $or: [{ requestTypes: { $size: 0 } }, { requestTypes: approval.requestType }] })
      .lean<any>();
    return d ? d.fromUserId : false;
  }

  private async apply(ctx: Ctx, approval: any, idx: number, decision: Decision, comment: string | undefined, onBehalfOf?: Types.ObjectId): Promise<void> {
    const handler = this.handlers.get(approval.requestType);
    const stage = approval.stages[idx];
    const entry = { userId: ctx.userOid, onBehalfOf, decision, comment, at: new Date() };
    const guard = { _id: approval._id, status: 'pending', currentStage: idx };

    if (decision === 'reject') {
      await handler?.onRejected(approval, ctx, comment);
      await this.approvals.updateOne(guard, { $push: { [`stages.${idx}.decisions`]: entry }, $set: { [`stages.${idx}.status`]: 'rejected', status: 'rejected', decidedAt: new Date(), decisionComment: comment, currentApproverIds: [] } });
      await this.notifyRequester(approval, 'rejected', comment);
      return;
    }
    if (decision === 'clarification') {
      await handler?.onClarification?.(approval, ctx, comment);
      await this.approvals.updateOne(guard, { $push: { [`stages.${idx}.decisions`]: entry }, $set: { status: 'clarification', decisionComment: comment } });
      await this.notifyRequester(approval, 'needs more information', comment);
      return;
    }

    // approve
    const approvedBy = new Set([...(stage.decisions ?? []).filter((d: any) => d.decision === 'approve').map((d: any) => String(d.onBehalfOf ?? d.userId)), String(onBehalfOf ?? ctx.userOid)]);
    const stageDone = stage.mode !== 'parallel_all' || stage.approverIds.every((a: any) => approvedBy.has(String(a)));
    if (!stageDone) {
      await this.approvals.updateOne(guard, { $push: { [`stages.${idx}.decisions`]: entry }, $pull: { currentApproverIds: ctx.userOid } });
      return;
    }

    // Find the next stage that still has approvers.
    const next = approval.stages.findIndex((s: any, i: number) => i > idx && s.status === 'waiting');
    if (next === -1) {
      // Final approval: effects first; if they fail, nothing is marked approved.
      await handler?.onApproved({ ...approval, status: 'approved' }, ctx);
      const r = await this.approvals.updateOne(guard, { $push: { [`stages.${idx}.decisions`]: entry }, $set: { [`stages.${idx}.status`]: 'approved', status: 'approved', decidedAt: new Date(), decisionComment: comment, currentApproverIds: [] } });
      if (r.modifiedCount !== 1) throw conflict('APPROVAL_CHANGED', 'This request changed while you were deciding. Refresh and try again.');
      await this.notifyRequester(approval, 'approved', comment);
      return;
    }
    const nextStage = approval.stages[next];
    const org = await this.orgSettings.get(ctx.orgOid);
    const dueAt = new Date(Date.now() + (org?.settings?.approvals?.escalationHours ?? 48) * 3600_000);
    const current = await this.withDelegates(ctx.orgOid, nextStage.approverIds, approval.requestType);
    const r = await this.approvals.updateOne(guard, {
      $push: { [`stages.${idx}.decisions`]: entry },
      $set: { [`stages.${idx}.status`]: 'approved', [`stages.${next}.status`]: 'active', [`stages.${next}.dueAt`]: dueAt, currentStage: next, currentApproverIds: current, dueAt },
    });
    if (r.modifiedCount !== 1) throw conflict('APPROVAL_CHANGED', 'This request changed while you were deciding. Refresh and try again.');
    await handler?.onStageAdvanced?.(approval);
    await this.notifyApprovers(ctx.orgOid, approval, current);
  }

  private async notifyRequester(approval: any, verb: string, comment?: string): Promise<void> {
    await this.notifications.notify(approval.organizationId, [approval.requestedBy], {
      event: 'approval_decided',
      title: `${approval.title}: ${verb}`,
      body: comment,
      link: `/approvals/${approval._id}`,
      data: { approvalId: String(approval._id), requestType: approval.requestType },
    });
    this.realtime.toUser(String(approval.requestedBy), 'approvals:changed', { approvalId: String(approval._id) });
  }

  /** The requester answered a clarification request: back to pending at the same stage. */
  async resubmit(ctx: Ctx, approvalId: string, comment?: string): Promise<any> {
    const a = await this.approvals.findOne({ _id: oid(approvalId), organizationId: ctx.orgOid, requestedBy: ctx.userOid }).lean<any>();
    if (!a) throw notFound('Request');
    if (a.status !== 'clarification') throw conflict('NOT_IN_CLARIFICATION', 'This request is not waiting for more information.');
    const stage = a.stages[a.currentStage];
    // Approvers who asked may decide again: drop their previous key for this stage.
    await this.history.updateMany({ approvalId: a._id, stage: a.currentStage, action: 'clarification' }, { $unset: { decisionKey: 1 } }).catch(async () => {
      await this.history.collection.updateMany({ approvalId: a._id, stage: a.currentStage, action: 'clarification' }, { $unset: { decisionKey: 1 } });
    });
    const current = await this.withDelegates(ctx.orgOid, stage.approverIds, a.requestType);
    await this.approvals.updateOne({ _id: a._id, status: 'clarification' }, { $set: { status: 'pending', currentApproverIds: current } });
    await this.history.create({ organizationId: ctx.orgOid, approvalId: a._id, stage: a.currentStage, actorId: ctx.userOid, action: 'resubmitted', comment });
    await this.notifyApprovers(ctx.orgOid, a, current);
    return this.view(ctx, approvalId);
  }

  /** The requester withdraws a pending request. */
  async cancel(ctx: Ctx, requestType: string, requestId: Types.ObjectId): Promise<void> {
    const a = await this.approvals.findOne({ organizationId: ctx.orgOid, requestType, requestId }).lean<any>();
    if (!a) return;
    if (!['pending', 'clarification'].includes(a.status)) throw conflict('APPROVAL_CLOSED', `This request is already ${a.status}.`);
    await this.handlers.get(requestType)?.onCancelled?.(a, ctx);
    await this.approvals.updateOne({ _id: a._id }, { $set: { status: 'cancelled', currentApproverIds: [], decidedAt: new Date() } });
    await this.history.create({ organizationId: ctx.orgOid, approvalId: a._id, stage: a.currentStage, actorId: ctx.userOid, action: 'cancelled' });
    this.realtime.toUsers(a.currentApproverIds.map(String), 'approvals:changed', { approvalId: String(a._id) });
  }

  async view(ctx: Ctx, approvalId: string): Promise<any> {
    const a = await this.approvals.findOne({ _id: oid(approvalId), organizationId: ctx.orgOid }).lean<any>();
    if (!a) throw notFound('Approval');
    const involved =
      String(a.requestedBy) === ctx.user.userId ||
      a.currentApproverIds.some((u: any) => String(u) === ctx.user.userId) ||
      a.stages.some((s: any) => s.approverIds.some((u: any) => String(u) === ctx.user.userId)) ||
      ctx.authz.can('approvals', 'view', 'organization');
    if (!involved) throw notFound('Approval');
    const hist = await this.history.find({ approvalId: a._id }).sort({ at: 1 }).lean();
    const userIds = [...new Set([String(a.requestedBy), ...a.stages.flatMap((s: any) => s.approverIds.map(String)), ...hist.map((h: any) => String(h.actorId))])];
    const names = await this.users.find({ _id: { $in: userIds.map((u) => new Types.ObjectId(u)) } }, { fullName: 1, displayName: 1 }).lean<any[]>();
    return {
      ...serialize(a),
      history: serialize(hist),
      people: Object.fromEntries(names.map((n) => [String(n._id), n.displayName || n.fullName])),
      canDecide: a.status === 'pending' && a.currentApproverIds.some((u: any) => String(u) === ctx.user.userId),
      waitingSince: a.stages[a.currentStage]?.dueAt ? undefined : a.updatedAt,
    };
  }

  // ------------------------------------------------------------------ escalation and reminders

  @Cron('*/15 * * * *')
  async escalate(): Promise<void> {
    await this.jobs.run('approvals.escalate', async () => {
      const now = new Date();
      const overdue = await this.approvals.find({ status: 'pending', dueAt: { $lt: now } }).limit(200).lean<any[]>();
      let n = 0;
      for (const a of overdue) {
        const stage = a.stages[a.currentStage];
        if ((stage.escalationLevel ?? 0) >= 2) continue;
        const rule = a.ruleId ? await this.rules.findById(a.ruleId).lean<any>() : null;
        const def: StageDef | undefined = (rule?.stages ?? DEFAULT_CHAINS[a.requestType])?.find((s: StageDef) => s.name === stage.name);
        let extra: Types.ObjectId[] = [];
        if (def?.escalateTo === 'role' && def.escalateRole) extra = await this.usersWithRole(a.organizationId, def.escalateRole);
        else if (def?.escalateTo === 'users') extra = (def.escalateUserIds ?? []).map((u) => new Types.ObjectId(String(u)));
        else if (def?.escalateTo === 'manager_of_approver') {
          for (const u of stage.approverIds) {
            const usr = await this.users.findById(u, { employeeId: 1 }).lean<any>();
            const emp = usr?.employeeId ? await this.employees.findById(usr.employeeId, { reportingManagerId: 1 }).lean<any>() : null;
            const m = await this.userOfEmployee(a.organizationId, emp?.reportingManagerId);
            if (m) extra.push(m);
          }
        }
        if (!extra.length) extra = await this.fallbackApprovers(a.organizationId, a.requestedBy);
        extra = extra.filter((u) => String(u) !== String(a.requestedBy));
        const due = new Date(now.getTime() + 24 * 3600_000);
        await this.approvals.updateOne(
          { _id: a._id, status: 'pending', currentStage: a.currentStage },
          {
            $addToSet: { [`stages.${a.currentStage}.approverIds`]: { $each: extra }, currentApproverIds: { $each: extra } },
            $set: { escalated: true, dueAt: due, [`stages.${a.currentStage}.dueAt`]: due, [`stages.${a.currentStage}.escalatedAt`]: now },
            $inc: { [`stages.${a.currentStage}.escalationLevel`]: 1 },
          },
        );
        await this.history.create({ organizationId: a.organizationId, approvalId: a._id, stage: a.currentStage, action: 'escalated', comment: `Escalated after the due time to ${extra.length} more approver(s).` });
        await this.notifyApprovers(a.organizationId, a, [...a.currentApproverIds, ...extra]);
        n++;
      }
      return `${n} escalated`;
    });
  }

  static summaryCounts(rows: any[]): Record<string, number> {
    return rows.reduce((acc: Record<string, number>, r: any) => ({ ...acc, [r.requestType]: (acc[r.requestType] ?? 0) + 1 }), {});
  }
}
