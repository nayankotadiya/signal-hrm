import { Injectable, OnModuleInit } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService, diff } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, conflict, dayString, escapeRegex, forbidden, notFound, objectId, oid, Paged } from '../../common/http/validation';
import { localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { FilesService } from '../files/files.service';
import { NotificationsService } from '../notifications/notifications.service';
import { RealtimeService } from '../notifications/realtime.service';
import { JobsService } from '../system/jobs.service';
import { TASK_STATUSES } from '../../schemas/work.schemas';

export const taskInput = z.object({
  title: z.string().trim().min(2).max(200),
  description: z.string().max(10_000).optional(),
  assigneeIds: z.array(objectId).max(20).default([]),
  departmentId: objectId.optional().nullable(),
  teamId: objectId.optional().nullable(),
  priority: z.enum(['low', 'medium', 'high', 'urgent']).default('medium'),
  status: z.enum(TASK_STATUSES).default('todo'),
  startDate: dayString.optional().nullable(),
  dueDate: dayString.optional().nullable(),
  tags: z.array(z.string().trim().max(30)).max(10).default([]),
  checklist: z.array(z.object({ id: z.string().max(40), text: z.string().trim().min(1).max(200), done: z.boolean().default(false) })).max(50).default([]),
  requiresReview: z.boolean().default(false),
  reviewerId: objectId.optional().nullable(),
  relatedLeadId: objectId.optional().nullable(),
});

/** Allowed status moves. Completion needs review first when the task requires it. */
const FLOW: Record<string, string[]> = {
  todo: ['in_progress', 'blocked', 'cancelled'],
  in_progress: ['todo', 'blocked', 'in_review', 'completed', 'cancelled'],
  blocked: ['todo', 'in_progress', 'cancelled'],
  in_review: ['in_progress', 'completed'],
  completed: ['in_progress'],
  cancelled: ['todo'],
};

@Injectable()
export class TasksService implements OnModuleInit {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly files: FilesService,
    private readonly notifications: NotificationsService,
    private readonly realtime: RealtimeService,
    private readonly orgSettings: OrgSettingsService,
    private readonly jobs: JobsService,
    @InjectModel('Task') private readonly tasks: Model<any>,
    @InjectModel('TaskComment') private readonly comments: Model<any>,
    @InjectModel('TaskActivity') private readonly activities: Model<any>,
    @InjectModel('TaskAttachment') private readonly attachments: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
  ) {}

  onModuleInit(): void {
    this.files.registerAuthorizer('task', async (ctx, f) => {
      const t = await this.tasks.findById(f.linked.id).lean<any>();
      return !!t && this.canView(ctx, t);
    });
  }

  /** Visible if: created by me, assigned to me, or an assignee is in my tasks:view scope. */
  private async canView(ctx: Ctx, t: any): Promise<boolean> {
    if (String(t.createdBy) === ctx.user.userId) return true;
    if (ctx.employeeOid && t.assigneeIds?.some((a: any) => String(a) === ctx.user.employeeId)) return true;
    const scope = ctx.authz.scope('tasks', 'view');
    if (!scope) return false;
    if (scope === 'organization') return true;
    const ids = await this.scope.employeeIds(ctx, scope, 'tasks', 'view');
    return !!ids && t.assigneeIds?.some((a: any) => ids.some((i) => String(i) === String(a)));
  }

  private async scopeFilter(ctx: Ctx, view: 'mine' | 'team' | 'all'): Promise<Record<string, unknown>> {
    const base: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (view === 'mine') return { ...base, $or: [{ assigneeIds: ctx.employeeOid ?? null }, { createdBy: ctx.userOid }] };
    const scope = PermissionsService.require(ctx, 'tasks', 'view');
    if (scope === 'organization' && view === 'all') return base;
    const ids = (await this.scope.employeeIds(ctx, scope === 'organization' ? 'team' : scope, 'tasks', 'view')) ?? [];
    return { ...base, $or: [{ assigneeIds: { $in: ids } }, { createdBy: ctx.userOid }] };
  }

  async list(ctx: Ctx, q: { view: 'mine' | 'team' | 'all'; status?: string; priority?: string; assigneeId?: string; q?: string; dueFrom?: string; dueTo?: string; overdue?: boolean; tag?: string; page: number; limit: number }): Promise<Paged<any>> {
    const filter: Record<string, any> = await this.scopeFilter(ctx, q.view);
    if (q.status) filter.status = { $in: q.status.split(',') };
    if (q.priority) filter.priority = q.priority;
    if (q.assigneeId) filter.assigneeIds = oid(q.assigneeId);
    if (q.tag) filter.tags = q.tag;
    if (q.q) filter.title = new RegExp(escapeRegex(q.q), 'i');
    if (q.dueFrom || q.dueTo) filter.dueDate = { ...(q.dueFrom ? { $gte: q.dueFrom } : {}), ...(q.dueTo ? { $lte: q.dueTo } : {}) };
    if (q.overdue) {
      const org = await this.orgSettings.get(ctx.orgOid);
      filter.dueDate = { $lt: localParts(new Date(), org.timezone).day };
      filter.status = { $nin: ['completed', 'cancelled'] };
    }
    const [rows, total] = await Promise.all([this.tasks.find(filter).sort({ status: 1, order: 1, dueDate: 1, createdAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean<any[]>(), this.tasks.countDocuments(filter)]);
    return { items: await this.decorate(rows), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  private async decorate(rows: any[]): Promise<any[]> {
    const ids = [...new Set(rows.flatMap((r) => (r.assigneeIds ?? []).map(String)))];
    const emps = await this.employees.find({ _id: { $in: ids.map(oid) } }, { firstName: 1, lastName: 1, photoFileId: 1 }).lean<any[]>();
    const e = new Map(emps.map((x) => [String(x._id), { id: String(x._id), name: `${x.firstName} ${x.lastName ?? ''}`.trim(), photoFileId: x.photoFileId ? String(x.photoFileId) : null }]));
    const counts = await this.comments.aggregate([{ $match: { taskId: { $in: rows.map((r) => r._id) } } }, { $group: { _id: '$taskId', n: { $sum: 1 } } }]);
    const cc = new Map(counts.map((c: any) => [String(c._id), c.n]));
    return serialize(rows).map((r: any) => ({ ...r, assignees: (r.assigneeIds ?? []).map((a: string) => e.get(a)).filter(Boolean), commentCount: cc.get(r.id) ?? 0 }));
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    const t = await this.tasks.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t || !(await this.canView(ctx, t))) throw notFound('Task');
    const [decorated] = await this.decorate([t]);
    const [comments, activity, attachments] = await Promise.all([
      this.comments.find({ taskId: t._id }).sort({ createdAt: 1 }).limit(500).lean<any[]>(),
      this.activities.find({ taskId: t._id }).sort({ createdAt: -1 }).limit(100).lean<any[]>(),
      this.attachments.find({ taskId: t._id }).lean<any[]>(),
    ]);
    const userIds = [...new Set([...comments.map((c) => String(c.authorId)), ...activity.map((a) => String(a.actorId))])];
    const users = await this.users.find({ _id: { $in: userIds.map(oid) } }, { fullName: 1, displayName: 1 }).lean<any[]>();
    const uname = new Map(users.map((u) => [String(u._id), u.displayName || u.fullName]));
    return {
      ...decorated,
      comments: serialize(comments).map((c: any) => ({ ...c, authorName: uname.get(c.authorId) })),
      activity: serialize(activity).map((a: any) => ({ ...a, actorName: uname.get(a.actorId) })),
      attachments: serialize(attachments),
      can: { edit: await this.canEdit(ctx, t), assign: ctx.authz.can('tasks', 'assign') },
    };
  }

  private async canEdit(ctx: Ctx, t: any): Promise<boolean> {
    if (String(t.createdBy) === ctx.user.userId) return true;
    const scope = ctx.authz.scope('tasks', 'edit');
    if (!scope) return false;
    if (scope === 'own') return !!ctx.employeeOid && t.assigneeIds?.some((a: any) => String(a) === ctx.user.employeeId);
    if (scope === 'organization') return true;
    const ids = await this.scope.employeeIds(ctx, scope, 'tasks', 'edit');
    return !!ids && t.assigneeIds?.some((a: any) => ids.some((i) => String(i) === String(a)));
  }

  private async validateAssignees(ctx: Ctx, ids: string[]): Promise<void> {
    if (!ids.length) return;
    if (!ctx.authz.can('tasks', 'assign')) {
      // Without assign rights you can only create tasks for yourself.
      if (ids.some((i) => i !== ctx.user.employeeId)) throw forbidden('ASSIGN_NOT_ALLOWED', 'You can only assign tasks to yourself.');
      return;
    }
    for (const i of ids) {
      const emp = await this.employees.exists({ _id: oid(i), organizationId: ctx.orgOid, status: { $nin: ['exited', 'archived'] } });
      if (!emp) throw badRequest('ASSIGNEE_INVALID', 'An assignee is not an active employee.', 'assigneeIds');
      if (!(await this.scope.covers(ctx, 'tasks', 'assign', i))) throw forbidden('ASSIGN_OUT_OF_SCOPE', "You can't assign tasks to people outside your team.");
    }
  }

  async create(ctx: Ctx, b: z.infer<typeof taskInput>): Promise<any> {
    PermissionsService.require(ctx, 'tasks', 'create');
    const assignees = b.assigneeIds.length ? b.assigneeIds : ctx.user.employeeId ? [ctx.user.employeeId] : [];
    await this.validateAssignees(ctx, assignees);
    if (b.startDate && b.dueDate && b.dueDate < b.startDate) throw badRequest('DATES_INVALID', 'The due date is before the start date.', 'dueDate');
    const last = await this.tasks.findOne({ organizationId: ctx.orgOid, status: b.status }).sort({ order: -1 }).lean<any>();
    const t = await this.tasks.create({
      ...b,
      organizationId: ctx.orgOid,
      createdBy: ctx.userOid,
      assigneeIds: assignees.map(oid),
      departmentId: b.departmentId ? oid(b.departmentId) : undefined,
      teamId: b.teamId ? oid(b.teamId) : undefined,
      reviewerId: b.reviewerId ? oid(b.reviewerId) : undefined,
      relatedLeadId: b.relatedLeadId ? oid(b.relatedLeadId) : undefined,
      completion: this.completionOf(b.checklist, b.status),
      order: (last?.order ?? 0) + 1000,
    });
    await this.activities.create({ organizationId: ctx.orgOid, taskId: t._id, actorId: ctx.userOid, type: 'created' });
    await this.notifyAssignees(ctx, t.toObject(), assignees);
    await this.audit.record(ctx, { action: 'task.create', resourceType: 'task', resourceId: t._id });
    return this.get(ctx, String(t._id));
  }

  private completionOf(checklist: { done: boolean }[], status: string): number {
    if (status === 'completed') return 100;
    if (!checklist?.length) return status === 'in_review' ? 90 : 0;
    return Math.round((checklist.filter((c) => c.done).length * 100) / checklist.length);
  }

  private async notifyAssignees(ctx: Ctx, t: any, employeeIds: string[]): Promise<void> {
    const others = employeeIds.filter((e) => e !== ctx.user.employeeId);
    if (!others.length) return;
    const users = await this.users.find({ organizationId: ctx.orgOid, employeeId: { $in: others.map(oid) } }, { _id: 1 }).lean<any[]>();
    await this.notifications.notify(ctx.orgOid, users.map((u) => u._id), { event: 'task_assigned', title: `New task: ${t.title}`, body: t.dueDate ? `Due ${t.dueDate}` : undefined, link: `/work/tasks/${t._id}` });
  }

  async update(ctx: Ctx, id: string, b: Partial<z.infer<typeof taskInput>> & { order?: number }): Promise<any> {
    const t = await this.tasks.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t || !(await this.canView(ctx, t))) throw notFound('Task');
    if (!(await this.canEdit(ctx, t))) throw forbidden('FORBIDDEN', "You can't edit this task.");
    const set: Record<string, any> = { ...b };
    if (b.assigneeIds) {
      await this.validateAssignees(ctx, b.assigneeIds);
      set.assigneeIds = b.assigneeIds.map(oid);
    }
    for (const k of ['departmentId', 'teamId', 'reviewerId', 'relatedLeadId']) if (k in set) set[k] = set[k] ? oid(set[k]) : null;
    if (b.status && b.status !== t.status) {
      if (!FLOW[t.status]?.includes(b.status)) throw badRequest('STATUS_FLOW', `A task can't move from ${t.status.replace('_', ' ')} to ${b.status.replace('_', ' ')}.`, 'status');
      if (b.status === 'completed' && t.requiresReview && t.status !== 'in_review') throw badRequest('REVIEW_REQUIRED', 'This task needs review before it can be completed.', 'status');
      if (b.status === 'completed' && t.requiresReview && t.reviewerId && String(t.reviewerId) !== ctx.user.userId && !ctx.authz.can('tasks', 'edit', 'team')) {
        throw forbidden('REVIEWER_ONLY', 'Only the reviewer can complete this task.');
      }
      set.completedAt = b.status === 'completed' ? new Date() : null;
    }
    set.completion = this.completionOf(b.checklist ?? t.checklist, b.status ?? t.status);
    await this.tasks.updateOne({ _id: t._id }, { $set: set });
    const changes = diff(t, set, Object.keys(set).filter((k) => !['order', 'completion', 'completedAt'].includes(k)));
    if (Object.keys(changes).length) await this.activities.create({ organizationId: ctx.orgOid, taskId: t._id, actorId: ctx.userOid, type: b.status && b.status !== t.status ? 'status_change' : 'updated', data: changes });
    if (b.assigneeIds) await this.notifyAssignees(ctx, { ...t, ...set }, b.assigneeIds.filter((a) => !(t.assigneeIds ?? []).map(String).includes(a)));
    this.realtime.toRoom(`org:${ctx.user.orgId}:tasks`, 'tasks:changed', { taskId: id });
    await this.audit.record(ctx, { action: 'task.update', resourceType: 'task', resourceId: id, changes });
    return this.get(ctx, id);
  }

  /** Kanban move: status + position (between two neighbours). */
  async move(ctx: Ctx, id: string, status: string, beforeId?: string, afterId?: string): Promise<any> {
    const [before, after] = await Promise.all([beforeId ? this.tasks.findById(beforeId, { order: 1 }).lean<any>() : null, afterId ? this.tasks.findById(afterId, { order: 1 }).lean<any>() : null]);
    const order = before && after ? (before.order + after.order) / 2 : before ? before.order + 1000 : after ? after.order - 1000 : Date.now();
    return this.update(ctx, id, { status: status as any, order });
  }

  async comment(ctx: Ctx, id: string, body: string): Promise<any> {
    const t = await this.tasks.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t || !(await this.canView(ctx, t))) throw notFound('Task');
    const c = await this.comments.create({ organizationId: ctx.orgOid, taskId: t._id, authorId: ctx.userOid, body });
    await this.activities.create({ organizationId: ctx.orgOid, taskId: t._id, actorId: ctx.userOid, type: 'comment' });
    const users = await this.users.find({ organizationId: ctx.orgOid, $or: [{ employeeId: { $in: t.assigneeIds ?? [] } }, { _id: t.createdBy }], _id: { $ne: ctx.userOid } }, { _id: 1 }).lean<any[]>();
    await this.notifications.notify(ctx.orgOid, users.map((u) => u._id), { event: 'task_assigned', title: `${ctx.user.name} commented on ${t.title}`, body: body.slice(0, 140), link: `/work/tasks/${id}` });
    return serialize(c.toObject());
  }

  async attach(ctx: Ctx, id: string, fileId: string): Promise<any> {
    const t = await this.tasks.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t || !(await this.canView(ctx, t))) throw notFound('Task');
    const f = await this.files.requireOwnUpload(ctx, fileId, 'attachment');
    await this.files.link(f._id, { type: 'task', id: t._id });
    const a = await this.attachments.create({ organizationId: ctx.orgOid, taskId: t._id, fileId: f._id, uploadedBy: ctx.userOid, name: f.name });
    await this.activities.create({ organizationId: ctx.orgOid, taskId: t._id, actorId: ctx.userOid, type: 'attachment', data: { name: f.name } });
    return serialize(a.toObject());
  }

  async remove(ctx: Ctx, id: string): Promise<void> {
    const t = await this.tasks.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t) throw notFound('Task');
    if (String(t.createdBy) !== ctx.user.userId) PermissionsService.require(ctx, 'tasks', 'delete');
    if (t.status === 'completed') throw conflict('TASK_COMPLETED', 'Completed tasks stay for reports. Cancel instead.');
    await this.tasks.updateOne({ _id: t._id }, { $set: { status: 'cancelled' } });
    await this.audit.record(ctx, { action: 'task.cancel', resourceType: 'task', resourceId: id });
  }

  /** Overdue reminders, once a day per task. */
  @Cron('0 9 * * *')
  async overdue(): Promise<void> {
    await this.jobs.run('tasks.overdue', async () => {
      const today = new Date().toISOString().slice(0, 10);
      const rows = await this.tasks.find({ dueDate: { $lt: today }, status: { $nin: ['completed', 'cancelled'] } }).limit(2000).lean<any[]>();
      for (const t of rows) {
        const users = await this.users.find({ organizationId: t.organizationId, employeeId: { $in: t.assigneeIds ?? [] } }, { _id: 1 }).lean<any[]>();
        await this.notifications.notify(t.organizationId, users.map((u) => u._id), { event: 'task_overdue', title: `Overdue: ${t.title}`, body: `Was due ${t.dueDate}`, link: `/work/tasks/${t._id}` });
      }
      return `${rows.length} overdue`;
    });
  }

  static readonly types = Types;
}
