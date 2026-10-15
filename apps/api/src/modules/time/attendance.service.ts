import { HttpStatus, Inject, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { ApiError } from '../../common/errors/api-error';
import { badRequest, conflict, dayString, forbidden, notFound, oid, Paged } from '../../common/http/validation';
import { MailService } from '../../common/mail/mail.service';
import { addDays, daysBetween, localParts, OrgSettingsService, weekdayOf, zonedTimeToUtc } from '../../common/org/org-settings.service';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { InjectModel, serialize } from '../../database/model';
import { ApprovalEngine } from '../approvals/approval.engine';
import { FilesService } from '../files/files.service';
import { buildBulletproofEmailHtml, NotificationsService } from '../notifications/notifications.service';
import { RealtimeService } from '../notifications/realtime.service';
import { JobsService } from '../system/jobs.service';
import { checkGeofence, haversineMeters, speedKmh } from './geo';
import { shiftLength, ShiftsService, toMinutes } from './shifts.service';

export const punchInput = z.object({
  latitude: z.number().min(-90).max(90).optional(),
  longitude: z.number().min(-180).max(180).optional(),
  accuracyMeters: z.number().min(0).max(100_000).optional(),
  /** What the browser reported when asked for location. */
  locationStatus: z.enum(['granted', 'denied', 'unavailable', 'timeout', 'not_requested']).default('not_requested'),
  selfieFileId: z.string().optional(),
  /** Browser signals that suggest a simulated position (only where the platform exposes them). */
  mockSignals: z.array(z.enum(['mock_provider', 'zero_accuracy', 'developer_override', 'repeated_exact_fix'])).max(5).optional(),
  /** Offline queue: when the device recorded the tap. Used only to open a correction, never as the punch time. */
  queuedOffline: z.boolean().optional(),
  clientRecordedAt: z.coerce.date().optional(),
  remote: z.boolean().optional(),
  /** GPS failure exception: the employee explains why location couldn't be verified. */
  exceptionReason: z.string().trim().min(5).max(500).optional(),
});
export type PunchInput = z.infer<typeof punchInput>;
type Action = 'checkIn' | 'checkOut';

export const correctionInput = z.object({
  workDate: dayString,
  kind: z.enum(['missed_check_in', 'missed_check_out', 'wrong_time', 'gps_failure', 'other']),
  requestedCheckIn: z.coerce.date().optional(),
  requestedCheckOut: z.coerce.date().optional(),
  reason: z.string().trim().min(5).max(500),
});

const geoErr = (code: string, message: string, meta: Record<string, unknown>) => new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, code, message, undefined, meta);

@Injectable()
export class AttendanceService implements OnModuleInit {
  private readonly logger = new Logger('Attendance');

  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly orgSettings: OrgSettingsService,
    private readonly shifts: ShiftsService,
    private readonly files: FilesService,
    private readonly approvals: ApprovalEngine,
    private readonly notifications: NotificationsService,
    private readonly mail: MailService,
    private readonly realtime: RealtimeService,
    private readonly jobs: JobsService,
    @InjectModel('Attendance') private readonly attendance: Model<any>,
    @InjectModel('AttendanceCorrection') private readonly corrections: Model<any>,
    @InjectModel('AttendanceEvidence') private readonly evidence: Model<any>,
    @InjectModel('AttendanceFlag') private readonly flags: Model<any>,
    @InjectModel('GpsAttempt') private readonly gpsAttempts: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Location') private readonly locations: Model<any>,
    @InjectModel('Device') private readonly devices: Model<any>,
    @InjectModel('Holiday') private readonly holidays: Model<any>,
    @InjectModel('LeaveRequest') private readonly leaves: Model<any>,
    @InjectModel('Shift') private readonly shiftModel: Model<any>,
  ) {}

  onModuleInit(): void {
    this.approvals.register('attendance_correction', {
      onApproved: async (a, actor) => this.applyCorrection(a.requestId, actor?.userOid),
      onRejected: async (a) => {
        const c = await this.corrections.findOneAndUpdate({ _id: a.requestId, status: 'pending' }, { $set: { status: 'rejected', decidedAt: new Date() } }).lean<any>();
        if (c?.attendanceId) await this.attendance.updateOne({ _id: c.attendanceId, status: 'pending_correction' }, { $set: { status: 'incomplete' } });
      },
      onCancelled: async (a) => void (await this.corrections.updateOne({ _id: a.requestId }, { $set: { status: 'cancelled' } })),
    });
    // Selfies and other evidence: the employee themself, or holders of attendance_evidence:view covering them.
    this.files.registerAuthorizer('attendance_evidence', async (ctx, f) => String(f.ownerEmployeeId) === ctx.user.employeeId || this.scope.covers(ctx, 'attendance_evidence', 'view', f.ownerEmployeeId));
  }

  // ------------------------------------------------------------------ today

  /** Today's state, requirements and context for the check-in screen. */
  async today(ctx: Ctx): Promise<any> {
    const emp = await this.requireEmployee(ctx);
    const org = await this.orgSettings.get(ctx.orgOid);
    const now = new Date();
    const { day } = localParts(now, org.timezone);
    const [record, shift, location, holiday, leave] = await Promise.all([
      this.openOrToday(ctx.orgOid, emp._id, day, org),
      this.shifts.effectiveShift(ctx.orgOid, emp._id, day),
      emp.locationId ? this.locations.findById(emp.locationId).lean<any>() : null,
      this.holidays.findOne({ organizationId: ctx.orgOid, date: day, $or: [{ locationIds: { $size: 0 } }, { locationIds: emp.locationId }] }).lean<any>(),
      this.leaves.findOne({ organizationId: ctx.orgOid, employeeId: emp._id, status: 'approved', startDate: { $lte: day }, endDate: { $gte: day } }).lean<any>(),
    ]);
    const settings = org.settings?.attendance ?? {};
    const failures = await this.gpsAttempts.countDocuments({ organizationId: ctx.orgOid, employeeId: emp._id, workDate: day });
    return {
      serverTime: now.toISOString(),
      workDate: day,
      timezone: org.timezone,
      record: serialize(record),
      state: (() => {
        if (!record?.checkIn) return 'not_checked_in';
        const sessions: any[] = record?.sessions && record.sessions.length > 0
          ? record.sessions
          : (record?.checkIn ? [{ checkIn: record.checkIn, checkOut: record.checkOut }] : []);
        const last = sessions.length > 0 ? sessions[sessions.length - 1] : null;
        const isOpen = last && !last.checkOut;
        return isOpen ? 'checked_in' : 'checked_out';
      })(),
      dayCount: record?.dayCount ?? (record?.checkOut ? (record?.status === 'half_day' ? 0.5 : 1.0) : (record?.checkIn ? 0.5 : 0.0)),
      shift: shift ? { ...serialize(shift), lengthMinutes: shiftLength(shift) } : null,
      location: location ? { id: String(location._id), name: location.name, latitude: location.latitude, longitude: location.longitude, radiusMeters: location.radiusMeters } : null,
      requirements: {
        checkIn: { requireLocation: settings.checkIn?.requireLocation ?? true, requireSelfie: settings.checkIn?.requireSelfie ?? true },
        checkOut: { requireLocation: settings.checkOut?.requireLocation ?? true, requireSelfie: settings.checkOut?.requireSelfie ?? true },
        maxAccuracyMeters: settings.maxAccuracyMeters ?? 100,
        allowRemote: settings.allowRemote ?? false,
        gpsRetryLimit: settings.gpsRetryLimit ?? 2,
      },
      gpsFailuresToday: failures,
      exceptionAvailable: failures >= (settings.gpsRetryLimit ?? 2),
      holiday: holiday ? { name: holiday.name } : null,
      onLeave: leave ? { leaveRequestId: String(leave._id), partialDay: leave.partialDay } : null,
    };
  }

  private async requireEmployee(ctx: Ctx): Promise<any> {
    if (!ctx.employeeOid) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record. Ask HR to link it.');
    const emp = await this.employees.findOne({ _id: ctx.employeeOid, organizationId: ctx.orgOid }).lean<any>();
    if (!emp || ['exited', 'archived'].includes(emp.status)) throw forbidden('EMPLOYEE_INACTIVE', 'Attendance is not available for this employee record.');
    return emp;
  }

  /** The record to check out of: an open one from today or (overnight shifts) the previous day. */
  private async openOrToday(orgId: Types.ObjectId, employeeId: Types.ObjectId, day: string, org: any): Promise<any | null> {
    const today = await this.attendance.findOne({ organizationId: orgId, employeeId, workDate: day }).lean<any>();
    if (today) return today;
    const maxHours = org.settings?.attendance?.autoCheckoutHours ?? 16;
    const prev = await this.attendance.findOne({ organizationId: orgId, employeeId, workDate: addDays(day, -1), 'checkIn.at': { $exists: true }, 'checkOut.at': { $exists: false } }).lean<any>();
    if (prev && Date.now() - new Date(prev.checkIn.at).getTime() < maxHours * 3600_000) return prev;
    return null;
  }

  // ------------------------------------------------------------------ punch

  /**
   * Check-in / check-out. Rules (Phase 4 requirements):
   * - timestamp is the server's clock only;
   * - location and selfie requirements are configured separately for check-in and check-out;
   * - accuracy worse than the organization limit is refused (retry), then the exception flow opens;
   * - geofence distance is computed here with Haversine against the employee's assigned location;
   * - suspicious patterns are flagged for review, never auto-punished;
   * - the controller requires an Idempotency-Key, so retries never create duplicates;
   * - distance, accuracy and the verification result are stored on the record.
   */
  async punch(ctx: Ctx, action: Action, input: PunchInput): Promise<any> {
    PermissionsService.require(ctx, 'attendance', 'create');
    const emp = await this.requireEmployee(ctx);
    const org = await this.orgSettings.get(ctx.orgOid);
    const settings = org.settings?.attendance ?? {};
    const req = (action === 'checkIn' ? settings.checkIn : settings.checkOut) ?? {};
    const requireLocation = req.requireLocation ?? true;
    const requireSelfie = req.requireSelfie ?? false;
    const maxAccuracy = settings.maxAccuracyMeters ?? 100;
    const retryLimit = settings.gpsRetryLimit ?? 2;

    const now = new Date(); // server time, always
    const { day } = localParts(now, org.timezone);
    const existing = await this.openOrToday(ctx.orgOid, emp._id, day, org);
    const existingSessions: any[] = existing?.sessions && existing.sessions.length > 0
      ? existing.sessions
      : (existing?.checkIn ? [{ checkIn: existing.checkIn, checkOut: existing.checkOut, durationMinutes: existing.workedMinutes }] : []);
    const lastExistingSession = existingSessions.length > 0 ? existingSessions[existingSessions.length - 1] : null;
    const isSessionOpen = !!(lastExistingSession && !lastExistingSession.checkOut);

    if (action === 'checkIn' && isSessionOpen) {
      throw conflict('ALREADY_CHECKED_IN', `You are already checked in at ${this.fmt(lastExistingSession.checkIn.at, org)}.`);
    }
    if (action === 'checkOut' && !existing?.checkIn) {
      throw conflict('NOT_CHECKED_IN', 'Check in first.');
    }
    if (action === 'checkOut' && !isSessionOpen) {
      throw conflict('ALREADY_CHECKED_OUT', `You are already checked out. Check in first to resume.`);
    }
    const workDate: string = existing?.workDate ?? day;
    const actionKey = action === 'checkIn' ? 'check_in' : 'check_out';

    // ---- location
    const punch: Record<string, unknown> = { at: now, method: 'geofence', deviceId: ctx.deviceId, ip: ctx.ip, queuedOffline: !!input.queuedOffline, clientRecordedAt: input.clientRecordedAt };
    const pendingFlags: { type: string; severity: string; details: Record<string, unknown> }[] = [];
    let exception = false;
    const location = emp.locationId ? await this.locations.findOne({ _id: emp.locationId, organizationId: ctx.orgOid, active: true }).lean<any>() : null;
    const hasFix = input.latitude != null && input.longitude != null && input.accuracyMeters != null;

    if (hasFix) {
      Object.assign(punch, { latitude: input.latitude, longitude: input.longitude, accuracyMeters: Math.round(input.accuracyMeters!) });
    }

    let isOutsideCompany = false;
    if (!requireLocation) {
      punch.verification = hasFix ? 'not_required' : 'no_location';
      punch.method = 'remote';
      if (hasFix && location) punch.distanceMeters = Math.round(haversineMeters(input.latitude!, input.longitude!, location.latitude, location.longitude));
    } else if (input.exceptionReason) {
      // GPS failure exception: only after the allowed retries (or when location permission is denied).
      const failures = await this.gpsAttempts.countDocuments({ organizationId: ctx.orgOid, employeeId: emp._id, workDate, action: actionKey });
      if (failures < retryLimit && input.locationStatus !== 'denied') {
        throw geoErr('EXCEPTION_NOT_YET', `Try your location again first (${retryLimit - failures} more ${retryLimit - failures === 1 ? 'try' : 'tries'}).`, { retriesLeft: retryLimit - failures });
      }
      exception = true;
      punch.method = 'exception';
      punch.verification = 'exception_pending';
      if (hasFix && location) punch.distanceMeters = Math.round(haversineMeters(input.latitude!, input.longitude!, location.latitude, location.longitude));
    } else if (!hasFix) {
      const reason = input.locationStatus === 'denied' ? 'permission_denied' : input.locationStatus === 'timeout' ? 'timeout' : 'unavailable';
      const failures = await this.recordGpsFailure(ctx, emp._id, workDate, actionKey, reason);
      throw geoErr('LOCATION_REQUIRED', input.locationStatus === 'denied' ? 'Location permission is off. Turn it on for this site, or use the exception if you can’t.' : 'We couldn’t get your location. Try again outdoors or near a window.', {
        retriesLeft: Math.max(0, retryLimit - failures),
        exceptionAvailable: failures >= retryLimit || input.locationStatus === 'denied',
      });
    } else if (!location) {
      punch.method = 'remote';
      punch.verification = 'not_required';
    } else {
      const verdict = checkGeofence({ latitude: input.latitude!, longitude: input.longitude!, accuracyMeters: input.accuracyMeters! }, location, maxAccuracy);
      punch.locationId = location._id;
      if (verdict.ok) {
        Object.assign(punch, { verification: 'within_radius', distanceMeters: verdict.distanceMeters });
      } else if (verdict.verification === 'accuracy_too_low') {
        // Not accepted: the fix is too vague to prove anything. Retry, then exception.
        const failures = await this.recordGpsFailure(ctx, emp._id, workDate, actionKey, 'accuracy_too_low', input.accuracyMeters);
        throw geoErr('GPS_ACCURACY_TOO_LOW', `Your location is only accurate to about ${verdict.accuracyMeters} m; we need ${verdict.requiredAccuracy} m or better. Move near a window or outdoors and try again.`, {
          accuracyMeters: verdict.accuracyMeters,
          requiredAccuracy: verdict.requiredAccuracy,
          retriesLeft: Math.max(0, retryLimit - failures),
          exceptionAvailable: failures >= retryLimit,
        });
      } else {
        // Outside of company area: allow punch with exact map coordinates, flag as outside_geofence
        isOutsideCompany = true;
        Object.assign(punch, { method: 'remote', verification: 'outside_radius', distanceMeters: verdict.distanceMeters });
        pendingFlags.push({
          type: 'outside_geofence',
          severity: 'low',
          details: {
            distanceMeters: verdict.distanceMeters,
            radiusMeters: verdict.radiusMeters,
            remote: true,
            latitude: input.latitude,
            longitude: input.longitude,
          },
        });
      }
    }

    // ---- selfie: when user is outside company area, they do NOT upload selfies!
    const effectiveRequireSelfie = !isOutsideCompany && requireSelfie;
    if (effectiveRequireSelfie && !input.selfieFileId) throw geoErr('SELFIE_REQUIRED', 'Take a photo to continue.', {});
    let selfieFile: any;
    if (input.selfieFileId) selfieFile = await this.files.requireOwnUpload(ctx, input.selfieFileId, 'selfie', 10);

    // ---- suspicious patterns (flag only)
    pendingFlags.push(...(await this.detectPatterns(ctx, emp, input, punch, now, org)));
    if (pendingFlags.some((f) => f.type === 'mock_location')) punch.mockLocationSuspected = true;

    // ---- write
    const shift = await this.shifts.effectiveShift(ctx.orgOid, emp._id, workDate);
    let record: any;
    if (action === 'checkIn') {
      const late = shift ? this.lateMinutes(now, workDate, shift, org.timezone) : 0;
      const newSession = { checkIn: punch };
      if (!existing) {
        try {
          record = await this.attendance.findOneAndUpdate(
            { organizationId: ctx.orgOid, employeeId: emp._id, workDate },
            {
              $set: {
                checkIn: punch,
                sessions: [newSession],
                shiftId: shift?._id,
                lateMinutes: late,
                status: late > 0 ? 'late' : 'present',
              },
              $unset: { checkOut: '' },
            },
            { upsert: true, new: true },
          );
        } catch (e: any) {
          if (e?.code === 11000) throw conflict('ALREADY_CHECKED_IN', 'You already checked in today.');
          throw e;
        }
      } else {
        const gapMin = lastExistingSession?.checkOut?.at
          ? Math.max(0, Math.round((now.getTime() - new Date(lastExistingSession.checkOut.at).getTime()) / 60_000))
          : 0;
        const breakMinutes = (existing.breakMinutes ?? 0) + gapMin;
        record = await this.attendance.findOneAndUpdate(
          { _id: existing._id },
          {
            $push: { sessions: newSession },
            $set: { breakMinutes },
            $unset: { checkOut: '' },
          },
          { new: true },
        );
      }
    } else {
      const updatedSessions = [...existingSessions];
      const activeIdx = updatedSessions.length - 1;
      const activeSession = updatedSessions[activeIdx];
      const sessionDuration = Math.max(0, Math.round((now.getTime() - new Date(activeSession.checkIn.at).getTime()) / 60_000));
      updatedSessions[activeIdx] = {
        ...activeSession,
        checkOut: punch,
        durationMinutes: sessionDuration,
      };

      let totalWorked = updatedSessions.reduce((sum: number, s: any) => sum + (s.durationMinutes || 0), 0);
      let finalBreakMinutes = existing.breakMinutes ?? 0;

      if (updatedSessions.length === 1 && totalWorked >= 270) {
        finalBreakMinutes = shift?.breakMinutes ?? 60;
        totalWorked = Math.max(0, totalWorked - finalBreakMinutes);
      }

      let overtime = 0;
      let early = 0;
      if (shift) {
        const len = shiftLength(shift) - (shift.breakMinutes ?? 60);
        const threshold = shift.overtimeAfterMinutes || len;
        overtime = Math.max(0, totalWorked - threshold);
        const end = zonedTimeToUtc(toMinutes(shift.endTime) <= toMinutes(shift.startTime) ? addDays(workDate, 1) : workDate, shift.endTime, org.timezone);
        early = Math.max(0, Math.floor((end.getTime() - now.getTime()) / 60_000));
      }

      let dayCount = 0.0;
      let status = 'incomplete';
      if (totalWorked >= 360) {
        dayCount = 1.0;
        status = (existing.lateMinutes ?? 0) > 0 ? 'late' : 'present';
      } else if (totalWorked >= 150) {
        dayCount = 0.5;
        status = 'half_day';
      }

      record = await this.attendance.findOneAndUpdate(
        { _id: existing._id },
        {
          $set: {
            checkOut: punch,
            sessions: updatedSessions,
            breakMinutes: finalBreakMinutes,
            workedMinutes: totalWorked,
            overtimeMinutes: overtime,
            earlyLeaveMinutes: early,
            status,
            dayCount,
          },
        },
        { new: true },
      );
      if (!record) throw conflict('ALREADY_CHECKED_OUT', 'Record not found.');
    }

    if (selfieFile) {
      const retentionDays = org.settings?.attendance?.selfieRetentionDays ?? 45; // 1 month 15 days
      const deleteAfter = new Date(now.getTime() + retentionDays * 86400_000);
      const ev = await this.evidence.create({ organizationId: ctx.orgOid, employeeId: emp._id, attendanceId: record._id, kind: 'selfie', fileId: selfieFile._id, capturedAt: now, deleteAfter });
      await this.files.link(selfieFile._id, { type: 'attendance_evidence', id: ev._id });
      await this.files.setDeleteAfter(selfieFile._id, deleteAfter);
      await this.attendance.updateOne({ _id: record._id }, { $set: { [`${action}.selfieEvidenceId`]: ev._id } });
    }
    for (const f of pendingFlags) await this.raiseFlag(ctx.orgOid, emp._id, record._id, f);

    // Exceptions and late offline syncs become correction requests for a person to approve.
    if (exception || (input.queuedOffline && input.clientRecordedAt && Math.abs(now.getTime() - input.clientRecordedAt.getTime()) > 10 * 60_000)) {
      await this.createCorrection(ctx, emp, {
        workDate,
        kind: exception ? 'gps_failure' : 'wrong_time',
        requestedCheckIn: action === 'checkIn' && input.clientRecordedAt ? input.clientRecordedAt : undefined,
        requestedCheckOut: action === 'checkOut' && input.clientRecordedAt ? input.clientRecordedAt : undefined,
        reason: input.exceptionReason ?? 'Recorded offline; synced later. Device time shown for reference only.',
      }, record._id);
    }

    await this.audit.record(ctx, { action: `attendance.${actionKey}`, resourceType: 'attendance', resourceId: record._id, changes: { verification: { from: null, to: punch.verification }, distanceMeters: { from: null, to: punch.distanceMeters ?? null } } });
    this.realtime.toRoom(`org:${ctx.user.orgId}:attendance`, 'attendance:changed', { employeeId: String(emp._id), workDate, action: actionKey });
    
    // Automated check-in / check-out confirmation notification & email
    const punchTimeStr = this.fmt(now, org);
    const targetUserId = emp.userId ?? ctx.userOid;
    if (targetUserId) {
      if (action === 'checkIn') {
        void this.notifications.notify(ctx.orgOid, [targetUserId], {
          event: 'attendance_check_in',
          title: `Check-In Confirmed (${punchTimeStr})`,
          body: `Hi ${emp.firstName || ctx.user.name || 'there'}, your attendance check-in for ${workDate} was successfully recorded at ${punchTimeStr}. Have a great day at Bulletproof Brands!`,
          link: '/time/attendance',
          priority: 'normal',
        }).catch((e) => this.logger.warn(`Failed notifying checkIn: ${e.message}`));
      } else {
        const workedH = Math.floor((record.workedMinutes || 0) / 60);
        const workedM = (record.workedMinutes || 0) % 60;
        const workedStr = workedH > 0 ? `${workedH}h ${workedM}m` : `${workedM}m`;
        void this.notifications.notify(ctx.orgOid, [targetUserId], {
          event: 'attendance_check_out',
          title: `Check-Out Confirmed (${punchTimeStr})`,
          body: `Hi ${emp.firstName || ctx.user.name || 'there'}, your check-out for ${workDate} was recorded at ${punchTimeStr}. Total time worked today: ${workedStr}. Rest well!`,
          link: '/time/attendance',
          priority: 'normal',
        }).catch((e) => this.logger.warn(`Failed notifying checkOut: ${e.message}`));
      }
    }

    const fresh = await this.attendance.findById(record._id).lean();
    return { record: serialize(fresh), flagsRaised: pendingFlags.map((f) => f.type), exception };
  }

  private fmt(at: Date, org: any): string {
    return new Intl.DateTimeFormat('en-IN', { timeZone: org.timezone, hour: 'numeric', minute: '2-digit', hour12: org.timeFormat !== '24h' }).format(new Date(at));
  }

  private km(m: number): string {
    return m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${m} m`;
  }

  private async recordGpsFailure(ctx: Ctx, employeeId: Types.ObjectId, workDate: string, action: string, reason: string, accuracy?: number, distance?: number): Promise<number> {
    await this.gpsAttempts.create({ organizationId: ctx.orgOid, employeeId, workDate, action, reason, accuracyMeters: accuracy != null ? Math.round(accuracy) : undefined, distanceMeters: distance, at: new Date() });
    // Repeated failures over a week are a pattern worth a look (not a penalty).
    const week = await this.gpsAttempts.countDocuments({ organizationId: ctx.orgOid, employeeId, at: { $gt: new Date(Date.now() - 7 * 86400_000) } });
    if (week >= 6) {
      const open = await this.flags.exists({ organizationId: ctx.orgOid, employeeId, type: 'repeated_gps_failure', status: 'open', createdAt: { $gt: new Date(Date.now() - 86400_000) } });
      if (!open) await this.raiseFlag(ctx.orgOid, employeeId, undefined, { type: 'repeated_gps_failure', severity: 'low', details: { failuresLast7Days: week } });
    }
    return this.gpsAttempts.countDocuments({ organizationId: ctx.orgOid, employeeId, workDate, action });
  }

  /** Shared device, impossible travel, mock-location signals. */
  private async detectPatterns(ctx: Ctx, emp: any, input: PunchInput, punch: Record<string, any>, now: Date, org: any) {
    const out: { type: string; severity: string; details: Record<string, unknown> }[] = [];
    if (ctx.deviceId) {
      const dev = await this.devices.findOne({ organizationId: ctx.orgOid, deviceId: ctx.deviceId }).lean<any>();
      const others = (dev?.userIds ?? []).filter((u: any) => String(u) !== ctx.user.userId);
      if (others.length) {
        const sameDay = await this.attendance.countDocuments({
          organizationId: ctx.orgOid,
          employeeId: { $ne: emp._id },
          workDate: localParts(now, org.timezone).day,
          $or: [{ 'checkIn.deviceId': ctx.deviceId }, { 'checkOut.deviceId': ctx.deviceId }],
        });
        out.push({ type: 'shared_device', severity: sameDay ? 'high' : 'medium', details: { otherAccounts: others.length, punchesByOthersToday: sameDay } });
      }
    }
    if (punch.latitude != null) {
      const prev = await this.attendance
        .findOne({ organizationId: ctx.orgOid, employeeId: emp._id, $or: [{ 'checkOut.latitude': { $exists: true } }, { 'checkIn.latitude': { $exists: true } }], updatedAt: { $gt: new Date(now.getTime() - 24 * 3600_000) } })
        .sort({ updatedAt: -1 })
        .lean<any>();
      const last = prev?.checkOut?.latitude != null ? prev.checkOut : prev?.checkIn?.latitude != null ? prev.checkIn : null;
      if (last) {
        const kmh = speedKmh({ latitude: last.latitude, longitude: last.longitude, at: new Date(last.at) }, { latitude: punch.latitude, longitude: punch.longitude, at: now });
        const meters = haversineMeters(last.latitude, last.longitude, punch.latitude, punch.longitude);
        const limit = org.settings?.attendance?.impossibleTravelKmh ?? 150;
        if (meters > 2000 && kmh > limit) out.push({ type: 'impossible_travel', severity: 'high', details: { fromAt: last.at, km: Math.round(meters / 100) / 10, kmh: Math.round(kmh) } });
        if (last.latitude === punch.latitude && last.longitude === punch.longitude && last.accuracyMeters === punch.accuracyMeters) {
          out.push({ type: 'mock_location', severity: 'medium', details: { signal: 'repeated_exact_fix' } });
        }
      }
    }
    const signals = new Set(input.mockSignals ?? []);
    if (input.accuracyMeters === 0) signals.add('zero_accuracy');
    if (signals.size && !out.some((o) => o.type === 'mock_location')) out.push({ type: 'mock_location', severity: 'medium', details: { signals: [...signals] } });
    return out;
  }

  private async raiseFlag(orgId: Types.ObjectId, employeeId: Types.ObjectId, attendanceId: Types.ObjectId | undefined, f: { type: string; severity: string; details: Record<string, unknown> }): Promise<void> {
    await this.flags.create({ organizationId: orgId, employeeId, attendanceId, type: f.type, severity: f.severity, details: f.details, status: 'open' });
    if (attendanceId) await this.attendance.updateOne({ _id: attendanceId }, { $addToSet: { flags: f.type } });
  }

  // ------------------------------------------------------------------ calculations

  lateMinutes(at: Date, workDate: string, shift: any, tz: string): number {
    const start = zonedTimeToUtc(workDate, shift.startTime, tz);
    const diffMin = Math.floor((at.getTime() - start.getTime()) / 60_000);
    return diffMin > (shift.graceMinutes ?? 0) ? diffMin : 0;
  }

  /** Worked, overtime, early-leave minutes and day status from server-validated timestamps. */
  totals(inAt: Date, outAt: Date, shift: any, org: any, lateMinutes: number, workDate: string): Record<string, unknown> {
    const gross = Math.max(0, Math.round((new Date(outAt).getTime() - new Date(inAt).getTime()) / 60_000));
    // Automatic 1:00 PM to 2:00 PM lunch break (60 minutes):
    // Deducted when the shift spans through lunch or gross duration is >= 4.5 hours (270 min)
    const breakMinutes = gross >= 270 ? (shift?.breakMinutes ?? 60) : 0;
    const worked = Math.max(0, gross - breakMinutes);
    let overtime = 0;
    let early = 0;
    if (shift) {
      const len = shiftLength(shift) - (shift.breakMinutes ?? 60);
      const threshold = shift.overtimeAfterMinutes || len;
      overtime = Math.max(0, worked - threshold);
      const end = zonedTimeToUtc(toMinutes(shift.endTime) <= toMinutes(shift.startTime) ? addDays(workDate, 1) : workDate, shift.endTime, org.timezone);
      early = Math.max(0, Math.floor((end.getTime() - new Date(outAt).getTime()) / 60_000));
    }
    const a = org.settings?.attendance ?? {};
    let status = lateMinutes > 0 ? 'late' : 'present';
    let dayCount = 1.0;
    // Shift: 10:00 AM - 1:00 PM (Morning 3h = 180m), 1:00 PM - 2:00 PM Break (60m auto), 2:00 PM - 7:00 PM (Afternoon 5h = 300m).
    // Total scheduled net work: 480m (8 hours).
    // Full Day (1.0): >= 360 mins (6 hours net work, spanning both sessions).
    // Half Day (0.5): >= 150 mins (2.5 hours, e.g. morning session 3h or afternoon session 5h).
    if (worked >= 360) {
      dayCount = 1.0;
      status = lateMinutes > 0 ? 'late' : 'present';
    } else if (worked >= 150) {
      dayCount = 0.5;
      status = 'half_day';
    } else {
      dayCount = 0.0;
      status = 'incomplete';
    }
    return { breakMinutes, workedMinutes: worked, overtimeMinutes: overtime, earlyLeaveMinutes: early, status, dayCount };
  }

  // ------------------------------------------------------------------ queries

  async list(ctx: Ctx, q: { from: string; to: string; employeeId?: string; status?: string; flagged?: boolean; overtime?: boolean; page: number; limit: number }): Promise<Paged<any>> {
    const filter: Record<string, any> = await this.scope.filter(ctx, 'attendance', 'view');
    if (q.employeeId) {
      await this.scope.requireCovers(ctx, 'attendance', 'view', q.employeeId);
      filter.employeeId = oid(q.employeeId);
    }
    filter.workDate = { $gte: q.from, $lte: q.to };
    if (q.status) filter.status = q.status;
    if (q.flagged) filter['flags.0'] = { $exists: true };
    if (q.overtime) filter.overtimeMinutes = { $gt: 0 };
    const [rows, total] = await Promise.all([
      this.attendance.find(filter).sort({ workDate: -1, 'checkIn.at': -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean<any[]>(),
      this.attendance.countDocuments(filter),
    ]);
    const emps = await this.employees.find({ _id: { $in: rows.map((r) => r.employeeId) } }, { firstName: 1, lastName: 1, employeeCode: 1 }).lean<any[]>();
    const name = new Map(emps.map((e) => [String(e._id), `${e.firstName} ${e.lastName ?? ''}`.trim()]));
    const canEvidence = ctx.authz.can('attendance_evidence', 'view');
    const items = serialize(rows).map((r: any) => {
      if (!canEvidence && r.employeeId !== ctx.user.employeeId) {
        // Evidence references are hidden from people who may not see them.
        if (r.checkIn) delete r.checkIn.selfieEvidenceId;
        if (r.checkOut) delete r.checkOut.selfieEvidenceId;
      }
      return { ...r, employeeName: name.get(r.employeeId) };
    });
    return { items, page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  /** Month heatmap for one employee: a status per day (holidays, weekly offs and leave included). */
  async calendar(ctx: Ctx, employeeId: string, month: string): Promise<any> {
    if (!(await this.scope.covers(ctx, 'attendance', 'view', employeeId))) throw notFound('Employee');
    const emp = await this.employees.findOne({ _id: oid(employeeId), organizationId: ctx.orgOid }).lean<any>();
    if (!emp) throw notFound('Employee');
    const org = await this.orgSettings.get(ctx.orgOid);
    const start = `${month}-01`;
    const [y, m] = month.split('-').map(Number);
    const end = `${month}-${String(new Date(Date.UTC(y, m, 0)).getUTCDate()).padStart(2, '0')}`;
    const [records, hols, leaves] = await Promise.all([
      this.attendance.find({ organizationId: ctx.orgOid, employeeId: emp._id, workDate: { $gte: start, $lte: end } }).lean<any[]>(),
      this.holidays.find({ organizationId: ctx.orgOid, date: { $gte: start, $lte: end }, $or: [{ locationIds: { $size: 0 } }, { locationIds: emp.locationId }] }).lean<any[]>(),
      this.leaves.find({ organizationId: ctx.orgOid, employeeId: emp._id, status: 'approved', startDate: { $lte: end }, endDate: { $gte: start } }).lean<any[]>(),
    ]);
    const today = localParts(new Date(), org.timezone).day;
    const byDay = new Map(records.map((r) => [r.workDate, r]));
    const holidayOn = new Map(hols.map((h) => [h.date, h.name]));
    const days = [];
    for (const d of daysBetween(start, end)) {
      const r = byDay.get(d);
      let status: string;
      if (r) status = r.status;
      else if (holidayOn.has(d)) status = 'holiday';
      else if (leaves.some((l) => l.startDate <= d && l.endDate >= d)) status = 'on_leave';
      else if (!(org.workingDays ?? [1, 2, 3, 4, 5, 6]).includes(weekdayOf(d))) status = 'weekly_off';
      else if (d > today || (emp.joiningDate && d < new Date(emp.joiningDate).toISOString().slice(0, 10))) status = 'none';
      else if (d === today) status = 'none';
      else status = 'absent';
      days.push({ day: d, status, workedMinutes: r?.workedMinutes ?? 0, lateMinutes: r?.lateMinutes ?? 0, holiday: holidayOn.get(d) ?? null, flags: r?.flags ?? [] });
    }
    const summary: Record<string, number> = {};
    for (const d of days) summary[d.status] = (summary[d.status] ?? 0) + 1;
    return { employeeId, month, days, summary };
  }

  /** Live board: who is in, late, remote or on leave, by location and shift, with coverage warnings. */
  async live(ctx: Ctx): Promise<any> {
    const scopeFilter = await this.scope.filter(ctx, 'attendance', 'view', '_id');
    const org = await this.orgSettings.get(ctx.orgOid);
    const day = localParts(new Date(), org.timezone).day;
    const emps = await this.employees.find({ ...scopeFilter, status: { $in: ['active', 'probation', 'notice', 'onboarding'] } }, { firstName: 1, lastName: 1, locationId: 1, shiftId: 1, departmentId: 1, photoFileId: 1 }).lean<any[]>();
    const ids = emps.map((e) => e._id);
    const [records, leaves, locs, shifts] = await Promise.all([
      this.attendance.find({ organizationId: ctx.orgOid, employeeId: { $in: ids }, workDate: day }).lean<any[]>(),
      this.leaves.find({ organizationId: ctx.orgOid, employeeId: { $in: ids }, status: 'approved', startDate: { $lte: day }, endDate: { $gte: day } }, { employeeId: 1 }).lean<any[]>(),
      this.locations.find({ organizationId: ctx.orgOid }, { name: 1 }).lean<any[]>(),
      this.shiftModel.find({ organizationId: ctx.orgOid }, { name: 1, startTime: 1 }).lean<any[]>(),
    ]);
    const rec = new Map(records.map((r) => [String(r.employeeId), r]));
    const onLeave = new Set(leaves.map((l) => String(l.employeeId)));
    const locName = new Map(locs.map((l) => [String(l._id), l.name]));
    const people = emps.map((e) => {
      const r = rec.get(String(e._id));
      const state = onLeave.has(String(e._id)) ? 'on_leave' : !r?.checkIn ? 'not_in' : r.checkOut ? 'left' : r.checkIn.method === 'remote' ? 'remote' : r.lateMinutes > 0 ? 'late' : 'in';
      return { employeeId: String(e._id), name: `${e.firstName} ${e.lastName ?? ''}`.trim(), photoFileId: e.photoFileId ? String(e.photoFileId) : null, state, since: r?.checkIn?.at ?? null, location: locName.get(String(e.locationId)) ?? null, shiftId: e.shiftId ? String(e.shiftId) : null, flags: r?.flags ?? [] };
    });
    const counts: Record<string, number> = {};
    for (const p of people) counts[p.state] = (counts[p.state] ?? 0) + 1;
    // Coverage: per location, how many of the expected people are in.
    const byLocation = new Map<string, { location: string; expected: number; present: number }>();
    for (const p of people) {
      if (p.state === 'on_leave') continue;
      const key = p.location ?? 'Unassigned';
      const v = byLocation.get(key) ?? { location: key, expected: 0, present: 0 };
      v.expected++;
      if (['in', 'late', 'remote', 'left'].includes(p.state)) v.present++;
      byLocation.set(key, v);
    }
    const coverage = [...byLocation.values()].map((c) => ({ ...c, warning: c.expected >= 3 && c.present / c.expected < 0.5 }));
    return { workDate: day, counts, people, coverage, shifts: serialize(shifts) };
  }

  // ------------------------------------------------------------------ corrections

  async requestCorrection(ctx: Ctx, input: z.infer<typeof correctionInput>): Promise<any> {
    const emp = await this.requireEmployee(ctx);
    const org = await this.orgSettings.get(ctx.orgOid);
    const today = localParts(new Date(), org.timezone).day;
    if (input.workDate > today) throw badRequest('FUTURE_DATE', "You can't correct a future day.", 'workDate');
    if (input.workDate < addDays(today, -31)) throw badRequest('TOO_OLD', 'Corrections are possible for the last 31 days.', 'workDate');
    if (input.requestedCheckIn && input.requestedCheckOut && input.requestedCheckOut <= input.requestedCheckIn) throw badRequest('TIMES_INVALID', 'Check-out must be after check-in.', 'requestedCheckOut');
    for (const t of [input.requestedCheckIn, input.requestedCheckOut]) if (t && t > new Date()) throw badRequest('FUTURE_TIME', "A requested time can't be in the future.");
    const rec = await this.attendance.findOne({ organizationId: ctx.orgOid, employeeId: emp._id, workDate: input.workDate }).lean<any>();
    return this.createCorrection(ctx, emp, input, rec?._id);
  }

  private async createCorrection(ctx: Ctx, emp: any, input: { workDate: string; kind: string; requestedCheckIn?: Date; requestedCheckOut?: Date; reason: string }, attendanceId?: Types.ObjectId): Promise<any> {
    if (await this.corrections.exists({ organizationId: ctx.orgOid, employeeId: emp._id, workDate: input.workDate, status: 'pending' })) {
      throw conflict('CORRECTION_PENDING', 'There is already a correction waiting for approval for this day.');
    }
    const c = await this.corrections.create({ organizationId: ctx.orgOid, employeeId: emp._id, attendanceId, ...input });
    if (attendanceId) await this.attendance.updateOne({ _id: attendanceId }, { $set: { correctionRequestId: c._id, status: 'pending_correction' } });
    const a = await this.approvals.start(ctx, {
      requestType: 'attendance_correction',
      requestId: c._id,
      subjectEmployeeId: emp._id,
      title: `Attendance correction: ${emp.firstName} ${emp.lastName ?? ''}`.trim(),
      summary: `${input.workDate} · ${input.kind.replace(/_/g, ' ')} · ${input.reason}`,
      link: '/time/attendance',
    });
    await this.corrections.updateOne({ _id: c._id }, { $set: { approvalId: a._id } });
    return serialize({ ...c.toObject(), approvalId: a._id });
  }

  /** Approved correction: applies times with method "correction" and recalculates the day. Idempotent. */
  private async applyCorrection(correctionId: Types.ObjectId, by?: Types.ObjectId): Promise<void> {
    const c = await this.corrections.findOneAndUpdate({ _id: correctionId, status: 'pending' }, { $set: { status: 'approved', decidedAt: new Date(), decidedBy: by } }, { new: true }).lean<any>();
    if (!c) return;
    const org = await this.orgSettings.get(c.organizationId);
    const rec = await this.attendance.findOne({ organizationId: c.organizationId, employeeId: c.employeeId, workDate: c.workDate }).lean<any>();
    const set: Record<string, unknown> = { approvedCorrectionId: c._id };
    const inAt = c.requestedCheckIn ?? rec?.checkIn?.at;
    const outAt = c.requestedCheckOut ?? rec?.checkOut?.at;
    if (c.requestedCheckIn) set.checkIn = { ...(rec?.checkIn ?? {}), at: c.requestedCheckIn, method: 'correction', verification: rec?.checkIn?.verification === 'exception_pending' ? 'exception_approved' : (rec?.checkIn?.verification ?? 'not_required') };
    else if (rec?.checkIn?.verification === 'exception_pending') set['checkIn.verification'] = 'exception_approved';
    if (c.requestedCheckOut) set.checkOut = { ...(rec?.checkOut ?? {}), at: c.requestedCheckOut, method: 'correction', verification: 'not_required' };
    else if (rec?.checkOut?.verification === 'exception_pending') set['checkOut.verification'] = 'exception_approved';
    const shift = await this.shifts.effectiveShift(c.organizationId, c.employeeId, c.workDate);
    const late = inAt && shift ? this.lateMinutes(new Date(inAt), c.workDate, shift, org.timezone) : 0;
    set.lateMinutes = late;
    if (inAt && outAt) Object.assign(set, this.totals(new Date(inAt), new Date(outAt), shift, org, late, c.workDate));
    else set.status = inAt ? (late ? 'late' : 'present') : 'incomplete';
    await this.attendance.updateOne({ organizationId: c.organizationId, employeeId: c.employeeId, workDate: c.workDate }, { $set: set, $setOnInsert: { shiftId: shift?._id } }, { upsert: true });
  }

  async listCorrections(ctx: Ctx, status?: string): Promise<any[]> {
    const filter: Record<string, unknown> = await this.scope.filter(ctx, 'attendance', 'view');
    if (status) filter.status = status;
    const rows = await this.corrections.find(filter).sort({ createdAt: -1 }).limit(200).lean<any[]>();
    const emps = await this.employees.find({ _id: { $in: rows.map((r) => r.employeeId) } }, { firstName: 1, lastName: 1 }).lean<any[]>();
    const name = new Map(emps.map((e) => [String(e._id), `${e.firstName} ${e.lastName ?? ''}`.trim()]));
    return serialize(rows).map((r: any) => ({ ...r, employeeName: name.get(r.employeeId) }));
  }

  // ------------------------------------------------------------------ flags

  async listFlags(ctx: Ctx, status = 'open'): Promise<any[]> {
    const filter: Record<string, unknown> = await this.scope.filter(ctx, 'attendance', 'approve');
    filter.status = status;
    const rows = await this.flags.find(filter).sort({ createdAt: -1 }).limit(200).lean<any[]>();
    const emps = await this.employees.find({ _id: { $in: rows.map((r) => r.employeeId) } }, { firstName: 1, lastName: 1 }).lean<any[]>();
    const name = new Map(emps.map((e) => [String(e._id), `${e.firstName} ${e.lastName ?? ''}`.trim()]));
    return serialize(rows).map((r: any) => ({ ...r, employeeName: name.get(r.employeeId) }));
  }

  /** A person reviews each flag. Outcomes are notes only; nothing changes pay or status automatically. */
  async reviewFlag(ctx: Ctx, id: string, outcome: 'reviewed_ok' | 'reviewed_concern' | 'dismissed', note?: string): Promise<any> {
    const f = await this.flags.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!f) throw notFound('Flag');
    await this.scope.requireCovers(ctx, 'attendance', 'approve', f.employeeId);
    await this.flags.updateOne({ _id: f._id }, { $set: { status: outcome, reviewedBy: ctx.userOid, reviewedAt: new Date(), reviewNote: note } });
    await this.audit.record(ctx, { action: 'attendance.flag_review', resourceType: 'attendance_flag', resourceId: id, changes: { status: { from: f.status, to: outcome } } });
    return serialize(await this.flags.findById(f._id).lean());
  }

  async evidenceFor(ctx: Ctx, attendanceId: string): Promise<any[]> {
    const rec = await this.attendance.findOne({ _id: oid(attendanceId), organizationId: ctx.orgOid }).lean<any>();
    if (!rec) throw notFound('Attendance');
    const own = String(rec.employeeId) === ctx.user.employeeId;
    if (!own && !(await this.scope.covers(ctx, 'attendance_evidence', 'view', rec.employeeId))) throw notFound('Attendance');
    if (!own) await this.audit.record(ctx, { action: 'attendance.evidence_view', resourceType: 'attendance', resourceId: attendanceId });
    return serialize(await this.evidence.find({ organizationId: ctx.orgOid, attendanceId: rec._id }).lean());
  }

  // ------------------------------------------------------------------ daily jobs

  /**
   * Shortly after midnight: yesterday's open records become "incomplete" (no invented check-out times)
   * and working-day absences are recorded, skipping holidays, weekly offs and approved leave.
   */
  @Cron('20 0 * * *')
  async closeDay(): Promise<void> {
    await this.jobs.run('attendance.close_day', async () => {
      let incomplete = 0;
      let absent = 0;
      const orgs = await this.employees.distinct('organizationId');
      for (const orgId of orgs) {
        const org = await this.orgSettings.get(orgId);
        if (!org) continue;
        const yesterday = addDays(localParts(new Date(), org.timezone).day, -1);
        const r = await this.attendance.updateMany({ organizationId: orgId, workDate: yesterday, 'checkIn.at': { $exists: true }, 'checkOut.at': { $exists: false }, status: { $nin: ['pending_correction'] } }, { $set: { status: 'incomplete' } });
        incomplete += r.modifiedCount;
        if (!(org.workingDays ?? [1, 2, 3, 4, 5, 6]).includes(weekdayOf(yesterday))) continue;
        const holidayAll = await this.holidays.exists({ organizationId: orgId, date: yesterday, locationIds: { $size: 0 } });
        if (holidayAll) continue;
        const active = await this.employees.find({ organizationId: orgId, status: { $in: ['active', 'probation', 'notice'] }, joiningDate: { $lte: new Date(`${yesterday}T23:59:59Z`) } }, { _id: 1, locationId: 1 }).lean<any[]>();
        const have = new Set((await this.attendance.find({ organizationId: orgId, workDate: yesterday }, { employeeId: 1 }).lean<any[]>()).map((a) => String(a.employeeId)));
        const leave = new Set((await this.leaves.find({ organizationId: orgId, status: 'approved', startDate: { $lte: yesterday }, endDate: { $gte: yesterday } }, { employeeId: 1 }).lean<any[]>()).map((l) => String(l.employeeId)));
        const localHolidays = await this.holidays.find({ organizationId: orgId, date: yesterday }, { locationIds: 1 }).lean<any[]>();
        const holidayLocs = new Set(localHolidays.flatMap((h) => (h.locationIds ?? []).map(String)));
        for (const e of active) {
          const id = String(e._id);
          if (have.has(id)) continue;
          const status = leave.has(id) ? 'on_leave' : holidayLocs.has(String(e.locationId)) ? 'holiday' : 'absent';
          await this.attendance.updateOne({ organizationId: orgId, employeeId: e._id, workDate: yesterday }, { $setOnInsert: { status } }, { upsert: true });
          if (status === 'absent') absent++;
        }
      }
      return `${incomplete} incomplete, ${absent} absent`;
    });
  }

  /** Writes on_leave days when leave is approved (does not override days with a check-in). */
  async markLeave(orgId: Types.ObjectId, employeeId: Types.ObjectId, days: string[], leaveRequestId: Types.ObjectId): Promise<void> {
    for (const d of days) {
      await this.attendance.updateOne(
        { organizationId: orgId, employeeId, workDate: d, 'checkIn.at': { $exists: false } },
        { $set: { status: 'on_leave', leaveRequestId } },
        { upsert: true },
      ).catch((e: any) => {
        if (e?.code !== 11000) throw e; // a check-in exists for that day: keep it
      });
    }
  }

  async unmarkLeave(orgId: Types.ObjectId, leaveRequestId: Types.ObjectId): Promise<void> {
    await this.attendance.deleteMany({ organizationId: orgId, leaveRequestId, 'checkIn.at': { $exists: false } });
  }

  /**
   * Nightly facial data retention purge:
   * Keeps facial/selfie evidence for 1 month 15 days (default 45 days) and then permanently deletes from Google Drive / storage.
   */
  @Cron('40 2 * * *')
  async purgeExpiredFacialData(): Promise<void> {
    await this.jobs.run('attendance.purge_facial_data', async () => {
      const now = new Date();
      const expired = await this.evidence.find({ deleteAfter: { $lt: now } }, { _id: 1, fileId: 1, attendanceId: 1 }).limit(1000).lean<any[]>();
      let purged = 0;
      for (const ev of expired) {
        if (ev.fileId) await this.files.remove(ev.fileId).catch(() => {});
        if (ev.attendanceId) {
          await this.attendance.updateOne(
            { _id: ev.attendanceId },
            { $unset: { 'checkIn.selfieEvidenceId': '', 'checkOut.selfieEvidenceId': '' } },
          );
        }
        await this.evidence.deleteOne({ _id: ev._id });
        purged++;
      }
      return `${purged} facial evidence records and photos permanently purged (1m 15d retention)`;
    });
  }

  /**
   * Automated 7:00 PM attendance check-out reminder (every day except Sunday).
   * Runs periodically (every 5 minutes) and evaluates the local time for each organization.
   * If the organization's local time is 7:00 PM (19:00, 1140 minutes) or later on Monday–Saturday,
   * it finds employees who checked in today but have not checked out, and sends them an in-app
   * notification, web push, and branded email reminder.
   */
  @Cron('*/5 * * * *')
  async remindCheckoutAt7Pm(): Promise<void> {
    await this.jobs.run('attendance.checkout_reminder_7pm', async () => {
      let notifiedCount = 0;
      const orgIds = await this.employees.distinct('organizationId');
      const now = new Date();

      for (const orgId of orgIds) {
        const org = await this.orgSettings.get(orgId);
        if (!org) continue;

        const tz = org.timezone || 'Asia/Kolkata';
        const { day, minutes, weekday } = localParts(now, tz);
        // Exclude Sunday (weekday === 0 in JS Date / localParts)
        if (weekday === 0) continue;

        // Only trigger at or after 7:00 PM (19:00 = 1140 minutes) until midnight
        if (minutes < 1140 || minutes >= 1440) continue;

        // Find employees who checked in today and haven't received reminder yet today
        const unclosed = await this.attendance.find({
          organizationId: orgId,
          workDate: day,
          'checkIn.at': { $exists: true },
          checkoutReminderSentAt: { $exists: false },
        }).lean<any[]>();

        for (const record of unclosed) {
          const sessions: any[] = record?.sessions && record.sessions.length > 0
            ? record.sessions
            : (record?.checkIn ? [{ checkIn: record.checkIn, checkOut: record.checkOut }] : []);
          const last = sessions.length > 0 ? sessions[sessions.length - 1] : null;
          const isSessionOpen = !!(last && !last.checkOut);
          if (!isSessionOpen) continue; // Employee already checked out of current session

          const emp = await this.employees.findById(record.employeeId).lean<any>();
          if (!emp) continue;

          const user = emp.userId ? await this.users.findById(emp.userId).lean<any>() : null;
          const targetEmail = user?.email || emp.contactEmail;
          const targetName = emp.firstName ? `${emp.firstName} ${emp.lastName || ''}`.trim() : user?.fullName || 'Colleague';
          const title = 'Reminder: Please Record Your Check-Out';
          const body = `Hi ${targetName}, our records show you checked in today (${day}) at Bulletproof Brands but have not checked out yet. As our workday ends at 7:00 PM, please remember to record your check-out so your attendance and hours are counted accurately.`;

          // 1. In-App, Push Notification, and Queued Email (essential priority)
          if (emp.userId) {
            await this.notifications.notify(orgId, [emp.userId], {
              event: 'attendance_checkout_reminder',
              title,
              body,
              link: '/time/attendance',
              priority: 'essential',
            });
          } else if (targetEmail && this.mail.canSend) {
            // Direct branded email fallback if no user account linked
            const html = buildBulletproofEmailHtml({
              title,
              body,
              badge: '7:00 PM Check-Out Reminder',
              badgeColor: '#b45309',
              badgeBg: '#fef3c7',
              link: '/time/attendance',
              linkText: 'Check Out Now',
              recipientName: targetName,
              recipientEmail: targetEmail,
              publicWebUrl: this.env.PUBLIC_WEB_URL,
            });
            await this.mail.send({
              to: targetEmail,
              subject: `[Bulletproof Brands] Don't forget to check out today (${day})`,
              text: `Dear ${targetName},\n\nYou checked in today (${day}) but have not yet recorded your check-out.\n\nPlease log in to Bulletproof Brands HRM and check out before you leave:\n${this.env.PUBLIC_WEB_URL}/time/attendance\n\nBulletproof Brands - IMPOSSIBLE TO IGNORE`,
              html,
            }).catch((err) => this.logger.warn(`Failed sending 7pm reminder email to ${targetEmail}: ${err.message}`));
          }

          // Mark reminder sent on record
          await this.attendance.updateOne(
            { _id: record._id },
            { $set: { checkoutReminderSentAt: new Date() } },
          );
          notifiedCount++;
        }
      }
      return `${notifiedCount} employees reminded to check out at 7:00 PM`;
    });
  }
}
