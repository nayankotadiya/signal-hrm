import { Body, Controller, Delete, Get, HttpCode, Param, Post, Put, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import { C, Can, Ctx, Idempotent } from '../../common/auth/context';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, isoDate, listQuery, notFound, objectId, oid, parse } from '../../common/http/validation';
import { InjectModel, serialize } from '../../database/model';
import { ApprovalEngine } from './approval.engine';

const decideBody = z.object({ decision: z.enum(['approve', 'reject', 'clarification']), comment: z.string().trim().max(1000).optional() });
const stage = z.object({
  name: z.string().trim().min(1).max(60),
  approverType: z.enum(['manager', 'department_head', 'role', 'users', 'permission']),
  role: z.string().optional(),
  permission: z.string().regex(/^[a-z_]+:[a-z]+$/).optional(),
  userIds: z.array(objectId).optional(),
  mode: z.enum(['single', 'parallel_any', 'parallel_all']).default('single'),
  condition: z.object({ field: z.string(), op: z.enum(['gt', 'gte', 'lt', 'lte', 'eq', 'ne', 'in']), value: z.any() }).optional(),
  dueHours: z.number().int().min(1).max(720).default(48),
  escalateTo: z.enum(['none', 'manager_of_approver', 'role', 'users']).default('none'),
  escalateRole: z.string().optional(),
  escalateUserIds: z.array(objectId).optional(),
});
const ruleBody = z.object({
  requestType: z.enum(['leave', 'expense', 'travel', 'payroll', 'attendance_correction', 'shift_change', 'onboarding', 'offboarding', 'salary_change']),
  name: z.string().trim().max(80).optional(),
  priority: z.number().int().default(0),
  match: z.object({ departmentIds: z.array(objectId).optional(), minAmount: z.number().optional(), maxAmount: z.number().optional(), leaveTypeIds: z.array(objectId).optional() }).default({}),
  stages: z.array(stage).min(1).max(6),
  preventSelfApproval: z.boolean().default(true),
  requireRejectComment: z.boolean().default(false),
  active: z.boolean().default(true),
});
const delegationBody = z.object({
  toUserId: objectId,
  requestTypes: z.array(z.string()).default([]),
  startsAt: isoDate,
  endsAt: isoDate,
  reason: z.string().max(300).optional(),
});

@ApiTags('approvals')
@Controller({ path: 'approvals', version: '1' })
export class ApprovalsController {
  constructor(
    private readonly engine: ApprovalEngine,
    private readonly scope: ScopeService,
    private readonly audit: AuditService,
    @InjectModel('Approval') private readonly approvals: Model<any>,
    @InjectModel('ApprovalRule') private readonly rules: Model<any>,
    @InjectModel('Delegation') private readonly delegations: Model<any>,
    @InjectModel('ApprovalHistory') private readonly history: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  /** Tabs: mine (waiting for me), submitted, all (authorized), history, escalations. */
  @Get()
  async list(@C() ctx: Ctx, @Query() query: unknown) {
    const q = parse(listQuery.extend({ tab: z.enum(['mine', 'submitted', 'all', 'history', 'escalations']).default('mine'), type: z.string().optional() }), query);
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    switch (q.tab) {
      case 'mine':
        filter.currentApproverIds = ctx.userOid;
        filter.status = 'pending';
        break;
      case 'submitted':
        filter.requestedBy = ctx.userOid;
        break;
      case 'history': {
        const ids = await this.history.distinct('approvalId', { organizationId: ctx.orgOid, actorId: ctx.userOid, action: { $in: ['approved', 'rejected', 'clarification'] } });
        filter._id = { $in: ids };
        break;
      }
      case 'all':
      case 'escalations': {
        Object.assign(filter, await this.scope.filter(ctx, 'approvals', 'view', 'subjectEmployeeId'));
        if (q.tab === 'escalations') {
          filter.escalated = true;
          filter.status = 'pending';
        }
        break;
      }
    }
    if (q.type) filter.requestType = q.type;
    if (q.status && q.tab !== 'mine') filter.status = q.status;
    const [items, total, counts] = await Promise.all([
      this.approvals.find(filter).sort({ createdAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean(),
      this.approvals.countDocuments(filter),
      this.approvals.aggregate([{ $match: { organizationId: ctx.orgOid, currentApproverIds: ctx.userOid, status: 'pending' } }, { $group: { _id: '$requestType', n: { $sum: 1 } } }]),
    ]);
    const requesterIds = [...new Set(items.map((i: any) => String(i.requestedBy)))].map((i) => new Types.ObjectId(i));
    const names = await this.users.find({ _id: { $in: requesterIds } }, { fullName: 1, displayName: 1 }).lean<any[]>();
    const nameOf = new Map(names.map((n) => [String(n._id), n.displayName || n.fullName]));
    return {
      items: serialize(items).map((i: any) => ({ ...i, requestedByName: nameOf.get(i.requestedBy) })),
      page: q.page,
      limit: q.limit,
      total,
      hasMore: q.page * q.limit < total,
      pendingByType: Object.fromEntries(counts.map((c: any) => [c._id, c.n])),
    };
  }

  @Get('rules')
  @Can('approvals', 'view')
  async listRules(@C() ctx: Ctx) {
    return { items: serialize(await this.rules.find({ organizationId: ctx.orgOid }).sort({ requestType: 1, priority: -1 }).lean()) };
  }

  @Post('rules')
  @Can('approvals', 'configure', 'organization')
  async createRule(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(ruleBody, body);
    const doc = await this.rules.create({ ...b, organizationId: ctx.orgOid, updatedBy: ctx.userOid });
    await this.audit.record(ctx, { action: 'approval_rule.create', resourceType: 'approval_rule', resourceId: doc._id });
    return serialize(doc.toObject());
  }

  @Put('rules/:id')
  @Can('approvals', 'configure', 'organization')
  async updateRule(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(ruleBody, body);
    const before = await this.rules.findOneAndUpdate({ _id: oid(id), organizationId: ctx.orgOid }, { $set: { ...b, updatedBy: ctx.userOid } }).lean();
    if (!before) throw notFound('Rule');
    await this.audit.record(ctx, { action: 'approval_rule.update', resourceType: 'approval_rule', resourceId: id });
    return serialize(await this.rules.findById(id).lean());
  }

  @Delete('rules/:id')
  @Can('approvals', 'configure', 'organization')
  async deleteRule(@C() ctx: Ctx, @Param('id') id: string) {
    const r = await this.rules.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: { active: false } });
    if (!r.matchedCount) throw notFound('Rule');
    await this.audit.record(ctx, { action: 'approval_rule.deactivate', resourceType: 'approval_rule', resourceId: id });
    return { deactivated: true };
  }

  @Get('delegations')
  async listDelegations(@C() ctx: Ctx) {
    const rows = await this.delegations.find({ organizationId: ctx.orgOid, $or: [{ fromUserId: ctx.userOid }, { toUserId: ctx.userOid }] }).sort({ startsAt: -1 }).lean();
    return { items: serialize(rows) };
  }

  /** Delegation always has an expiry. */
  @Post('delegations')
  async delegate(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(delegationBody, body);
    if (b.endsAt <= b.startsAt) throw badRequest('DATES_INVALID', 'The end must be after the start.', 'endsAt');
    if (b.endsAt.getTime() - b.startsAt.getTime() > 90 * 86400_000) throw badRequest('DELEGATION_TOO_LONG', 'Delegations can last at most 90 days.', 'endsAt');
    if (b.toUserId === ctx.user.userId) throw badRequest('SELF_DELEGATION', "You can't delegate to yourself.", 'toUserId');
    const to = await this.users.findOne({ _id: oid(b.toUserId), organizationId: ctx.orgOid, status: 'active' }).lean();
    if (!to) throw notFound('User');
    const doc = await this.delegations.create({ ...b, toUserId: oid(b.toUserId), fromUserId: ctx.userOid, organizationId: ctx.orgOid, active: true });
    await this.audit.record(ctx, { action: 'approval.delegate', resourceType: 'delegation', resourceId: doc._id, changes: { toUserId: { from: null, to: b.toUserId } } });
    // Pending approvals waiting for me become visible to the delegate.
    await this.approvals.updateMany({ organizationId: ctx.orgOid, status: 'pending', currentApproverIds: ctx.userOid }, { $addToSet: { currentApproverIds: oid(b.toUserId) } });
    return serialize(doc.toObject());
  }

  @Delete('delegations/:id')
  async endDelegation(@C() ctx: Ctx, @Param('id') id: string) {
    const d = await this.delegations.findOneAndUpdate({ _id: oid(id), organizationId: ctx.orgOid, fromUserId: ctx.userOid }, { $set: { active: false, endsAt: new Date() } }).lean<any>();
    if (!d) throw notFound('Delegation');
    await this.approvals.updateMany({ organizationId: ctx.orgOid, status: 'pending', currentApproverIds: d.toUserId, 'stages.approverIds': { $ne: d.toUserId } }, { $pull: { currentApproverIds: d.toUserId } });
    await this.audit.record(ctx, { action: 'approval.delegation_end', resourceType: 'delegation', resourceId: id });
    return { ended: true };
  }

  @Get(':id')
  view(@C() ctx: Ctx, @Param('id') id: string) {
    return this.engine.view(ctx, id);
  }

  /** Decisions carry an Idempotency-Key and are processed once (held commit from the dark action card). */
  @Post(':id/decision')
  @Idempotent()
  @HttpCode(200)
  decide(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(decideBody, body);
    return this.engine.decide(ctx, id, b.decision, b.comment);
  }

  @Post(':id/resubmit')
  @HttpCode(200)
  resubmit(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.engine.resubmit(ctx, id, parse(z.object({ comment: z.string().max(1000).optional() }), body).comment);
  }
}
