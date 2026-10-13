import { Body, Controller, Get, HttpCode, Param, Patch, Post, Put, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AllowStatuses, C, Can, Ctx, RequireReauth } from '../../common/auth/context';
import { ROLES } from '../../common/authz/catalog';
import { badRequest, listQuery, oid, parse } from '../../common/http/validation';
import { InjectModel, serialize } from '../../database/model';
import { createUserInput, UsersService } from './users.service';

@ApiTags('users')
@Controller({ path: 'users', version: '1' })
export class UsersController {
  constructor(private readonly users: UsersService) {}

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.users.list(ctx, parse(listQuery.extend({ role: z.string().optional() }), q));
  }

  @Post()
  @Can('users', 'create')
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.users.create(ctx, parse(createUserInput, body));
  }

  /** Super Admin creation: existing Super Admin + strong re-authentication. */
  @Post('super-admins')
  @RequireReauth()
  createSuperAdmin(@C() ctx: Ctx, @Body() body: unknown) {
    return this.users.createSuperAdmin(ctx, parse(z.object({ fullName: z.string().trim().min(2).max(120), email: z.string().email() }), body));
  }

  @Get(':id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.users.get(ctx, id);
  }

  @Post(':id/invitation')
  @HttpCode(200)
  resend(@C() ctx: Ctx, @Param('id') id: string) {
    return this.users.resendInvitation(ctx, id);
  }

  /** One-time temporary password (shown once). Needs recent re-authentication. */
  @Post(':id/temporary-password')
  @RequireReauth()
  @HttpCode(200)
  temporaryPassword(@C() ctx: Ctx, @Param('id') id: string) {
    return this.users.setTemporaryPassword(ctx, id);
  }

  @Post(':id/status')
  @HttpCode(200)
  status(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(z.object({ status: z.enum(['active', 'suspended', 'inactive']), reason: z.string().max(300).optional() }), body);
    return this.users.setStatus(ctx, id, b.status, b.reason);
  }

  /** Role changes require recent re-authentication (they change what someone can see). */
  @Put(':id/role')
  @RequireReauth()
  role(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.users.setRole(ctx, id, parse(z.object({ role: z.enum(ROLES) }), body).role);
  }

  @Get(':id/permissions')
  permissions(@C() ctx: Ctx, @Param('id') id: string) {
    return this.users.permissionsOf(ctx, id);
  }

  @Post(':id/permissions')
  @RequireReauth()
  grant(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(z.object({ grant: z.string(), recordIds: z.array(z.string()).optional(), reason: z.string().max(300).optional(), expiresAt: z.coerce.date().optional() }), body);
    return this.users.addGrant(ctx, id, b.grant, b.recordIds, b.reason, b.expiresAt);
  }

  @Post(':id/permissions/remove')
  @RequireReauth()
  @HttpCode(200)
  revoke(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.users.removeGrant(ctx, id, parse(z.object({ grant: z.string() }), body).grant);
  }
}

const profileBody = z.object({
  fullName: z.string().trim().min(2).max(120).optional(),
  displayName: z.string().trim().min(1).max(60).optional(),
  username: z.string().trim().toLowerCase().regex(/^[a-z0-9._-]{3,30}$/, '3-30 letters, numbers, dots, dashes').optional(),
  phone: z.string().regex(/^\+[1-9]\d{7,14}$/).optional().nullable(),
  timezone: z.string().max(60).optional(),
  language: z.enum(['en', 'hi', 'gu', 'en-hinglish']).optional(),
  photoFileId: z.string().optional().nullable(),
});

/** The signed-in user's own profile and N UI preferences. */
@ApiTags('me')
@Controller({ path: 'me', version: '1' })
export class MeController {
  constructor(
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('UserPreferences') private readonly prefs: Model<any>,
  ) {}

  @AllowStatuses('pending')
  @Patch('profile')
  async profile(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(profileBody, body);
    if (b.timezone) {
      try {
        new Intl.DateTimeFormat('en', { timeZone: b.timezone });
      } catch {
        throw badRequest('TIMEZONE_INVALID', 'Pick a valid time zone.', 'timezone');
      }
    }
    if (b.username && (await this.users.exists({ organizationId: ctx.orgOid, username: b.username, _id: { $ne: ctx.userOid } }))) {
      throw badRequest('USERNAME_TAKEN', 'That username is taken.', 'username');
    }
    const set: Record<string, unknown> = { ...b };
    if (b.photoFileId) set.photoFileId = oid(b.photoFileId);
    if (b.phone !== undefined) set.phoneVerified = false;
    await this.users.updateOne({ _id: ctx.userOid }, { $set: set });
    return serialize(await this.users.findById(ctx.userOid, { passwordHash: 0, googleSub: 0, appleSub: 0 }).lean());
  }

  @Get('preferences')
  async getPrefs(@C() ctx: Ctx) {
    const p = await this.prefs.findOne({ organizationId: ctx.orgOid, userId: ctx.userOid }).lean<any>();
    return { nui: p?.nui ?? null, dashboard: p?.dashboard ?? null, updatedAt: p?.updatedAt ?? null };
  }

  /** N UI preferences sync across devices. Changing them never touches data or permissions. */
  @Put('preferences')
  async setPrefs(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.object({ nui: z.record(z.any()).optional(), dashboard: z.record(z.any()).optional() }), body);
    if (JSON.stringify(b).length > 20_000) throw badRequest('PREFERENCES_TOO_LARGE', 'Preferences are too large.');
    const set: Record<string, unknown> = {};
    if (b.nui) set.nui = b.nui;
    if (b.dashboard) set.dashboard = b.dashboard;
    const p = await this.prefs.findOneAndUpdate({ organizationId: ctx.orgOid, userId: ctx.userOid }, { $set: set }, { upsert: true, new: true }).lean<any>();
    return { nui: p.nui, dashboard: p.dashboard, updatedAt: p.updatedAt };
  }
}
