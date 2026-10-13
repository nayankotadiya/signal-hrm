import { Body, Controller, Delete, Get, HttpCode, Param, Patch, Post, Put, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AuditService, diff } from '../../common/audit/audit.service';
import { C, Can, Ctx, Feature, Idempotent } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, dayString, listQuery, notFound, objectId, oid, parse } from '../../common/http/validation';
import { localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { NotificationsService } from '../notifications/notifications.service';
import { AttendanceService, correctionInput, punchInput } from './attendance.service';
import { applyInput, LeaveService, leaveTypeInput, policyInput } from './leave.service';
import { shiftInput, ShiftsService } from './shifts.service';

const range = z.object({ from: dayString, to: dayString });

@ApiTags('attendance')
@Feature('attendance')
@Controller({ path: 'attendance', version: '1' })
export class AttendanceController {
  constructor(private readonly svc: AttendanceService) {}

  @Get('today')
  today(@C() ctx: Ctx) {
    return this.svc.today(ctx);
  }

  /** Every punch carries an Idempotency-Key (offline queue retries are safe). */
  @Post('check-in')
  @Idempotent()
  checkIn(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.punch(ctx, 'checkIn', parse(punchInput, body));
  }

  @Post('check-out')
  @Idempotent()
  @HttpCode(200)
  checkOut(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.punch(ctx, 'checkOut', parse(punchInput, body));
  }

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery.merge(range).extend({ employeeId: objectId.optional(), flagged: z.coerce.boolean().optional(), overtime: z.coerce.boolean().optional() }), q);
    if (b.to < b.from) throw badRequest('DATES_INVALID', 'The end date is before the start.', 'to');
    return this.svc.list(ctx, b);
  }

  @Get('calendar')
  calendar(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(z.object({ employeeId: objectId.optional(), month: z.string().regex(/^\d{4}-\d{2}$/) }), q);
    return this.svc.calendar(ctx, b.employeeId ?? ctx.user.employeeId ?? '', b.month);
  }

  @Get('live')
  @Can('attendance', 'view', 'team')
  live(@C() ctx: Ctx) {
    return this.svc.live(ctx);
  }

  @Get('corrections')
  async corrections(@C() ctx: Ctx, @Query() q: unknown) {
    return { items: await this.svc.listCorrections(ctx, parse(z.object({ status: z.string().optional() }), q).status) };
  }

  @Post('corrections')
  @Idempotent()
  correction(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.requestCorrection(ctx, parse(correctionInput, body));
  }

  @Get('flags')
  @Can('attendance', 'approve')
  async flags(@C() ctx: Ctx, @Query() q: unknown) {
    return { items: await this.svc.listFlags(ctx, parse(z.object({ status: z.string().default('open') }), q).status) };
  }

  @Post('flags/:id/review')
  @HttpCode(200)
  review(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(z.object({ outcome: z.enum(['reviewed_ok', 'reviewed_concern', 'dismissed']), note: z.string().max(500).optional() }), body);
    return this.svc.reviewFlag(ctx, id, b.outcome, b.note);
  }

  @Get(':id/evidence')
  async evidence(@C() ctx: Ctx, @Param('id') id: string) {
    return { items: await this.svc.evidenceFor(ctx, id) };
  }
}

const locationBody = z.object({
  name: z.string().trim().min(2).max(80),
  address: z.string().max(300).optional(),
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  radiusMeters: z.number().int().min(10).max(5000),
  timezone: z.string().max(60).optional(),
  active: z.boolean().default(true),
});

@ApiTags('locations')
@Controller({ path: 'locations', version: '1' })
export class LocationsController {
  constructor(
    private readonly audit: AuditService,
    @InjectModel('Location') private readonly locations: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
  ) {}

  @Get()
  async list(@C() ctx: Ctx) {
    const rows = await this.locations.find({ organizationId: ctx.orgOid }).sort({ name: 1 }).lean<any[]>();
    const counts = await this.employees.aggregate([{ $match: { organizationId: ctx.orgOid, status: { $nin: ['exited', 'archived'] } } }, { $group: { _id: '$locationId', n: { $sum: 1 } } }]);
    const countOf = new Map(counts.map((c: any) => [String(c._id), c.n]));
    return { items: serialize(rows).map((l: any) => ({ ...l, employeeCount: countOf.get(l.id) ?? 0 })) };
  }

  @Post()
  @Can('locations', 'configure', 'organization')
  async create(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(locationBody, body);
    const l = await this.locations.create({ ...b, organizationId: ctx.orgOid });
    await this.audit.record(ctx, { action: 'location.create', resourceType: 'location', resourceId: l._id });
    return serialize(l.toObject());
  }

  @Patch(':id')
  @Can('locations', 'configure', 'organization')
  async update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(locationBody.partial(), body);
    const before = await this.locations.findOneAndUpdate({ _id: oid(id), organizationId: ctx.orgOid }, { $set: b }).lean();
    if (!before) throw notFound('Location');
    await this.audit.record(ctx, { action: 'location.update', resourceType: 'location', resourceId: id, changes: diff(before, b) });
    return serialize(await this.locations.findById(id).lean());
  }
}

@ApiTags('shifts')
@Feature('shifts')
@Controller({ path: 'shifts', version: '1' })
export class ShiftsController {
  constructor(private readonly svc: ShiftsService) {}

  @Get()
  async list(@C() ctx: Ctx) {
    return { items: await this.svc.list(ctx) };
  }

  @Post()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.create(ctx, parse(shiftInput, body));
  }

  @Patch(':id')
  update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.update(ctx, id, parse(shiftInput.partial(), body));
  }

  @Delete(':id')
  async archive(@C() ctx: Ctx, @Param('id') id: string) {
    await this.svc.archive(ctx, id);
    return { archived: true };
  }

  @Post('assign')
  assign(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.assign(ctx, parse(z.object({ shiftId: objectId, employeeIds: z.array(objectId).min(1).max(500), from: dayString, to: dayString.optional().nullable(), setDefault: z.boolean().default(true) }), body));
  }

  @Get('calendar')
  calendar(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(range.extend({ employeeId: objectId.optional() }), q);
    return this.svc.calendar(ctx, b.from, b.to, b.employeeId);
  }

  @Get('requests')
  async requests(@C() ctx: Ctx, @Query() q: unknown) {
    return { items: await this.svc.listRequests(ctx, parse(z.object({ status: z.string().optional() }), q).status) };
  }

  @Post('requests')
  @Idempotent()
  request(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.requestChange(
      ctx,
      parse(z.object({ kind: z.enum(['change', 'swap']), date: dayString, toDate: dayString.optional(), requestedShiftId: objectId.optional(), swapWithEmployeeId: objectId.optional(), reason: z.string().max(500).optional() }), body),
    );
  }

  @Post('requests/check')
  @HttpCode(200)
  check(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.object({ kind: z.enum(['change', 'swap']), date: dayString, toDate: dayString.optional(), requestedShiftId: objectId.optional(), swapWithEmployeeId: objectId.optional() }), body);
    if (!ctx.employeeOid) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    return this.svc.ruleCheck(ctx.orgOid, ctx.employeeOid, b);
  }
}

@ApiTags('leave')
@Feature('leave')
@Controller({ path: 'leave', version: '1' })
export class LeaveController {
  constructor(private readonly svc: LeaveService) {}

  @Get('balances')
  async balances(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(z.object({ employeeId: objectId.optional(), year: z.coerce.number().int().min(2000).max(2100).optional() }), q);
    const id = b.employeeId ?? ctx.user.employeeId;
    if (!id) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    return { items: await this.svc.balancesFor(ctx, id, b.year) };
  }

  @Post('balances/adjust')
  @Idempotent()
  adjust(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.adjust(ctx, parse(z.object({ employeeId: objectId, leaveTypeId: objectId, year: z.number().int(), delta: z.number().min(-365).max(365).refine((n) => n !== 0 && Number.isInteger(n * 2), 'Use whole or half days'), reason: z.string().trim().min(3).max(300) }), body));
  }

  @Get('requests')
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(ctx, parse(listQuery.extend({ mine: z.coerce.boolean().optional(), employeeId: objectId.optional(), from: dayString.optional(), to: dayString.optional() }), q));
  }

  /** Applying needs an Idempotency-Key so a double tap never creates two requests. */
  @Post('requests')
  @Idempotent()
  apply(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(applyInput.extend({ employeeId: objectId.optional() }), body);
    const { employeeId, ...rest } = b;
    return this.svc.apply(ctx, rest, employeeId);
  }

  /** Live validation for the apply drawer: units and balance without creating anything. */
  @Post('requests/preview')
  @HttpCode(200)
  async preview(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.object({ leaveTypeId: objectId, startDate: dayString, endDate: dayString, partialDay: z.enum(['none', 'first_half', 'second_half']).default('none') }), body);
    if (!ctx.user.employeeId) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    const balances = await this.svc.balancesFor(ctx, ctx.user.employeeId, Number(b.startDate.slice(0, 4)));
    const bal = balances.find((x) => x.leaveTypeId === b.leaveTypeId);
    if (b.endDate < b.startDate) return { units: 0, available: bal?.available ?? 0, ok: false, message: 'The end date is before the start date.' };
    const { units, days } = await this.svc.countUnits(ctx.orgOid, { _id: ctx.employeeOid }, b.startDate, b.endDate, b.partialDay);
    const ok = !!bal && (bal.allowNegative || units <= bal.available) && units > 0;
    return { units, days, available: bal?.available ?? 0, after: bal ? bal.available - units : null, ok, message: !bal ? 'Not available to you.' : units === 0 ? 'These dates are holidays or weekly offs.' : ok ? null : `Only ${bal.available} day(s) available.` };
  }

  @Post('requests/:id/cancel')
  @HttpCode(200)
  cancel(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.cancel(ctx, id);
  }

  @Get('calendar')
  async calendar(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(range, q);
    return { items: await this.svc.calendar(ctx, b.from, b.to) };
  }

  @Get('types')
  async types(@C() ctx: Ctx) {
    return { items: await this.svc.listTypes(ctx) };
  }

  @Post('types')
  createType(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.upsertType(ctx, parse(leaveTypeInput, body));
  }

  @Put('types/:id')
  updateType(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.upsertType(ctx, parse(leaveTypeInput, body), id);
  }

  @Get('policies')
  async policies(@C() ctx: Ctx) {
    PermissionsService.require(ctx, 'leave', 'view');
    return { items: await this.svc.listPolicies(ctx) };
  }

  @Post('policies')
  createPolicy(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.upsertPolicy(ctx, parse(policyInput, body));
  }

  @Put('policies/:id')
  updatePolicy(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.upsertPolicy(ctx, parse(policyInput, body), id);
  }
}

const holidayBody = z.object({ date: dayString, name: z.string().trim().min(2).max(80), optional: z.boolean().default(false), locationIds: z.array(objectId).default([]) });
const eventBody = z.object({
  title: z.string().trim().min(2).max(120),
  description: z.string().max(2000).optional(),
  startAt: z.coerce.date(),
  endAt: z.coerce.date().optional(),
  eventType: z.enum(['company', 'training', 'celebration', 'deadline', 'other']).default('company'),
  visibility: z.enum(['organization', 'departments', 'locations']).default('organization'),
  departmentIds: z.array(objectId).default([]),
  locationIds: z.array(objectId).default([]),
});
const announcementBody = z.object({
  kind: z.enum(['announcement', 'kudos']).default('announcement'),
  title: z.string().trim().min(2).max(140),
  body: z.string().max(5000).optional(),
  toEmployeeId: objectId.optional(),
  pinned: z.boolean().default(false),
  expiresAt: z.coerce.date().optional(),
  audience: z.object({ departmentIds: z.array(objectId).default([]), locationIds: z.array(objectId).default([]) }).default({ departmentIds: [], locationIds: [] }),
});

@ApiTags('holidays')
@Controller({ path: '', version: '1' })
export class HolidaysController {
  constructor(
    private readonly audit: AuditService,
    private readonly orgSettings: OrgSettingsService,
    private readonly notifications: NotificationsService,
    private readonly scope: ScopeService,
    @InjectModel('Holiday') private readonly holidays: Model<any>,
    @InjectModel('HrEvent') private readonly events: Model<any>,
    @InjectModel('Announcement') private readonly announcements: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('ModerationAction') private readonly modActions: Model<any>,
  ) {}

  @Get('holidays')
  async listHolidays(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(z.object({ year: z.coerce.number().int().min(2000).max(2100).optional(), locationId: objectId.optional() }), q);
    const org = await this.orgSettings.get(ctx.orgOid);
    const year = b.year ?? Number(localParts(new Date(), org.timezone).day.slice(0, 4));
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid, date: { $gte: `${year}-01-01`, $lte: `${year}-12-31` } };
    if (b.locationId) filter.$or = [{ locationIds: { $size: 0 } }, { locationIds: oid(b.locationId) }];
    return { items: serialize(await this.holidays.find(filter).sort({ date: 1 }).lean()) };
  }

  @Post('holidays')
  @Can('holidays', 'manage', 'organization')
  async createHoliday(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(holidayBody, body);
    const h = await this.holidays.create({ ...b, locationIds: b.locationIds.map(oid), organizationId: ctx.orgOid });
    await this.audit.record(ctx, { action: 'holiday.create', resourceType: 'holiday', resourceId: h._id });
    return serialize(h.toObject());
  }

  @Delete('holidays/:id')
  @Can('holidays', 'manage', 'organization')
  async deleteHoliday(@C() ctx: Ctx, @Param('id') id: string) {
    const h = await this.holidays.findOneAndDelete({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!h) throw notFound('Holiday');
    await this.audit.record(ctx, { action: 'holiday.delete', resourceType: 'holiday', resourceId: id, changes: { name: { from: h.name, to: null }, date: { from: h.date, to: null } } });
    return { deleted: true };
  }

  @Get('events')
  async listEvents(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(z.object({ from: z.coerce.date().optional(), to: z.coerce.date().optional() }), q);
    const me = ctx.employeeOid ? await this.employees.findById(ctx.employeeOid, { departmentId: 1, locationId: 1 }).lean<any>() : null;
    const filter: Record<string, unknown> = {
      organizationId: ctx.orgOid,
      status: { $ne: 'cancelled' },
      startAt: { $gte: b.from ?? new Date(Date.now() - 30 * 86400_000), $lte: b.to ?? new Date(Date.now() + 180 * 86400_000) },
    };
    if (!ctx.authz.can('holidays', 'manage')) {
      filter.$or = [{ visibility: 'organization' }, { visibility: 'departments', departmentIds: me?.departmentId }, { visibility: 'locations', locationIds: me?.locationId }];
    }
    return { items: serialize(await this.events.find(filter).sort({ startAt: 1 }).limit(200).lean()) };
  }

  @Post('events')
  @Can('holidays', 'manage', 'organization')
  async createEvent(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(eventBody, body);
    if (b.endAt && b.endAt < b.startAt) throw badRequest('DATES_INVALID', 'The end is before the start.', 'endAt');
    const ev = await this.events.create({ ...b, departmentIds: b.departmentIds.map(oid), locationIds: b.locationIds.map(oid), organizationId: ctx.orgOid, createdBy: ctx.userOid });
    await this.audit.record(ctx, { action: 'event.create', resourceType: 'hr_event', resourceId: ev._id });
    return serialize(ev.toObject());
  }

  @Patch('events/:id')
  @Can('holidays', 'manage', 'organization')
  async updateEvent(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(eventBody.partial().extend({ status: z.enum(['scheduled', 'cancelled', 'done']).optional() }), body);
    const set: Record<string, unknown> = { ...b };
    if (b.departmentIds) set.departmentIds = b.departmentIds.map(oid);
    if (b.locationIds) set.locationIds = b.locationIds.map(oid);
    const r = await this.events.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: set });
    if (!r.matchedCount) throw notFound('Event');
    await this.audit.record(ctx, { action: 'event.update', resourceType: 'hr_event', resourceId: id });
    return serialize(await this.events.findById(id).lean());
  }

  @Get('announcements')
  async listAnnouncements(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery.extend({ kind: z.enum(['announcement', 'kudos']).optional() }), q);
    const me = ctx.employeeOid ? await this.employees.findById(ctx.employeeOid, { departmentId: 1, locationId: 1 }).lean<any>() : null;
    const filter: Record<string, unknown> = {
      organizationId: ctx.orgOid,
      publishedAt: { $ne: null },
      $and: [
        { $or: [{ expiresAt: null }, { expiresAt: { $gt: new Date() } }] },
        { $or: [{ 'audience.departmentIds.0': { $exists: false } }, { 'audience.departmentIds': me?.departmentId }] },
        { $or: [{ 'audience.locationIds.0': { $exists: false } }, { 'audience.locationIds': me?.locationId }] },
      ],
    };
    if (b.kind) filter.kind = b.kind;
    const [items, total] = await Promise.all([
      this.announcements.find(filter).sort({ pinned: -1, publishedAt: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean(),
      this.announcements.countDocuments(filter),
    ]);
    return { items: serialize(items), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }

  /** Announcements need announcements:create; anyone may give kudos to a colleague. */
  @Post('announcements')
  async publish(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(announcementBody, body);
    if (b.kind === 'announcement') PermissionsService.require(ctx, 'announcements', 'create');
    const restricted = await this.modActions.exists({ organizationId: ctx.orgOid, targetUserId: ctx.userOid, action: 'restrict', expiresAt: { $gt: new Date() } });
    if (restricted) throw badRequest('POSTING_RESTRICTED', 'A moderator has paused your posting for now.');
    if (b.kind === 'kudos' && !b.toEmployeeId) throw badRequest('RECIPIENT_REQUIRED', 'Choose who the kudos are for.', 'toEmployeeId');
    if (b.kind === 'kudos' && b.toEmployeeId === ctx.user.employeeId) throw badRequest('SELF_KUDOS', "Kudos are for someone else.", 'toEmployeeId');
    const a = await this.announcements.create({
      ...b,
      pinned: b.kind === 'announcement' ? b.pinned : false,
      toEmployeeId: b.toEmployeeId ? oid(b.toEmployeeId) : undefined,
      audience: { departmentIds: b.audience.departmentIds.map(oid), locationIds: b.audience.locationIds.map(oid) },
      organizationId: ctx.orgOid,
      createdBy: ctx.userOid,
      publishedAt: new Date(),
    });
    await this.audit.record(ctx, { action: `${b.kind}.publish`, resourceType: 'announcement', resourceId: a._id });
    if (b.kind === 'kudos' && b.toEmployeeId) {
      const u = await this.users.findOne({ organizationId: ctx.orgOid, employeeId: oid(b.toEmployeeId) }, { _id: 1 }).lean<any>();
      if (u) await this.notifications.notify(ctx.orgOid, [u._id], { event: 'kudos', title: `${ctx.user.name} sent you kudos`, body: b.title, link: '/announcements' });
    } else if (b.pinned) {
      const users = await this.users.find({ organizationId: ctx.orgOid, status: 'active' }, { _id: 1 }).limit(2000).lean<any[]>();
      await this.notifications.notify(ctx.orgOid, users.map((u) => u._id), { event: 'announcement', title: b.title, body: b.body?.slice(0, 200), link: '/announcements' });
    }
    return serialize(a.toObject());
  }

  @Delete('announcements/:id')
  async remove(@C() ctx: Ctx, @Param('id') id: string) {
    const a = await this.announcements.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!a) throw notFound('Announcement');
    if (String(a.createdBy) !== ctx.user.userId) PermissionsService.require(ctx, 'announcements', 'manage');
    await this.announcements.updateOne({ _id: a._id }, { $set: { publishedAt: null } });
    await this.audit.record(ctx, { action: 'announcement.unpublish', resourceType: 'announcement', resourceId: id });
    return { removed: true };
  }

  @Post('announcements/:id/react')
  @HttpCode(200)
  async react(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const { emoji } = parse(z.object({ emoji: z.enum(['clap', 'heart', 'party', 'thumbs_up']) }), body);
    const r = await this.announcements.updateOne({ _id: oid(id), organizationId: ctx.orgOid, publishedAt: { $ne: null } }, { $inc: { [`reactions.${emoji}`]: 1 } });
    if (!r.matchedCount) throw notFound('Announcement');
    return { reacted: true };
  }

  /** Birthdays and work anniversaries this week (celebration motion plays once on the client). */
  @Get('celebrations')
  async celebrations(@C() ctx: Ctx) {
    const org = await this.orgSettings.get(ctx.orgOid);
    const today = localParts(new Date(), org.timezone).day;
    const md = (d: Date) => d.toISOString().slice(5, 10);
    const window = Array.from({ length: 7 }, (_, i) => md(new Date(Date.parse(`${today}T00:00:00Z`) + i * 86400_000)));
    const emps = await this.employees.find({ organizationId: ctx.orgOid, status: { $in: ['active', 'probation', 'notice'] } }, { firstName: 1, lastName: 1, joiningDate: 1, 'sensitive.dateOfBirth': 1, photoFileId: 1 }).lean<any[]>();
    const items = [];
    for (const e of emps) {
      const name = `${e.firstName} ${e.lastName ?? ''}`.trim();
      if (e.joiningDate && window.includes(md(new Date(e.joiningDate))) && new Date(e.joiningDate).getUTCFullYear() < Number(today.slice(0, 4))) {
        items.push({ type: 'work_anniversary', employeeId: String(e._id), name, years: Number(today.slice(0, 4)) - new Date(e.joiningDate).getUTCFullYear(), on: md(new Date(e.joiningDate)), photoFileId: e.photoFileId });
      }
      // Birthdays show day and month only, never the year.
      if (e.sensitive?.dateOfBirth && window.includes(md(new Date(e.sensitive.dateOfBirth)))) items.push({ type: 'birthday', employeeId: String(e._id), name, on: md(new Date(e.sensitive.dateOfBirth)), photoFileId: e.photoFileId });
    }
    return { items: items.sort((a, b) => a.on.localeCompare(b.on)) };
  }
}
