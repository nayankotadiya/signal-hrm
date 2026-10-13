import { Injectable } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { InjectModel } from '../../database/model';
import type { Ctx } from '../auth/context';
import { Action, Resource, Scope } from './catalog';
import { PermissionsService } from './permissions.service';

/**
 * Turns a permission scope into a database filter. Every list and read query goes through this,
 * so a manager who calls the API directly still sees only their team.
 */
@Injectable()
export class ScopeService {
  constructor(
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Team') private readonly teams: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
  ) {}

  /** Employee ids the scope covers, or null for the whole organization. */
  async employeeIds(ctx: Ctx, scope: Scope, resource?: Resource, action?: Action): Promise<Types.ObjectId[] | null> {
    switch (scope) {
      case 'organization':
        return null;
      case 'own':
        return ctx.employeeOid ? [ctx.employeeOid] : [];
      case 'records':
        return resource && action ? ctx.authz.recordIds(resource, action).filter(Types.ObjectId.isValid).map((i) => new Types.ObjectId(i)) : [];
      case 'team':
        return this.teamIds(ctx);
      case 'department':
        return this.departmentIds(ctx);
    }
  }

  /** Me + direct reports + members of teams I lead. */
  async teamIds(ctx: Ctx): Promise<Types.ObjectId[]> {
    const key = 'team';
    if (ctx.cache.has(key)) return ctx.cache.get(key) as Types.ObjectId[];
    if (!ctx.employeeOid) return [];
    const led = await this.teams.find({ organizationId: ctx.orgOid, leadEmployeeId: ctx.employeeOid, status: 'active' }, { _id: 1 }).lean();
    const ids = await this.employees.distinct('_id', {
      organizationId: ctx.orgOid,
      $or: [{ reportingManagerId: ctx.employeeOid }, { teamId: { $in: led.map((t: any) => t._id) } }, { _id: ctx.employeeOid }],
    });
    ctx.cache.set(key, ids);
    return ids as Types.ObjectId[];
  }

  /** Employees of my department and of departments I head. */
  async departmentIds(ctx: Ctx): Promise<Types.ObjectId[]> {
    const key = 'dept';
    if (ctx.cache.has(key)) return ctx.cache.get(key) as Types.ObjectId[];
    if (!ctx.employeeOid) return [];
    const me = await this.employees.findOne({ _id: ctx.employeeOid }, { departmentId: 1 }).lean<{ departmentId?: Types.ObjectId }>();
    const headed = await this.departments.distinct('_id', { organizationId: ctx.orgOid, headEmployeeId: ctx.employeeOid });
    const deptIds = [...headed, ...(me?.departmentId ? [me.departmentId] : [])];
    const ids = await this.employees.distinct('_id', { organizationId: ctx.orgOid, $or: [{ departmentId: { $in: deptIds } }, { _id: ctx.employeeOid }] });
    ctx.cache.set(key, ids);
    return ids as Types.ObjectId[];
  }

  /**
   * Filter for documents that belong to employees, e.g. leave requests: { organizationId, employeeId: { $in } }.
   * Throws 403 when the caller has no grant at all.
   */
  async filter(ctx: Ctx, resource: Resource, action: Action, field = 'employeeId'): Promise<Record<string, unknown>> {
    const scope = PermissionsService.require(ctx, resource, action);
    const ids = await this.employeeIds(ctx, scope, resource, action);
    const base: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (ids === null) return base;
    return { ...base, [field]: { $in: ids } };
  }

  /** True when the given employee falls inside the caller's scope for resource:action. */
  async covers(ctx: Ctx, resource: Resource, action: Action, employeeId: unknown): Promise<boolean> {
    const scope = ctx.authz.scope(resource, action);
    if (!scope) return false;
    const ids = await this.employeeIds(ctx, scope, resource, action);
    if (ids === null) return true;
    return ids.some((i) => String(i) === String(employeeId));
  }

  async requireCovers(ctx: Ctx, resource: Resource, action: Action, employeeId: unknown): Promise<void> {
    if (!(await this.covers(ctx, resource, action, employeeId))) {
      PermissionsService.require(ctx, resource, action, 'organization'); // throws the standard 403
    }
  }
}
