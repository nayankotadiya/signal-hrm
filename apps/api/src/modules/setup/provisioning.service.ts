import { Injectable } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { DEFAULT_ROLE_GRANTS, ROLES } from '../../common/authz/catalog';
import { InjectModel } from '../../database/model';

const ROLE_NAMES: Record<string, string> = {
  super_admin: 'Super Admin',
  admin: 'Admin / CEO',
  hr: 'HR',
  manager: 'Manager',
  team_leader: 'Team Leader',
  employee: 'Employee',
  moderator: 'Moderator',
  user: 'User',
};

/**
 * Idempotent organization setup: roles with default grants, the initial departments, leave types,
 * expense categories and lead sources. Safe to run again (it only adds what is missing).
 * Never deletes or overwrites existing data.
 */
@Injectable()
export class ProvisioningService {
  constructor(
    @InjectModel('Organization') private readonly orgs: Model<any>,
    @InjectModel('Role') private readonly roles: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('LeaveType') private readonly leaveTypes: Model<any>,
    @InjectModel('LeavePolicy') private readonly leavePolicies: Model<any>,
    @InjectModel('ExpenseCategory') private readonly expenseCategories: Model<any>,
    @InjectModel('LeadSource') private readonly leadSources: Model<any>,
    @InjectModel('StatutoryRule') private readonly statutoryRules: Model<any>,
  ) {}

  async provision(orgId: Types.ObjectId): Promise<void> {
    for (const key of ROLES) {
      await this.roles.updateOne(
        { organizationId: orgId, key },
        { $setOnInsert: { organizationId: orgId, key, name: ROLE_NAMES[key], grants: DEFAULT_ROLE_GRANTS[key], system: true, version: 1 } },
        { upsert: true },
      );
    }
    // Super Admin always holds every grant (catalog may grow between releases).
    await this.roles.updateOne({ organizationId: orgId, key: 'super_admin' }, { $set: { grants: DEFAULT_ROLE_GRANTS.super_admin }, $inc: { version: 1 } });

    for (const name of ['Content', 'Meta', 'Shopify']) {
      await this.departments.updateOne({ organizationId: orgId, name }, { $setOnInsert: { organizationId: orgId, name, status: 'active' } }, { upsert: true });
    }
    const types = [
      { code: 'CL', name: 'Casual Leave', paid: true, color: '#6C5CE7', quota: 12 },
      { code: 'SL', name: 'Sick Leave', paid: true, color: '#14B8A6', quota: 8, attach: 2 },
      { code: 'PL', name: 'Paid Leave', paid: true, color: '#F5A524', quota: 15 },
      { code: 'UL', name: 'Unpaid Leave', paid: false, color: '#8E8E96', quota: 0 },
      { code: 'CO', name: 'Compensatory Leave', paid: true, color: '#7BC143', quota: 0 },
    ];
    for (const t of types) {
      const r = await this.leaveTypes.findOneAndUpdate(
        { organizationId: orgId, code: t.code },
        { $setOnInsert: { organizationId: orgId, code: t.code, name: t.name, paid: t.paid, color: t.color, allowHalfDay: true, requiresAttachmentAfterDays: t.attach, active: true } },
        { upsert: true, new: true },
      );
      const exists = await this.leavePolicies.exists({ organizationId: orgId, leaveTypeId: r._id });
      if (!exists) {
        await this.leavePolicies.create({
          organizationId: orgId,
          name: `${t.name} policy`,
          leaveTypeId: r._id,
          annualQuota: t.quota,
          accrual: t.code === 'PL' ? 'monthly' : 'upfront',
          carryForwardMax: t.code === 'PL' ? 10 : 0,
          allowNegative: t.code === 'UL',
          minNoticeDays: t.code === 'PL' ? 3 : 0,
          appliesTo: { afterProbationOnly: t.code === 'PL' },
        });
      }
    }
    for (const c of [
      { name: 'Travel', perClaimLimit: 20000 },
      { name: 'Food and meals', perClaimLimit: 2000 },
      { name: 'Internet and phone', monthlyLimit: 1500 },
      { name: 'Office supplies', perClaimLimit: 5000 },
      { name: 'Client entertainment', perClaimLimit: 10000 },
      { name: 'Software and tools', perClaimLimit: 10000 },
      { name: 'Other' },
    ]) {
      await this.expenseCategories.updateOne({ organizationId: orgId, name: c.name }, { $setOnInsert: { organizationId: orgId, ...c, active: true } }, { upsert: true });
    }
    for (const s of [
      ['manual', 'Manual entry'],
      ['meta', 'Meta lead ads'],
      ['website', 'Website'],
      ['referral', 'Referral'],
      ['whatsapp', 'WhatsApp'],
      ['import', 'Import'],
    ]) {
      await this.leadSources.updateOne({ organizationId: orgId, key: s[0] }, { $setOnInsert: { organizationId: orgId, key: s[0], name: s[1], active: true } }, { upsert: true });
    }

    const defaultStatutory = [
      { code: 'PF_EMPLOYEE', name: 'Provident Fund (Employee)', kind: 'deduction', basis: 'component', basisComponent: 'basic', percent: 12, wageCeiling: 15000, cap: 1800, active: true },
      { code: 'PF_EMPLOYER', name: 'Provident Fund (Employer)', kind: 'employer_contribution', basis: 'component', basisComponent: 'basic', percent: 12, wageCeiling: 15000, cap: 1800, active: true },
      { code: 'ESI_EMPLOYEE', name: 'ESI (Employee)', kind: 'deduction', basis: 'gross', wageCeiling: 21000, percent: 0.75, active: true },
      { code: 'ESI_EMPLOYER', name: 'ESI (Employer)', kind: 'employer_contribution', basis: 'gross', wageCeiling: 21000, percent: 3.25, active: true },
      { code: 'PT_GJ', name: 'Professional Tax (Gujarat)', kind: 'deduction', basis: 'slab', slabs: [{ upTo: 11999, amount: 0 }, { upTo: 999999999, amount: 200 }], active: true },
    ];
    for (const r of defaultStatutory) {
      await this.statutoryRules.updateOne(
        { organizationId: orgId, code: r.code },
        { $setOnInsert: { organizationId: orgId, ...r } },
        { upsert: true },
      );
    }
  }
}
