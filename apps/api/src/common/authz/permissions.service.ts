import { HttpStatus, Injectable } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { InjectModel } from '../../database/model';
import type { Authz, AuthUser, Ctx } from '../auth/context';
import { ApiError } from '../errors/api-error';
import {
  Action,
  DEFAULT_ROLE_GRANTS,
  Grant,
  grantKey,
  parseGrant,
  Resource,
  RoleKey,
  ROLES,
  Scope,
  scopeRank,
  SUPER_ADMIN_ONLY,
} from './catalog';

interface CacheEntry {
  at: number;
  key: string;
  grants: Grant[];
}

/**
 * Resolves a user's grants (role defaults stored per organization + individual grants) and answers
 * "can this user do X, and at what scope?". Cached briefly per user and invalidated by
 * users.permissionsVersion / roles.version, so permission changes apply within seconds.
 */
@Injectable()
export class PermissionsService {
  private cache = new Map<string, CacheEntry>();
  private static readonly TTL = 30_000;

  constructor(
    @InjectModel('Role') private readonly roles: Model<any>,
    @InjectModel('UserPermission') private readonly userPerms: Model<any>,
  ) {}

  async grantsFor(user: AuthUser, permissionsVersion: number): Promise<Grant[]> {
    const role = await this.roles.findOne({ organizationId: user.orgId, key: user.role }).lean<{ grants: string[]; version: number }>();
    const key = `${permissionsVersion}:${role?.version ?? 0}`;
    const hit = this.cache.get(user.userId);
    if (hit && hit.key === key && Date.now() - hit.at < PermissionsService.TTL) return hit.grants;

    const roleGrants = role?.grants ?? DEFAULT_ROLE_GRANTS[user.role as RoleKey] ?? [];
    const extras = await this.userPerms
      .find({ organizationId: user.orgId, userId: user.userId, $or: [{ expiresAt: null }, { expiresAt: { $gt: new Date() } }] })
      .lean<{ grant: string; recordIds?: string[] }[]>();

    const out: Grant[] = [];
    for (const s of roleGrants) {
      const g = parseGrant(s);
      if (g && (user.role === 'super_admin' || !SUPER_ADMIN_ONLY.has(s))) out.push(g);
    }
    for (const e of extras) {
      const g = parseGrant(e.grant);
      if (g && (user.role === 'super_admin' || !SUPER_ADMIN_ONLY.has(e.grant))) out.push({ ...g, recordIds: e.recordIds });
    }
    this.cache.set(user.userId, { at: Date.now(), key, grants: out });
    return out;
  }

  invalidate(userId: string): void {
    this.cache.delete(userId);
  }

  invalidateAll(): void {
    this.cache.clear();
  }

  static build(grants: Grant[], role: string): Authz {
    const best = new Map<string, Scope>();
    const records = new Map<string, string[]>();
    for (const g of grants) {
      const k = `${g.resource}:${g.action}`;
      const cur = best.get(k);
      if (!cur || scopeRank(g.scope) > scopeRank(cur)) best.set(k, g.scope);
      if (g.scope === 'records' && g.recordIds?.length) records.set(k, [...(records.get(k) ?? []), ...g.recordIds]);
    }
    return {
      grants,
      isSuperAdmin: role === 'super_admin',
      scope: (r, a) => best.get(`${r}:${a}`) ?? null,
      can: (r, a, atLeast) => {
        const s = best.get(`${r}:${a}`);
        return !!s && (!atLeast || scopeRank(s) >= scopeRank(atLeast));
      },
      recordIds: (r, a) => records.get(`${r}:${a}`) ?? [],
    };
  }

  /** Throws 403 unless the caller holds resource:action; returns the scope. */
  static require(ctx: Ctx, resource: Resource, action: Action, atLeast?: Scope): Scope {
    const s = ctx.authz.scope(resource, action);
    if (!s || (atLeast && scopeRank(s) < scopeRank(atLeast))) {
      throw new ApiError(HttpStatus.FORBIDDEN, 'FORBIDDEN', "You don't have permission to do that.");
    }
    return s;
  }

  /**
   * Grant authority: a user may hand out only grants they hold themselves at the same or broader
   * scope, never super-admin-only grants, and only super_admin may assign the super_admin role.
   */
  static canGrant(ctx: Ctx, grant: string): boolean {
    if (ctx.authz.isSuperAdmin) return true;
    if (SUPER_ADMIN_ONLY.has(grant)) return false;
    const g = parseGrant(grant);
    if (!g) return false;
    if (!ctx.authz.can('roles', 'manage')) return false;
    return ctx.authz.can(g.resource, g.action, g.scope === 'records' ? 'own' : g.scope);
  }

  static canAssignRole(ctx: Ctx, role: string): boolean {
    if (!ROLES.includes(role as RoleKey)) return false;
    if (role === 'super_admin') return ctx.authz.isSuperAdmin;
    if (!ctx.authz.can('roles', 'manage')) return false;
    // A role may be assigned only if every grant it carries could be granted by the caller.
    return ctx.authz.isSuperAdmin || DEFAULT_ROLE_GRANTS[role as RoleKey].every((s) => PermissionsService.canGrant(ctx, s));
  }

  /** The permission set returned to the client (it only reads it; the server re-checks every call). */
  static describe(authz: Authz): string[] {
    return [...new Set(authz.grants.map((g) => grantKey(g)))].sort();
  }

  static oid(id: string): Types.ObjectId {
    return new Types.ObjectId(id);
  }
}
