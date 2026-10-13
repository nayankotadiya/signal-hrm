import { Injectable, OnModuleInit } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService, diff } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, conflict, dayString, notFound, objectId, oid } from '../../common/http/validation';
import { addDays, daysBetween, weekdayOf } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { ApprovalEngine } from '../approvals/approval.engine';
import { NotificationsService } from '../notifications/notifications.service';

const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:mm');
export const shiftInput = z.object({
  name: z.string().trim().min(1).max(60),
  startTime: hhmm,
  endTime: hhmm,
  breakMinutes: z.number().int().min(0).max(240).default(60),
  workingDays: z.array(z.number().int().min(0).max(6)).min(1).max(7).default([1, 2, 3, 4, 5, 6]),
  graceMinutes: z.number().int().min(0).max(120).default(10),
  overtimeAfterMinutes: z.number().int().min(0).max(1440).default(0),
  locationIds: z.array(objectId).default([]),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/).optional(),
  effectiveFrom: z.coerce.date().optional(),
  effectiveTo: z.coerce.date().optional().nullable(),
});

export const toMinutes = (t: string): number => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));

/** Shift length in minutes; an end before the start means the shift runs past midnight. */
export function shiftLength(s: { startTime: string; endTime: string }): number {
  const a = toMinutes(s.startTime);
  const b = toMinutes(s.endTime);
  return b > a ? b - a : 1440 - a + b;
}
export const isOvernight = (s: { startTime: string; endTime: string }): boolean => toMinutes(s.endTime) <= toMinutes(s.startTime);

@Injectable()
export class ShiftsService implements OnModuleInit {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly approvals: ApprovalEngine,
    private readonly notifications: NotificationsService,
    @InjectModel('Shift') private readonly shifts: Model<any>,
    @InjectModel('ShiftAssignment') private readonly assignments: Model<any>,
    @InjectModel('ShiftChangeRequest') private readonly requests: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('LeaveRequest') private readonly leaves: Model<any>,
  ) {}

  onModuleInit(): void {
    this.approvals.register('shift_change', {
      onApproved: async (a) => {
        const r = await this.requests.findById(a.requestId).lean<any>();
        if (!r || r.status === 'approved') return;
        const days = daysBetween(r.date, r.toDate ?? r.date);
        if (r.kind === 'swap' && r.swapWithEmployeeId) {
          for (const day of days) {
            const mine = await this.effectiveShiftId(r.organizationId, r.employeeId, day);
            const theirs = await this.effectiveShiftId(r.organizationId, r.swapWithEmployeeId, day);
            await this.assignOneDay(r.organizationId, r.employeeId, theirs, day, a.requestedBy);
            await this.assignOneDay(r.organizationId, r.swapWithEmployeeId, mine, day, a.requestedBy);
          }
        } else {
          for (const day of days) await this.assignOneDay(r.organizationId, r.employeeId, r.requestedShiftId, day, a.requestedBy);
        }
        await this.requests.updateOne({ _id: r._id }, { $set: { status: 'approved' } });
      },
      onRejected: async (a) => void (await this.requests.updateOne({ _id: a.requestId }, { $set: { status: 'rejected' } })),
      onCancelled: async (a) => void (await this.requests.updateOne({ _id: a.requestId }, { $set: { status: 'cancelled' } })),
    });
  }

  // ------------------------------------------------------------------ resolution

  async effectiveShiftId(orgId: Types.ObjectId, employeeId: Types.ObjectId, day: string): Promise<Types.ObjectId | null> {
    const a = await this.assignments
      .findOne({ organizationId: orgId, employeeId, from: { $lte: day }, $or: [{ to: null }, { to: { $exists: false } }, { to: { $gte: day } }] })
      .sort({ from: -1, createdAt: -1 })
      .lean<any>();
    if (a) return a.shiftId;
    const e = await this.employees.findById(employeeId, { shiftId: 1 }).lean<any>();
    return e?.shiftId ?? null;
  }

  /** The shift that applies to an employee on a day (dated assignments win over the default shift). */
  async effectiveShift(orgId: Types.ObjectId, employeeId: Types.ObjectId, day: string): Promise<any | null> {
    const id = await this.effectiveShiftId(orgId, employeeId, day);
    return id ? this.shifts.findOne({ _id: id, organizationId: orgId }).lean() : null;
  }

  private async assignOneDay(orgId: Types.ObjectId, employeeId: Types.ObjectId, shiftId: Types.ObjectId | null, day: string, by: Types.ObjectId): Promise<void> {
    if (!shiftId) return;
    await this.assignments.create({ organizationId: orgId, employeeId, shiftId, from: day, to: day, assignedBy: by });
  }

  // ------------------------------------------------------------------ shifts CRUD

  async list(ctx: Ctx): Promise<any[]> {
    PermissionsService.require(ctx, 'shifts', 'view');
    const rows = await this.shifts.find({ organizationId: ctx.orgOid, status: 'active' }).sort({ startTime: 1 }).lean<any[]>();
    return serialize(rows).map((s: any) => ({ ...s, lengthMinutes: shiftLength(s), overnight: isOvernight(s) }));
  }

  async create(ctx: Ctx, b: z.infer<typeof shiftInput>): Promise<any> {
    PermissionsService.require(ctx, 'shifts', 'create', 'organization');
    if (b.startTime === b.endTime) throw badRequest('SHIFT_ZERO_LENGTH', 'Start and end times must differ.', 'endTime');
    const doc = await this.shifts.create({ ...b, locationIds: b.locationIds.map(oid), organizationId: ctx.orgOid });
    await this.audit.record(ctx, { action: 'shift.create', resourceType: 'shift', resourceId: doc._id });
    return serialize(doc.toObject());
  }

  async update(ctx: Ctx, id: string, b: Partial<z.infer<typeof shiftInput>>): Promise<any> {
    PermissionsService.require(ctx, 'shifts', 'edit', 'organization');
    const set: Record<string, unknown> = { ...b };
    if (b.locationIds) set.locationIds = b.locationIds.map(oid);
    const before = await this.shifts.findOneAndUpdate({ _id: oid(id), organizationId: ctx.orgOid }, { $set: set }).lean<any>();
    if (!before) throw notFound('Shift');
    await this.audit.record(ctx, { action: 'shift.update', resourceType: 'shift', resourceId: id, changes: diff(before, set) });
    return serialize(await this.shifts.findById(id).lean());
  }

  async archive(ctx: Ctx, id: string): Promise<void> {
    PermissionsService.require(ctx, 'shifts', 'edit', 'organization');
    const inUse = await this.employees.countDocuments({ organizationId: ctx.orgOid, shiftId: oid(id), status: { $nin: ['exited', 'archived'] } });
    if (inUse) throw conflict('SHIFT_IN_USE', `${inUse} employee(s) still use this shift as their default.`);
    const r = await this.shifts.updateOne({ _id: oid(id), organizationId: ctx.orgOid }, { $set: { status: 'archived' } });
    if (!r.matchedCount) throw notFound('Shift');
    await this.audit.record(ctx, { action: 'shift.archive', resourceType: 'shift', resourceId: id });
  }

  /** Assigns a shift to employees from a date (optionally until a date); default shift when open-ended. */
  async assign(ctx: Ctx, b: { shiftId: string; employeeIds: string[]; from: string; to?: string | null; setDefault?: boolean }): Promise<{ assigned: number }> {
    PermissionsService.require(ctx, 'shifts', 'assign');
    const shift = await this.shifts.findOne({ _id: oid(b.shiftId), organizationId: ctx.orgOid, status: 'active' }).lean();
    if (!shift) throw notFound('Shift');
    if (b.to && b.to < b.from) throw badRequest('DATES_INVALID', 'The end date is before the start.', 'to');
    let n = 0;
    for (const id of b.employeeIds) {
      await this.scope.requireCovers(ctx, 'shifts', 'assign', id);
      await this.assignments.create({ organizationId: ctx.orgOid, employeeId: oid(id), shiftId: oid(b.shiftId), from: b.from, to: b.to ?? undefined, assignedBy: ctx.userOid });
      if (b.setDefault && !b.to) await this.employees.updateOne({ _id: oid(id) }, { $set: { shiftId: oid(b.shiftId) } });
      n++;
    }
    await this.audit.record(ctx, { action: 'shift.assign', resourceType: 'shift', resourceId: b.shiftId, changes: { employees: { from: null, to: n }, from: { from: null, to: b.from } } });
    return { assigned: n };
  }

  /** Week or month calendar: one block per employee per day, overnight shifts flagged. */
  async calendar(ctx: Ctx, from: string, to: string, employeeId?: string): Promise<any> {
    const filter = await this.scope.filter(ctx, 'shifts', 'view', '_id');
    if (employeeId) filter._id = oid(employeeId);
    filter.status = { $nin: ['exited', 'archived'] };
    const emps = await this.employees.find(filter, { firstName: 1, lastName: 1, shiftId: 1 }).limit(300).lean<any[]>();
    const days = daysBetween(from, to).slice(0, 62);
    const allShifts = new Map((await this.shifts.find({ organizationId: ctx.orgOid }).lean<any[]>()).map((s) => [String(s._id), s]));
    const ids = emps.map((e) => e._id);
    const asg = await this.assignments.find({ organizationId: ctx.orgOid, employeeId: { $in: ids }, from: { $lte: to }, $or: [{ to: null }, { to: { $exists: false } }, { to: { $gte: from } }] }).sort({ from: 1, createdAt: 1 }).lean<any[]>();
    const rows = emps.map((e) => ({
      employeeId: String(e._id),
      name: `${e.firstName} ${e.lastName ?? ''}`.trim(),
      days: days.map((day) => {
        const mine = asg.filter((a) => String(a.employeeId) === String(e._id) && a.from <= day && (!a.to || a.to >= day));
        const sid = mine.length ? String(mine[mine.length - 1].shiftId) : e.shiftId ? String(e.shiftId) : null;
        const s = sid ? allShifts.get(sid) : null;
        const working = s ? s.workingDays.includes(weekdayOf(day)) : false;
        return { day, shiftId: s && working ? sid : null, name: s && working ? s.name : null, start: s?.startTime, end: s?.endTime, overnight: s ? isOvernight(s) : false, color: s?.color ?? null };
      }),
    }));
    return { from, to, days, rows };
  }

  // ------------------------------------------------------------------ change and swap requests

  /** Automatic rule checks the manager sees before deciding. */
  async ruleCheck(orgId: Types.ObjectId, employeeId: Types.ObjectId, b: { kind: string; date: string; toDate?: string; requestedShiftId?: string; swapWithEmployeeId?: string }): Promise<{ ok: boolean; checks: { rule: string; ok: boolean; message: string }[] }> {
    const checks: { rule: string; ok: boolean; message: string }[] = [];
    const days = daysBetween(b.date, b.toDate ?? b.date);
    const onLeave = await this.leaves.exists({ organizationId: orgId, employeeId, status: { $in: ['approved', 'pending'] }, startDate: { $lte: days[days.length - 1] }, endDate: { $gte: days[0] } });
    checks.push({ rule: 'no_leave', ok: !onLeave, message: onLeave ? 'You have leave on these dates.' : 'No leave on these dates.' });
    if (b.kind === 'swap' && b.swapWithEmployeeId) {
      const other = oid(b.swapWithEmployeeId);
      const otherLeave = await this.leaves.exists({ organizationId: orgId, employeeId: other, status: { $in: ['approved', 'pending'] }, startDate: { $lte: days[days.length - 1] }, endDate: { $gte: days[0] } });
      checks.push({ rule: 'partner_available', ok: !otherLeave, message: otherLeave ? 'Your swap partner has leave on these dates.' : 'Swap partner is available.' });
      const mine = await this.effectiveShiftId(orgId, employeeId, b.date);
      const theirs = await this.effectiveShiftId(orgId, other, b.date);
      checks.push({ rule: 'different_shifts', ok: String(mine) !== String(theirs), message: String(mine) === String(theirs) ? 'You both already work the same shift.' : 'Shifts differ, so the swap changes something.' });
    }
    if (b.requestedShiftId || b.kind === 'swap') {
      // At least 8 hours rest between the previous day's shift end and the new start.
      const prev = await this.effectiveShift(orgId, employeeId, addDays(b.date, -1));
      const next = b.requestedShiftId ? await this.shifts.findById(b.requestedShiftId).lean<any>() : null;
      if (prev && next) {
        const prevEnd = isOvernight(prev) ? toMinutes(prev.endTime) : toMinutes(prev.endTime) - 1440;
        const rest = toMinutes(next.startTime) - prevEnd;
        checks.push({ rule: 'rest_hours', ok: rest >= 480, message: rest >= 480 ? 'At least 8 hours of rest.' : `Only ${Math.max(0, Math.round(rest / 60))} hours of rest after the previous shift.` });
      }
    }
    return { ok: checks.every((c) => c.ok), checks };
  }

  async requestChange(ctx: Ctx, b: { kind: 'change' | 'swap'; date: string; toDate?: string; requestedShiftId?: string; swapWithEmployeeId?: string; reason?: string }): Promise<any> {
    if (!ctx.employeeOid) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    PermissionsService.require(ctx, 'shifts', 'create');
    if (b.kind === 'change' && !b.requestedShiftId) throw badRequest('SHIFT_REQUIRED', 'Choose the shift you want.', 'requestedShiftId');
    if (b.kind === 'swap' && !b.swapWithEmployeeId) throw badRequest('PARTNER_REQUIRED', 'Choose who to swap with.', 'swapWithEmployeeId');
    if (b.toDate && b.toDate < b.date) throw badRequest('DATES_INVALID', 'The end date is before the start.', 'toDate');
    const ruleCheck = await this.ruleCheck(ctx.orgOid, ctx.employeeOid, b);
    const r = await this.requests.create({
      organizationId: ctx.orgOid,
      employeeId: ctx.employeeOid,
      kind: b.kind,
      date: b.date,
      toDate: b.toDate,
      requestedShiftId: b.requestedShiftId ? oid(b.requestedShiftId) : undefined,
      swapWithEmployeeId: b.swapWithEmployeeId ? oid(b.swapWithEmployeeId) : undefined,
      reason: b.reason,
      ruleCheck,
    });
    const a = await this.approvals.start(ctx, {
      requestType: 'shift_change',
      requestId: r._id,
      subjectEmployeeId: ctx.employeeOid,
      title: `Shift ${b.kind === 'swap' ? 'swap' : 'change'}: ${ctx.user.name}`,
      summary: `${b.date}${b.toDate ? ` to ${b.toDate}` : ''}${ruleCheck.ok ? '' : ' · rule checks need attention'}`,
      link: '/time/shifts',
    });
    await this.requests.updateOne({ _id: r._id }, { $set: { approvalId: a._id } });
    return { ...serialize(r.toObject()), approvalId: String(a._id) };
  }

  async listRequests(ctx: Ctx, status?: string): Promise<any[]> {
    const filter = await this.scope.filter(ctx, 'shifts', 'view');
    if (status) filter.status = status;
    return serialize(await this.requests.find(filter).sort({ createdAt: -1 }).limit(200).lean());
  }

  static readonly dayString = dayString;
}
