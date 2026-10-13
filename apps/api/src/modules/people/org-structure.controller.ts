import { Body, Controller, Delete, Get, Param, Patch, Post, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AuditService, diff } from '../../common/audit/audit.service';
import { C, Can, Ctx } from '../../common/auth/context';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, conflict, listQuery, notFound, objectId, oid, parse } from '../../common/http/validation';
import { InjectModel, serialize } from '../../database/model';

const deptBody = z.object({ name: z.string().trim().min(2).max(80), description: z.string().max(500).optional().nullable(), headEmployeeId: objectId.optional().nullable() });
const teamBody = z.object({
  name: z.string().trim().min(2).max(80),
  departmentId: objectId.optional().nullable(),
  leadEmployeeId: objectId.optional().nullable(),
  memberIds: z.array(objectId).max(500).optional(),
});

@ApiTags('departments')
@Controller({ path: 'departments', version: '1' })
export class DepartmentsController {
  constructor(
    private readonly audit: AuditService,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Team') private readonly teams: Model<any>,
  ) {}

  @Get()
  async list(@C() ctx: Ctx, @Query() query: unknown) {
    const q = parse(listQuery.extend({ includeArchived: z.coerce.boolean().optional() }), query);
    // Department names are not confidential; counts respect employee view scope below.
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!q.includeArchived) filter.status = 'active';
    const rows = await this.departments.find(filter).sort({ name: 1 }).lean<any[]>();
    const counts = await this.employees.aggregate([{ $match: { organizationId: ctx.orgOid, status: { $nin: ['exited', 'archived'] } } }, { $group: { _id: '$departmentId', n: { $sum: 1 } } }]);
    const countOf = new Map(counts.map((c: any) => [String(c._id), c.n]));
    const heads = await this.employees.find({ _id: { $in: rows.map((r) => r.headEmployeeId).filter(Boolean) } }, { firstName: 1, lastName: 1 }).lean<any[]>();
    const headName = new Map(heads.map((h) => [String(h._id), `${h.firstName} ${h.lastName ?? ''}`.trim()]));
    const canSeeCounts = ctx.authz.can('employees', 'view', 'department');
    return {
      items: serialize(rows).map((r: any) => ({ ...r, headName: headName.get(r.headEmployeeId) ?? null, headcount: canSeeCounts ? (countOf.get(r.id) ?? 0) : null })),
    };
  }

  @Post()
  @Can('departments', 'create', 'organization')
  async create(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(deptBody, body);
    if (await this.departments.exists({ organizationId: ctx.orgOid, name: new RegExp(`^${b.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'i') })) {
      throw conflict('DEPARTMENT_EXISTS', 'A department with this name already exists.');
    }
    if (b.headEmployeeId && !(await this.employees.exists({ _id: oid(b.headEmployeeId), organizationId: ctx.orgOid }))) throw badRequest('REFERENCE_INVALID', 'Head not found.', 'headEmployeeId');
    const d = await this.departments.create({ ...b, headEmployeeId: b.headEmployeeId ? oid(b.headEmployeeId) : undefined, organizationId: ctx.orgOid, createdBy: ctx.userOid });
    await this.audit.record(ctx, { action: 'department.create', resourceType: 'department', resourceId: d._id });
    return serialize(d.toObject());
  }

  @Patch(':id')
  @Can('departments', 'edit', 'organization')
  async update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(deptBody.partial(), body);
    const set: Record<string, unknown> = { ...b };
    if (b.headEmployeeId !== undefined) set.headEmployeeId = b.headEmployeeId ? oid(b.headEmployeeId) : null;
    const before = await this.departments.findOneAndUpdate({ _id: oid(id), organizationId: ctx.orgOid }, { $set: set }).lean<any>();
    if (!before) throw notFound('Department');
    await this.audit.record(ctx, { action: 'department.update', resourceType: 'department', resourceId: id, changes: diff(before, set) });
    return serialize(await this.departments.findById(id).lean());
  }

  /** Archive (never delete) so history and reports keep their department. */
  @Delete(':id')
  @Can('departments', 'delete', 'organization')
  async archive(@C() ctx: Ctx, @Param('id') id: string) {
    const active = await this.employees.countDocuments({ organizationId: ctx.orgOid, departmentId: oid(id), status: { $nin: ['exited', 'archived'] } });
    if (active) throw conflict('DEPARTMENT_NOT_EMPTY', `Move the ${active} employee(s) in this department first.`);
    const r = await this.departments.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: { status: 'archived' } });
    if (!r.matchedCount) throw notFound('Department');
    await this.teams.updateMany({ organizationId: ctx.orgOid, departmentId: oid(id) }, { $set: { status: 'archived' } });
    await this.audit.record(ctx, { action: 'department.archive', resourceType: 'department', resourceId: id });
    return { archived: true };
  }
}

@ApiTags('teams')
@Controller({ path: 'teams', version: '1' })
export class TeamsController {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    @InjectModel('Team') private readonly teams: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('EmployeeHistory') private readonly history: Model<any>,
  ) {}

  @Get()
  @Can('teams', 'view')
  async list(@C() ctx: Ctx, @Query() query: unknown) {
    const q = parse(listQuery.extend({ departmentId: objectId.optional(), includeArchived: z.coerce.boolean().optional() }), query);
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!q.includeArchived) filter.status = 'active';
    if (q.departmentId) filter.departmentId = oid(q.departmentId);
    if (!ctx.authz.can('teams', 'view', 'organization')) {
      const mine = await this.scope.teamIds(ctx);
      filter.$or = [{ leadEmployeeId: ctx.employeeOid }, { memberIds: { $in: mine } }];
    }
    const rows = await this.teams.find(filter).sort({ name: 1 }).lean<any[]>();
    const leadIds = rows.map((r) => r.leadEmployeeId).filter(Boolean);
    const leads = await this.employees.find({ _id: { $in: leadIds } }, { firstName: 1, lastName: 1 }).lean<any[]>();
    const leadName = new Map(leads.map((h) => [String(h._id), `${h.firstName} ${h.lastName ?? ''}`.trim()]));
    return { items: serialize(rows).map((r: any) => ({ ...r, leadName: leadName.get(r.leadEmployeeId) ?? null, memberCount: r.memberIds?.length ?? 0 })) };
  }

  @Get(':id')
  @Can('teams', 'view')
  async get(@C() ctx: Ctx, @Param('id') id: string) {
    const t = await this.teams.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t) throw notFound('Team');
    const members = await this.employees.find({ organizationId: ctx.orgOid, teamId: t._id, status: { $nin: ['exited', 'archived'] } }, { firstName: 1, lastName: 1, designation: 1, photoFileId: 1, status: 1 }).lean();
    return { ...serialize(t), members: serialize(members) };
  }

  @Post()
  @Can('teams', 'create', 'organization')
  async create(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(teamBody, body);
    if (await this.teams.exists({ organizationId: ctx.orgOid, departmentId: b.departmentId ? oid(b.departmentId) : null, name: b.name })) throw conflict('TEAM_EXISTS', 'A team with this name already exists in this department.');
    const t = await this.teams.create({ organizationId: ctx.orgOid, name: b.name, departmentId: b.departmentId ? oid(b.departmentId) : undefined, leadEmployeeId: b.leadEmployeeId ? oid(b.leadEmployeeId) : undefined, memberIds: [] });
    if (b.memberIds?.length) await this.setMembers(ctx, t._id, b.memberIds);
    await this.audit.record(ctx, { action: 'team.create', resourceType: 'team', resourceId: t._id });
    return this.get(ctx, String(t._id));
  }

  @Patch(':id')
  @Can('teams', 'edit')
  async update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(teamBody.partial(), body);
    const t = await this.teams.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!t) throw notFound('Team');
    if (!ctx.authz.can('teams', 'edit', 'organization') && String(t.leadEmployeeId) !== ctx.user.employeeId) throw notFound('Team');
    const set: Record<string, unknown> = {};
    if (b.name) set.name = b.name;
    if (b.departmentId !== undefined) set.departmentId = b.departmentId ? oid(b.departmentId) : null;
    if (b.leadEmployeeId !== undefined) set.leadEmployeeId = b.leadEmployeeId ? oid(b.leadEmployeeId) : null;
    await this.teams.updateOne({ _id: t._id }, { $set: set });
    if (b.memberIds) {
      if (!ctx.authz.can('teams', 'assign')) throw notFound('Team');
      await this.setMembers(ctx, t._id, b.memberIds);
    }
    await this.audit.record(ctx, { action: 'team.update', resourceType: 'team', resourceId: id, changes: diff(t, set) });
    return this.get(ctx, id);
  }

  /** Membership lives on employees.teamId (one team per person); transfers are recorded in history. */
  private async setMembers(ctx: Ctx, teamId: any, memberIds: string[]): Promise<void> {
    const ids = memberIds.map(oid);
    const current = await this.employees.find({ organizationId: ctx.orgOid, teamId }, { _id: 1 }).lean<any[]>();
    const removed = current.filter((c) => !memberIds.includes(String(c._id)));
    const toAdd = await this.employees.find({ organizationId: ctx.orgOid, _id: { $in: ids }, teamId: { $ne: teamId } }, { teamId: 1 }).lean<any[]>();
    for (const r of removed) {
      await this.employees.updateOne({ _id: r._id }, { $set: { teamId: null } });
      await this.history.create({ organizationId: ctx.orgOid, employeeId: r._id, type: 'transfer', from: { teamId }, to: { teamId: null }, byUserId: ctx.userOid });
    }
    for (const a of toAdd) {
      if (a.teamId) await this.teams.updateOne({ _id: a.teamId }, { $pull: { memberIds: a._id } });
      await this.employees.updateOne({ _id: a._id }, { $set: { teamId } });
      await this.history.create({ organizationId: ctx.orgOid, employeeId: a._id, type: 'transfer', from: { teamId: a.teamId ?? null }, to: { teamId }, byUserId: ctx.userOid });
    }
    await this.teams.updateOne({ _id: teamId }, { $set: { memberIds: ids } });
  }

  @Delete(':id')
  @Can('teams', 'delete', 'organization')
  async archive(@C() ctx: Ctx, @Param('id') id: string) {
    const r = await this.teams.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: { status: 'archived' } });
    if (!r.matchedCount) throw notFound('Team');
    await this.audit.record(ctx, { action: 'team.archive', resourceType: 'team', resourceId: id });
    return { archived: true };
  }
}
