import { Body, Controller, Get, Param, Put, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import { C, Can, Ctx, RequireReauth } from '../../common/auth/context';
import { ACTIONS, DEFAULT_ROLE_GRANTS, parseGrant, RESOURCES, ROLES, RoleKey, SCOPES, SOLE_SUPER_ADMIN_EMAIL } from '../../common/authz/catalog';
import { PermissionsService } from '../../common/authz/permissions.service';
import { badRequest, forbidden, listQuery, notFound, parse } from '../../common/http/validation';
import { InjectModel, serialize } from '../../database/model';

@ApiTags('roles')
@Controller({ path: 'roles', version: '1' })
export class RolesController {
  constructor(
    private readonly perms: PermissionsService,
    private readonly audit: AuditService,
    @InjectModel('Role') private readonly roles: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('UserPermission') private readonly userPerms: Model<any>,
    @InjectModel('PermissionChange') private readonly changes: Model<any>,
  ) {}

  private isSoleSuperAdmin(ctx: Ctx): boolean {
    return ctx.authz.isSuperAdmin && ctx.user.email?.toLowerCase() === SOLE_SUPER_ADMIN_EMAIL;
  }

  /** Catalog for the permission matrix UI. */
  @Get('catalog')
  @Can('roles', 'view')
  catalog(@C() ctx: Ctx) {
    const roles = this.isSoleSuperAdmin(ctx) ? ROLES : ROLES.filter((r) => r !== 'super_admin');
    return { resources: RESOURCES, actions: ACTIONS, scopes: SCOPES, roles, defaults: DEFAULT_ROLE_GRANTS };
  }

  @Get()
  @Can('roles', 'view')
  async list(@C() ctx: Ctx) {
    const isSole = this.isSoleSuperAdmin(ctx);
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!isSole) filter.key = { $ne: 'super_admin' };
    const rows = await this.roles.find(filter).sort({ key: 1 }).lean<any[]>();
    const matchUsers: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!isSole) {
      matchUsers.role = { $ne: 'super_admin' };
      matchUsers.email = { $ne: SOLE_SUPER_ADMIN_EMAIL };
    }
    const counts = await this.users.aggregate([{ $match: matchUsers }, { $group: { _id: '$role', n: { $sum: 1 } } }]);
    const countOf = new Map(counts.map((c: any) => [c._id, c.n]));
    return { items: serialize(rows).map((r: any) => ({ ...r, userCount: countOf.get(r.key) ?? 0 })) };
  }

  /**
   * Safe change: the server validates grant authority for every grant added or removed,
   * super_admin's set is fixed, and every change is recorded.
   */
  @Put(':key')
  @Can('roles', 'manage', 'organization')
  @RequireReauth()
  async update(@C() ctx: Ctx, @Param('key') key: string, @Body() body: unknown) {
    const b = parse(z.object({ grants: z.array(z.string()).max(500), name: z.string().max(60).optional(), description: z.string().max(300).optional() }), body);
    if (key === 'super_admin') {
      if (!ctx.authz.isSuperAdmin) throw notFound('Role');
      throw forbidden('SUPER_ADMIN_FIXED', "The Super Admin role always has every permission and can't be edited.");
    }
    const role = await this.roles.findOne({ organizationId: ctx.orgOid, key }).lean<any>();
    if (!role) throw notFound('Role');
    for (const g of b.grants) if (!parseGrant(g)) throw badRequest('GRANT_INVALID', `"${g}" is not a valid permission.`, 'grants');
    const before = new Set<string>(role.grants);
    const after = new Set<string>(b.grants);
    const added = [...after].filter((g) => !before.has(g));
    const removed = [...before].filter((g) => !after.has(g));
    for (const g of [...added, ...removed]) {
      if (!PermissionsService.canGrant(ctx, g)) throw forbidden('GRANT_AUTHORITY', `You can't change "${g}" because you don't hold it at that scope.`);
    }
    await this.roles.updateOne({ _id: role._id }, { $set: { grants: [...after], name: b.name ?? role.name, description: b.description ?? role.description }, $inc: { version: 1 } });
    this.perms.invalidateAll();
    await this.changes.create({ organizationId: ctx.orgOid, actorId: ctx.userOid, roleKey: key, change: 'role_updated', before: { added: [], removed }, after: { added } });
    await this.audit.record(ctx, { action: 'role.update', resourceType: 'role', resourceId: key, changes: { added: { from: null, to: added }, removed: { from: removed, to: null } } });
    return serialize(await this.roles.findById(role._id).lean());
  }

  /** Restores a role to the built-in defaults. */
  @Put(':key/reset')
  @Can('roles', 'manage', 'organization')
  @RequireReauth()
  async reset(@C() ctx: Ctx, @Param('key') key: string) {
    if (!ctx.authz.isSuperAdmin) throw forbidden('SUPER_ADMIN_ONLY', 'Only a Super Admin can reset a role.');
    const grants = DEFAULT_ROLE_GRANTS[key as RoleKey];
    if (!grants) throw notFound('Role');
    await this.roles.updateOne({ organizationId: ctx.orgOid, key }, { $set: { grants }, $inc: { version: 1 } });
    this.perms.invalidateAll();
    await this.audit.record(ctx, { action: 'role.reset', resourceType: 'role', resourceId: key });
    return { reset: true };
  }

  /** "Who can do what": everyone holding resource:action, with their scope and where it comes from. */
  @Get('who-can')
  @Can('roles', 'view')
  async whoCan(@C() ctx: Ctx, @Query() query: unknown) {
    const q = parse(z.object({ resource: z.string(), action: z.enum(ACTIONS) }), query);
    const prefix = `${q.resource}:${q.action}:`;
    const roles = await this.roles.find({ organizationId: ctx.orgOid, grants: { $regex: `^${q.resource}:${q.action}:` } }).lean<any[]>();
    const roleScope = new Map(roles.map((r) => [r.key, r.grants.filter((g: string) => g.startsWith(prefix)).map((g: string) => g.split(':')[2])]));
    const direct = await this.userPerms.find({ organizationId: ctx.orgOid, grant: { $regex: `^${q.resource}:${q.action}:` } }).lean<any[]>();
    const isSole = this.isSoleSuperAdmin(ctx);
    const userMatch: Record<string, unknown> = {
      organizationId: ctx.orgOid,
      status: { $in: ['active', 'invited', 'pending'] },
      $or: [{ role: { $in: [...roleScope.keys()] } }, { _id: { $in: direct.map((d) => d.userId) } }],
    };
    if (!isSole) {
      userMatch.role = { $ne: 'super_admin' };
      userMatch.email = { $ne: SOLE_SUPER_ADMIN_EMAIL };
    }
    const users = await this.users.find(userMatch, { fullName: 1, role: 1, status: 1 }).lean<any[]>();
    return {
      items: users.map((u) => ({
        id: String(u._id),
        fullName: u.fullName,
        role: u.role,
        status: u.status,
        viaRole: roleScope.get(u.role) ?? [],
        direct: direct.filter((d) => String(d.userId) === String(u._id)).map((d) => d.grant.split(':')[2]),
      })),
    };
  }

  @Get('changes')
  @Can('roles', 'view')
  async history(@C() ctx: Ctx, @Query() query: unknown) {
    const q = parse(listQuery, query);
    const isSole = this.isSoleSuperAdmin(ctx);
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid };
    if (!isSole) filter.roleKey = { $ne: 'super_admin' };
    const [items, total] = await Promise.all([
      this.changes.find(filter).sort({ at: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean(),
      this.changes.countDocuments(filter),
    ]);
    return { items: serialize(items), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }
}
