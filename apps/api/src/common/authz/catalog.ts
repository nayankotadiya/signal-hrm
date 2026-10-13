/**
 * Permission catalog (structure section 2.7): action + scope per resource.
 * A grant is written "resource:action:scope", e.g. "leave:approve:team".
 * Roles give defaults; extra grants come from user_permissions. The backend checks every request.
 */
export const ACTIONS = ['view', 'create', 'edit', 'delete', 'approve', 'reject', 'assign', 'export', 'manage', 'configure'] as const;
export type Action = (typeof ACTIONS)[number];

/** Narrow to broad. `records` = specific authorized records only. */
export const SCOPES = ['own', 'records', 'team', 'department', 'organization'] as const;
export type Scope = (typeof SCOPES)[number];
export const scopeRank = (s: Scope): number => SCOPES.indexOf(s);

export const RESOURCES = {
  organization: 'Organization settings',
  users: 'User accounts',
  employees: 'Employee records',
  employees_sensitive: 'Sensitive employee fields (bank, tax, date of birth, exit reason)',
  departments: 'Departments',
  teams: 'Teams',
  roles: 'Roles and permissions',
  features: 'Feature access',
  attendance: 'Attendance',
  attendance_evidence: 'Attendance selfies and location evidence',
  locations: 'Work locations and geofences',
  shifts: 'Shifts and schedules',
  leave: 'Leave',
  holidays: 'Holidays and HR events',
  announcements: 'Announcements and kudos',
  expenses: 'Expenses and reimbursements',
  salary: 'Salary structures and compensation',
  payroll: 'Payroll runs',
  payslips: 'Payslips',
  tasks: 'Tasks',
  crm: 'CRM and leads',
  travel: 'Travel',
  meetings: 'Calls and meetings',
  documents: 'Documents and policies',
  approvals: 'Approval Center',
  notifications: 'Notification templates and delivery',
  reports: 'Reports and analytics',
  storage: 'Files and storage',
  backups: 'Backups and restore',
  moderation: 'Moderation',
  audit: 'Audit logs',
  security: 'Security center and sessions',
  system: 'Database and system health',
  integrations: 'Integrations',
  nui_defaults: 'Organization N UI defaults',
  privacy: 'Personal data export',
} as const;
export type Resource = keyof typeof RESOURCES;

export const ROLES = ['super_admin', 'admin', 'hr', 'manager', 'employee', 'moderator', 'user'] as const;
export type RoleKey = (typeof ROLES)[number];

export interface Grant {
  resource: Resource;
  action: Action;
  scope: Scope;
  /** Only for scope "records". */
  recordIds?: string[];
}

export const grantKey = (g: Pick<Grant, 'resource' | 'action' | 'scope'>): string => `${g.resource}:${g.action}:${g.scope}`;

export function parseGrant(s: string): Grant | null {
  const [resource, action, scope] = s.split(':');
  if (!(resource in RESOURCES) || !ACTIONS.includes(action as Action) || !SCOPES.includes(scope as Scope)) return null;
  return { resource: resource as Resource, action: action as Action, scope: scope as Scope };
}

/** Helper: many actions at one scope. */
const g = (resource: Resource, actions: Action[], scope: Scope): string[] => actions.map((a) => `${resource}:${a}:${scope}`);
const ALL = [...ACTIONS];

const own = (r: Resource, a: Action[]) => g(r, a, 'own');
const team = (r: Resource, a: Action[]) => g(r, a, 'team');
const org = (r: Resource, a: Action[]) => g(r, a, 'organization');

/** Personal basics every account holder gets (except the minimal `user`, which gets the first block only). */
const SELF_MIN = [...own('privacy', ['export']), ...own('notifications', ['view'])];
const SELF = [
  ...SELF_MIN,
  ...own('employees', ['view']),
  ...own('attendance', ['view', 'create']),
  ...own('shifts', ['view', 'create']),
  ...own('leave', ['view', 'create']),
  ...own('expenses', ['view', 'create']),
  ...own('travel', ['view', 'create']),
  ...own('tasks', ['view', 'edit']),
  ...own('meetings', ['view', 'create']),
  ...own('documents', ['view']),
  ...own('payslips', ['view']),
  ...own('approvals', ['view']),
  ...org('holidays', ['view']),
  ...org('announcements', ['view']),
];

export const DEFAULT_ROLE_GRANTS: Record<RoleKey, string[]> = {
  super_admin: (Object.keys(RESOURCES) as Resource[]).flatMap((r) => org(r, ALL)),

  // Admin / CEO: operations; payroll, salary and CRM only when explicitly granted.
  admin: [
    ...SELF,
    ...org('organization', ['view', 'configure']),
    ...org('users', ['view', 'create', 'edit', 'manage']),
    ...org('employees', ['view', 'create', 'edit', 'export']),
    ...org('departments', ['view', 'create', 'edit', 'delete', 'assign']),
    ...org('teams', ['view', 'create', 'edit', 'delete', 'assign']),
    ...org('roles', ['view', 'manage']),
    ...org('features', ['view']),
    ...org('attendance', ['view', 'export']),
    ...org('locations', ['view']),
    ...org('shifts', ['view']),
    ...org('leave', ['view', 'approve', 'reject']),
    ...org('holidays', ['view', 'manage']),
    ...org('announcements', ['view', 'create', 'manage']),
    ...org('expenses', ['view', 'approve', 'reject']),
    ...org('tasks', ['view', 'create', 'edit', 'assign']),
    ...org('travel', ['view', 'approve', 'reject']),
    ...org('meetings', ['view', 'create', 'edit']),
    ...org('documents', ['view', 'create', 'edit']),
    ...org('approvals', ['view', 'approve', 'reject']),
    ...org('reports', ['view', 'export']),
    ...org('storage', ['view']),
    ...org('audit', ['view']),
    ...org('security', ['view']),
    ...org('system', ['view']),
  ],

  // HR: company-wide HR responsibility. Payroll and salary editing are separate grants.
  hr: [
    ...SELF,
    ...org('organization', ['view']),
    ...org('users', ['view', 'create', 'edit']),
    ...org('employees', ['view', 'create', 'edit', 'export']),
    ...org('employees_sensitive', ['view', 'edit']),
    ...org('departments', ['view', 'assign']),
    ...org('teams', ['view', 'create', 'edit', 'assign']),
    ...org('attendance', ['view', 'edit', 'approve', 'reject', 'export']),
    ...org('attendance_evidence', ['view']),
    ...org('locations', ['view', 'configure']),
    ...org('shifts', ['view', 'create', 'edit', 'assign', 'approve', 'reject']),
    ...org('leave', ['view', 'approve', 'reject', 'manage', 'export']),
    ...org('holidays', ['view', 'manage']),
    ...org('announcements', ['view', 'create', 'manage']),
    ...org('expenses', ['view', 'approve', 'reject']),
    ...org('travel', ['view']),
    ...org('meetings', ['view', 'create', 'edit']),
    ...org('documents', ['view', 'create', 'edit', 'delete', 'manage']),
    ...org('approvals', ['view', 'approve', 'reject']),
    ...org('reports', ['view', 'export']),
    ...org('tasks', ['view', 'create', 'assign']),
  ],

  // Manager: assigned team only. No unrelated departments or company-wide confidential data.
  manager: [
    ...SELF,
    ...team('employees', ['view']),
    ...team('attendance', ['view', 'approve', 'reject']),
    ...team('shifts', ['view', 'approve', 'reject']),
    ...team('leave', ['view', 'approve', 'reject']),
    ...team('expenses', ['view', 'approve', 'reject']),
    ...team('travel', ['view', 'approve', 'reject']),
    ...team('tasks', ['view', 'create', 'edit', 'assign']),
    ...team('meetings', ['view', 'create', 'edit']),
    ...team('approvals', ['view', 'approve', 'reject']),
    ...team('reports', ['view']),
    ...team('teams', ['view']),
  ],

  employee: [...SELF],

  // Moderator: no payroll, salary, attendance administration, leave balances or private messages.
  moderator: [
    ...SELF_MIN,
    ...own('employees', ['view']),
    ...org('moderation', ['view', 'manage']),
    ...org('announcements', ['view']),
    ...org('holidays', ['view']),
    ...own('approvals', ['view']),
  ],

  user: [...SELF_MIN],
};

/** Grants nobody below super_admin may hold or hand out. */
export const SUPER_ADMIN_ONLY = new Set<string>(['backups:manage:organization', 'backups:configure:organization', 'system:configure:organization']);
