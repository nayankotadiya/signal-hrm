import { Inject, Injectable } from '@nestjs/common';
import { Model } from 'mongoose';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { OrgSettingsService } from '../../common/org/org-settings.service';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { InjectModel } from '../../database/model';

export interface ChecklistStep {
  key: string;
  group: 'organization' | 'people' | 'time' | 'money' | 'platform';
  title: string;
  description: string;
  done: boolean;
  /** Short factual status, e.g. "3 locations". */
  status: string;
  link: string;
  required: boolean;
}

/** First-run setup checklist. Each step is evaluated from real configuration, never from a stored "done" flag. */
@Injectable()
export class SetupChecklistService {
  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly settings: OrgSettingsService,
    @InjectModel('Location') private readonly locations: Model<any>,
    @InjectModel('Shift') private readonly shifts: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('LeavePolicy') private readonly leavePolicies: Model<any>,
    @InjectModel('Holiday') private readonly holidays: Model<any>,
    @InjectModel('SalaryStructure') private readonly salaries: Model<any>,
    @InjectModel('StatutoryRule') private readonly statutory: Model<any>,
    @InjectModel('ApprovalRule') private readonly approvalRules: Model<any>,
    @InjectModel('BackupRecord') private readonly backups: Model<any>,
    @InjectModel('Document') private readonly documents: Model<any>,
  ) {}

  async get(ctx: Ctx): Promise<{ steps: ChecklistStep[]; done: number; total: number; requiredRemaining: number }> {
    PermissionsService.require(ctx, 'organization', 'configure', 'organization');
    const o = ctx.orgOid;
    const year = new Date().getUTCFullYear();
    const org = await this.settings.get(o);
    const [locs, shifts, depts, emps, activeUsers, policies, hols, salaries, statutory, rules, verifiedBackup, policyDocs, managersSet] = await Promise.all([
      this.locations.countDocuments({ organizationId: o, active: true }),
      this.shifts.countDocuments({ organizationId: o, status: 'active' }),
      this.departments.countDocuments({ organizationId: o }),
      this.employees.countDocuments({ organizationId: o, status: { $in: ['onboarding', 'active', 'probation', 'notice'] } }),
      this.users.countDocuments({ organizationId: o, status: 'active' }),
      this.leavePolicies.countDocuments({ organizationId: o }),
      this.holidays.countDocuments({ organizationId: o, date: { $gte: `${year}-01-01`, $lte: `${year}-12-31` } }),
      this.salaries.countDocuments({ organizationId: o, status: 'approved' }),
      this.statutory.countDocuments({ organizationId: o }),
      this.approvalRules.countDocuments({ organizationId: o }),
      this.backups.exists({ status: 'verified' }),
      this.documents.countDocuments({ organizationId: o, isPolicy: true, status: 'active' }),
      this.employees.countDocuments({ organizationId: o, reportingManagerId: { $exists: true, $ne: null } }),
    ]);
    const profileDone = !!(org?.name && org?.timezone && org?.legalName && (org?.primaryContact?.email || org?.supportEmail));
    const plural = (n: number, w: string) => `${n} ${w}${n === 1 ? '' : 's'}`;
    const steps: ChecklistStep[] = [
      { key: 'org.profile', group: 'organization', title: 'Company profile', description: 'Legal name, time zone, working days and a contact email.', done: profileDone, status: profileDone ? 'Complete' : 'Missing details', link: '/settings/organization', required: true },
      { key: 'org.departments', group: 'organization', title: 'Departments', description: 'Group people for reports, approvals and visibility.', done: depts > 0, status: plural(depts, 'department'), link: '/settings/departments', required: true },
      { key: 'time.locations', group: 'time', title: 'Work locations and geofences', description: 'Where check-in is allowed and the allowed radius.', done: locs > 0, status: plural(locs, 'location'), link: '/settings/locations', required: true },
      { key: 'time.shifts', group: 'time', title: 'Shifts', description: 'Start time, grace period and break rules.', done: shifts > 0, status: plural(shifts, 'shift'), link: '/settings/shifts', required: true },
      { key: 'time.leave', group: 'time', title: 'Leave policies', description: 'Entitlements, accrual and carry-forward.', done: policies > 0, status: plural(policies, 'policy'), link: '/settings/leave', required: true },
      { key: 'time.holidays', group: 'time', title: `Holiday calendar ${year}`, description: 'Public and optional holidays for the year.', done: hols > 0, status: plural(hols, 'holiday'), link: '/settings/holidays', required: false },
      { key: 'people.employees', group: 'people', title: 'Add employees', description: 'Add people manually or import a file.', done: emps > 0, status: plural(emps, 'employee'), link: '/people/new', required: true },
      { key: 'people.managers', group: 'people', title: 'Reporting managers', description: 'Approvals route to the reporting manager first.', done: managersSet > 0, status: `${managersSet} of ${emps} assigned`, link: '/people?filter=no_manager', required: true },
      { key: 'people.invites', group: 'people', title: 'Invite people to sign in', description: 'Only invited accounts can sign in.', done: activeUsers > 1, status: plural(activeUsers, 'active account'), link: '/people?filter=no_account', required: true },
      { key: 'people.policies', group: 'people', title: 'Publish company policies', description: 'Upload policies and ask employees to acknowledge them.', done: policyDocs > 0, status: plural(policyDocs, 'policy'), link: '/documents', required: false },
      { key: 'money.salary', group: 'money', title: 'Salary structures', description: 'Needed before the first payroll run.', done: salaries > 0, status: `${salaries} approved`, link: '/payroll/salary', required: false },
      { key: 'money.statutory', group: 'money', title: 'Statutory rules', description: 'PF, ESI, professional tax and TDS settings.', done: statutory > 0, status: plural(statutory, 'rule'), link: '/payroll/statutory', required: false },
      { key: 'org.approvals', group: 'organization', title: 'Approval rules', description: 'Default chains apply until you customise them.', done: rules > 0, status: rules > 0 ? plural(rules, 'custom rule') : 'Using defaults', link: '/settings/approvals', required: false },
      { key: 'platform.email', group: 'platform', title: 'Email delivery', description: 'Sign-in codes and notifications need a working mail server.', done: !!this.env.SMTP_HOST, status: this.env.SMTP_HOST ? 'Configured' : 'Not configured', link: '/system', required: true },
      { key: 'platform.storage', group: 'platform', title: 'File storage', description: 'Documents, receipts and selfies need a storage provider.', done: this.env.STORAGE_PROVIDER !== 'none', status: this.env.STORAGE_PROVIDER === 'none' ? 'Not configured' : this.env.STORAGE_PROVIDER.replace('_', ' '), link: '/system', required: true },
      { key: 'platform.backups', group: 'platform', title: 'Verified backup', description: 'Automatic backups enabled and at least one verified.', done: this.env.BACKUP_ENABLED && !!verifiedBackup, status: !this.env.BACKUP_ENABLED ? 'Disabled' : verifiedBackup ? 'Verified backup exists' : 'No verified backup yet', link: '/system/backups', required: true },
    ];
    const done = steps.filter((s) => s.done).length;
    return { steps, done, total: steps.length, requiredRemaining: steps.filter((s) => s.required && !s.done).length };
  }
}
