import { Body, Controller, Get, Param, Patch, Put } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AuditService, diff } from '../../common/audit/audit.service';
import { C, Can, Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { badRequest, forbidden, parse } from '../../common/http/validation';
import { OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';

/** Modules that can be switched off per organization (feature access control). */
export const FEATURE_REGISTRY = [
  { key: 'attendance', name: 'Attendance', core: false },
  { key: 'geofence', name: 'Geofencing and selfie attendance', core: false },
  { key: 'shifts', name: 'Shifts and schedules', core: false },
  { key: 'leave', name: 'Leave', core: false },
  { key: 'holidays', name: 'Holidays and HR events', core: false },
  { key: 'expenses', name: 'Expenses and reimbursements', core: false },
  { key: 'payroll', name: 'Salary and payroll', core: false },
  { key: 'tasks', name: 'Tasks', core: false },
  { key: 'crm', name: 'CRM and leads', core: false },
  { key: 'travel', name: 'Travel', core: false },
  { key: 'meetings', name: 'Calls and meetings', core: false },
  { key: 'documents', name: 'Documents and policies', core: false },
  { key: 'moderation', name: 'Moderation', core: false },
  { key: 'announcements', name: 'Announcements and kudos', core: false },
  { key: 'integrations', name: 'Integrations', core: false },
  { key: 'ai_assistant', name: 'AI assistant (off by default, may add cost)', core: false },
] as const;

const profileBody = z.object({
  name: z.string().trim().min(2).max(120).optional(),
  legalName: z.string().trim().max(200).optional(),
  logoFileId: z.string().optional().nullable(),
  registration: z.object({ gstin: z.string().max(20).optional(), pan: z.string().max(12).optional(), cin: z.string().max(25).optional(), other: z.string().max(100).optional() }).optional(),
  primaryContact: z.object({ name: z.string().max(100).optional(), email: z.string().email().optional(), phone: z.string().max(20).optional() }).optional(),
  supportEmail: z.string().email().optional(),
  timezone: z.string().max(60).optional(),
  currency: z.string().length(3).toUpperCase().optional(),
  dateFormat: z.enum(['dd MMM yyyy', 'dd/MM/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd']).optional(),
  timeFormat: z.enum(['12h', '24h']).optional(),
  weekStart: z.number().int().min(0).max(6).optional(),
  workingDays: z.array(z.number().int().min(0).max(6)).max(7).optional(),
  offices: z.array(z.object({ label: z.string().max(60), address: z.string().max(300) })).max(50).optional(),
  defaultLocale: z.enum(['en', 'hi', 'gu']).optional(),
  branding: z.object({ primaryColor: z.string().regex(/^#[0-9a-fA-F]{6}$/).optional(), accent: z.string().optional() }).optional(),
});

const SECTION_SCHEMAS: Record<string, z.ZodTypeAny> = {
  attendance: z.object({
    checkIn: z.object({ requireLocation: z.boolean(), requireSelfie: z.boolean() }).partial().optional(),
    checkOut: z.object({ requireLocation: z.boolean(), requireSelfie: z.boolean() }).partial().optional(),
    maxAccuracyMeters: z.number().int().min(5).max(2000).optional(),
    allowRemote: z.boolean().optional(),
    gpsRetryLimit: z.number().int().min(0).max(10).optional(),
    halfDayMinutes: z.number().int().min(30).max(720).optional(),
    fullDayMinutes: z.number().int().min(60).max(1440).optional(),
    autoCheckoutHours: z.number().int().min(4).max(24).optional(),
    impossibleTravelKmh: z.number().int().min(30).max(1200).optional(),
    selfieRetentionDays: z.number().int().min(1).max(3650).optional(),
  }),
  leave: z.object({ approvalByHr: z.boolean(), allowNegative: z.boolean(), countWeekends: z.boolean(), countHolidays: z.boolean() }).partial(),
  payroll: z.object({ payDay: z.number().int().min(1).max(28), cutoffDay: z.number().int().min(1).max(28), lopBasis: z.enum(['calendar_days', 'working_days', 'fixed_30']), roundNetPay: z.boolean() }).partial(),
  security: z.object({ sessionDays: z.number().int().min(1).max(90), reauthMinutes: z.number().int().min(1).max(60), maxFailedLogins: z.number().int().min(3).max(20), lockMinutes: z.number().int().min(1).max(1440), passwordLogin: z.boolean() }).partial(),
  approvals: z.object({ preventSelfApproval: z.boolean(), escalationHours: z.number().int().min(1).max(720) }).partial(),
  notifications: z.object({ essentialEvents: z.array(z.string()).max(30) }).partial(),
  expenses: z.object({ receiptRequiredAbove: z.number().min(0) }).partial(),
};

@ApiTags('organization')
@Controller({ path: 'organization', version: '1' })
export class OrganizationController {
  constructor(
    private readonly audit: AuditService,
    private readonly orgSettings: OrgSettingsService,
    @InjectModel('Organization') private readonly orgs: Model<any>,
    @InjectModel('PermissionChange') private readonly changes: Model<any>,
  ) {}

  @Get()
  @Can('organization', 'view')
  async get(@C() ctx: Ctx) {
    const org = await this.orgs.findById(ctx.orgOid).lean<any>();
    return { ...serialize(org), features: this.orgSettings.features(org) };
  }

  @Patch()
  @Can('organization', 'configure', 'organization')
  async update(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(profileBody, body);
    if (b.timezone) {
      try {
        new Intl.DateTimeFormat('en', { timeZone: b.timezone });
      } catch {
        throw badRequest('TIMEZONE_INVALID', 'Pick a valid time zone.', 'timezone');
      }
    }
    const before = await this.orgs.findById(ctx.orgOid).lean<any>();
    await this.orgs.updateOne({ _id: ctx.orgOid }, { $set: b });
    this.orgSettings.clear(ctx.orgOid);
    await this.audit.record(ctx, { action: 'organization.update', resourceType: 'organization', resourceId: ctx.orgOid, changes: diff(before, b) });
    return this.get(ctx);
  }

  @Put('settings/:section')
  @Can('organization', 'configure', 'organization')
  async settings(@C() ctx: Ctx, @Param('section') section: string, @Body() body: unknown) {
    const schema = SECTION_SCHEMAS[section];
    if (!schema) throw badRequest('UNKNOWN_SECTION', 'Unknown settings section.');
    if (section === 'security' && !ctx.authz.isSuperAdmin) throw forbidden('SUPER_ADMIN_ONLY', 'Only a Super Admin can change security settings.');
    const b = parse(schema, body) as Record<string, unknown>;
    const flat: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(b)) {
      if (v && typeof v === 'object' && !Array.isArray(v)) for (const [k2, v2] of Object.entries(v)) flat[`settings.${section}.${k}.${k2}`] = v2;
      else flat[`settings.${section}.${k}`] = v;
    }
    const before = await this.orgs.findById(ctx.orgOid, { settings: 1 }).lean<any>();
    await this.orgs.updateOne({ _id: ctx.orgOid }, { $set: flat });
    this.orgSettings.clear(ctx.orgOid);
    await this.audit.record(ctx, { action: `organization.settings.${section}`, resourceType: 'organization', resourceId: ctx.orgOid, changes: diff(before?.settings?.[section] ?? {}, b) });
    return this.get(ctx);
  }

  @Get('features')
  async features(@C() ctx: Ctx) {
    const org = await this.orgSettings.get(ctx.orgOid);
    const on = this.orgSettings.features(org);
    return { items: FEATURE_REGISTRY.map((f) => ({ ...f, enabled: on[f.key] ?? f.key !== 'ai_assistant' })) };
  }

  @Put('features/:key')
  @Can('features', 'configure', 'organization')
  async toggle(@C() ctx: Ctx, @Param('key') key: string, @Body() body: unknown) {
    if (!FEATURE_REGISTRY.some((f) => f.key === key)) throw badRequest('UNKNOWN_FEATURE', 'Unknown module.');
    const { enabled } = parse(z.object({ enabled: z.boolean() }), body);
    await this.orgs.updateOne({ _id: ctx.orgOid }, { $set: { [`features.${key}`]: enabled } });
    this.orgSettings.clear(ctx.orgOid);
    await this.changes.create({ organizationId: ctx.orgOid, actorId: ctx.userOid, change: 'feature_toggled', after: { key, enabled } });
    await this.audit.record(ctx, { action: 'feature.toggle', resourceType: 'feature', resourceId: key, changes: { enabled: { from: !enabled, to: enabled } } });
    return this.features(ctx);
  }

  /** Organization-wide N UI defaults (users can still personalize). */
  @Put('nui-defaults')
  @Can('nui_defaults', 'configure', 'organization')
  async nuiDefaults(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.record(z.any()), body);
    if (JSON.stringify(b).length > 10_000) throw badRequest('TOO_LARGE', 'Defaults are too large.');
    await this.orgs.updateOne({ _id: ctx.orgOid }, { $set: { nuiDefaults: b } });
    this.orgSettings.clear(ctx.orgOid);
    await this.audit.record(ctx, { action: 'nui.defaults', resourceType: 'organization', resourceId: ctx.orgOid });
    return { nuiDefaults: b };
  }

  /** N UI Studio: publish a named theme preset for the organization. */
  @Put('nui-presets/:name')
  @Can('nui_defaults', 'configure', 'organization')
  async preset(@C() ctx: Ctx, @Param('name') name: string, @Body() body: unknown) {
    const prefs = parse(z.record(z.any()), body);
    if (!/^[\w -]{1,40}$/.test(name)) throw badRequest('NAME_INVALID', 'Use up to 40 letters, numbers and spaces.');
    await this.orgs.updateOne({ _id: ctx.orgOid }, { $pull: { nuiPresets: { name } } });
    await this.orgs.updateOne({ _id: ctx.orgOid }, { $push: { nuiPresets: { name, prefs, publishedBy: ctx.userOid, publishedAt: new Date() } } });
    this.orgSettings.clear(ctx.orgOid);
    await this.audit.record(ctx, { action: 'nui.preset_publish', resourceType: 'organization', resourceId: name });
    return { published: name };
  }

  static require = PermissionsService.require;
}
