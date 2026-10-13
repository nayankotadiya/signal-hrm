import { safeKeys } from '../audit/audit.service';
import { DEFAULT_ROLE_GRANTS, parseGrant, RESOURCES } from './catalog';
import { PermissionsService } from './permissions.service';

const ctxFor = (grants: string[], role = 'manager') => ({ authz: PermissionsService.build(grants.map((g) => parseGrant(g)!), role) }) as any;

describe('permission model', () => {
  it('broadest scope wins and atLeast is respected', () => {
    const a = PermissionsService.build(['leave:view:own', 'leave:view:team'].map((g) => parseGrant(g)!), 'manager');
    expect(a.scope('leave', 'view')).toBe('team');
    expect(a.can('leave', 'view', 'team')).toBe(true);
    expect(a.can('leave', 'view', 'organization')).toBe(false);
    expect(a.can('payroll', 'view')).toBe(false);
  });

  it('rejects unknown grant strings', () => {
    expect(parseGrant('payroll:fly:organization')).toBeNull();
    expect(parseGrant('nope:view:own')).toBeNull();
    expect(parseGrant('payroll:view')).toBeNull();
  });

  it('Super Admin holds every grant at organization scope', () => {
    const all = DEFAULT_ROLE_GRANTS.super_admin;
    expect(all).toContain('payroll:manage:organization');
    expect(all.length).toBe(Object.keys(RESOURCES).length * 10);
  });

  it('default roles: admin has no payroll or salary unless granted; employee is own-scoped', () => {
    expect(DEFAULT_ROLE_GRANTS.admin.some((g) => g.startsWith('payroll:') || g.startsWith('salary:'))).toBe(false);
    expect(DEFAULT_ROLE_GRANTS.employee.every((g) => g.endsWith(':own') || g.startsWith('holidays:') || g.startsWith('announcements:'))).toBe(true);
  });

  it('grant authority: only grants you hold, never above your scope, and only with roles:manage', () => {
    const ctx = ctxFor(['roles:manage:organization', 'leave:view:team']);
    expect(PermissionsService.canGrant(ctx, 'leave:view:team')).toBe(true);
    expect(PermissionsService.canGrant(ctx, 'leave:view:organization')).toBe(false);
    expect(PermissionsService.canGrant(ctx, 'payroll:view:own')).toBe(false);
    expect(PermissionsService.canGrant(ctxFor(['leave:view:team']), 'leave:view:team')).toBe(false);
    expect(PermissionsService.canAssignRole(ctx, 'super_admin')).toBe(false);
  });

  it('audit change keys never contain dots (MongoDB field names)', () => {
    expect(Object.keys(safeKeys({ 'bank.accountName': { from: null, to: 'x' }, $where: { from: 1, to: 2 } }))).toEqual(['bank › accountName', '＄where']);
  });
});
