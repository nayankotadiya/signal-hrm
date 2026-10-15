import { Schema } from 'mongoose';
import { baseOptions, orgScoped } from '../database/model';

const { ObjectId, Mixed } = Schema.Types;

// ---------------------------------------------------------------- locations (geofences)
export const LocationSchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true, trim: true },
      address: String,
      latitude: { type: Number, required: true, min: -90, max: 90 },
      longitude: { type: Number, required: true, min: -180, max: 180 },
      radiusMeters: { type: Number, required: true, min: 10, max: 5000, default: 150 },
      timezone: String,
      active: { type: Boolean, default: true },
    },
    baseOptions,
  ),
);

// ---------------------------------------------------------------- shifts
export const ShiftSchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true, trim: true },
      startTime: { type: String, required: true }, // HH:mm, local to the location
      endTime: { type: String, required: true }, // < start means overnight
      breakMinutes: { type: Number, default: 60 },
      workingDays: { type: [Number], default: [1, 2, 3, 4, 5, 6] },
      graceMinutes: { type: Number, default: 10 },
      overtimeAfterMinutes: { type: Number, default: 0 }, // 0 = after shift length
      locationIds: [ObjectId],
      color: String,
      effectiveFrom: Date,
      effectiveTo: Date,
      status: { type: String, enum: ['active', 'archived'], default: 'active' },
    },
    baseOptions,
  ),
);

/** Dated assignment: the shift that applies to an employee from a date (attendance uses the effective one). */
export const ShiftAssignmentSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      shiftId: { type: ObjectId, required: true },
      from: { type: String, required: true }, // YYYY-MM-DD
      to: String,
      assignedBy: ObjectId,
    },
    baseOptions,
  ),
);
ShiftAssignmentSchema.index({ organizationId: 1, employeeId: 1, from: -1 });

export const ShiftChangeRequestSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      kind: { type: String, enum: ['change', 'swap'], default: 'change' },
      date: { type: String, required: true },
      toDate: String,
      requestedShiftId: ObjectId,
      swapWithEmployeeId: ObjectId,
      reason: String,
      ruleCheck: Mixed, // automatic rule checks before the manager decides
      status: { type: String, enum: ['pending', 'approved', 'rejected', 'cancelled'], default: 'pending' },
      approvalId: ObjectId,
    },
    baseOptions,
  ),
);

// ---------------------------------------------------------------- attendance
export const ATTENDANCE_STATUSES = ['present', 'absent', 'late', 'half_day', 'on_leave', 'holiday', 'weekly_off', 'incomplete', 'pending_correction'] as const;

const PunchSchema = new Schema(
  {
    /** Server time. The device clock is never used. */
    at: { type: Date, required: true },
    method: { type: String, enum: ['geofence', 'remote', 'manual', 'correction', 'auto', 'exception'], required: true },
    latitude: Number,
    longitude: Number,
    accuracyMeters: Number,
    locationId: ObjectId,
    distanceMeters: Number,
    /** within_radius | outside_radius | accuracy_too_low | not_required | no_location | exception_pending | exception_approved */
    verification: String,
    selfieEvidenceId: ObjectId,
    deviceId: String,
    ip: String,
    mockLocationSuspected: Boolean,
    queuedOffline: Boolean,
    clientRecordedAt: Date, // reported only for diagnostics; never used for calculations
  },
  { _id: false },
);

export const AttendanceSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true },
      workDate: { type: String, required: true }, // YYYY-MM-DD in the organization time zone
      shiftId: ObjectId,
      checkIn: PunchSchema,
      checkOut: PunchSchema,
      breakMinutes: { type: Number, default: 0 },
      workedMinutes: { type: Number, default: 0 },
      overtimeMinutes: { type: Number, default: 0 },
      lateMinutes: { type: Number, default: 0 },
      earlyLeaveMinutes: { type: Number, default: 0 },
      dayCount: { type: Number, default: 0 },
      status: { type: String, enum: ATTENDANCE_STATUSES, default: 'incomplete' },
      flags: [String], // suspicious-pattern flag ids for review (never auto-punitive)
      correctionRequestId: ObjectId,
      approvedCorrectionId: ObjectId,
      leaveRequestId: ObjectId,
      notes: String,
      checkoutReminderSentAt: Date,
    },
    baseOptions,
  ),
);
// One record per employee per day: duplicate check-ins are impossible at the database level.
AttendanceSchema.index({ organizationId: 1, employeeId: 1, workDate: 1 }, { unique: true });
AttendanceSchema.index({ organizationId: 1, workDate: 1, status: 1 });

export const AttendanceCorrectionSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      attendanceId: ObjectId,
      workDate: { type: String, required: true },
      kind: { type: String, enum: ['missed_check_in', 'missed_check_out', 'wrong_time', 'gps_failure', 'other'], required: true },
      requestedCheckIn: Date,
      requestedCheckOut: Date,
      reason: { type: String, required: true },
      status: { type: String, enum: ['pending', 'approved', 'rejected', 'cancelled'], default: 'pending' },
      approvalId: ObjectId,
      decidedBy: ObjectId,
      decidedAt: Date,
    },
    baseOptions,
  ),
);

/** Selfies and other evidence. Restricted: only the employee and holders of attendance_evidence:view. */
export const AttendanceEvidenceSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      attendanceId: ObjectId,
      kind: { type: String, enum: ['selfie', 'document'], default: 'selfie' },
      fileId: { type: ObjectId, required: true },
      capturedAt: Date, // server time of upload
      deleteAfter: Date, // retention policy
    },
    baseOptions,
  ),
);
AttendanceEvidenceSchema.index({ deleteAfter: 1 });

/** Suspicious patterns flagged for human review. Never changes pay or status by itself. */
export const AttendanceFlagSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      attendanceId: ObjectId,
      type: { type: String, enum: ['shared_device', 'impossible_travel', 'repeated_gps_failure', 'mock_location', 'outside_geofence'], required: true },
      severity: { type: String, enum: ['low', 'medium', 'high'], default: 'medium' },
      details: Mixed,
      status: { type: String, enum: ['open', 'reviewed_ok', 'reviewed_concern', 'dismissed'], default: 'open' },
      reviewedBy: ObjectId,
      reviewedAt: Date,
      reviewNote: String,
    },
    baseOptions,
  ),
);
AttendanceFlagSchema.index({ organizationId: 1, status: 1, createdAt: -1 });

/** Failed location attempts (accuracy too low, permission denied), used for retry limits and flags. */
export const GpsAttemptSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true },
      workDate: String,
      action: { type: String, enum: ['check_in', 'check_out'] },
      reason: { type: String, enum: ['accuracy_too_low', 'permission_denied', 'unavailable', 'timeout', 'outside_radius'] },
      accuracyMeters: Number,
      distanceMeters: Number,
      at: { type: Date, default: Date.now },
    },
    { ...baseOptions, timestamps: false },
  ),
);
GpsAttemptSchema.index({ organizationId: 1, employeeId: 1, at: -1 });

// ---------------------------------------------------------------- leave
export const LeaveTypeSchema = orgScoped(
  new Schema(
    {
      code: { type: String, required: true, uppercase: true, trim: true }, // CL, SL, PL, UL, CO
      name: { type: String, required: true },
      paid: { type: Boolean, default: true },
      color: String,
      allowHalfDay: { type: Boolean, default: true },
      requiresAttachmentAfterDays: Number,
      active: { type: Boolean, default: true },
    },
    baseOptions,
  ),
);
LeaveTypeSchema.index({ organizationId: 1, code: 1 }, { unique: true });

export const LeavePolicySchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true },
      leaveTypeId: { type: ObjectId, required: true },
      annualQuota: { type: Number, default: 0 },
      accrual: { type: String, enum: ['upfront', 'monthly'], default: 'upfront' },
      carryForwardMax: { type: Number, default: 0 },
      maxConsecutiveDays: Number,
      minNoticeDays: { type: Number, default: 0 },
      allowNegative: { type: Boolean, default: false },
      requireHrApproval: { type: Boolean, default: false },
      appliesTo: {
        employmentTypes: [String],
        departmentIds: [ObjectId],
        locationIds: [ObjectId],
        afterProbationOnly: { type: Boolean, default: false },
      },
      active: { type: Boolean, default: true },
    },
    baseOptions,
  ),
);

export const LeaveBalanceSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true },
      leaveTypeId: { type: ObjectId, required: true },
      year: { type: Number, required: true },
      entitled: { type: Number, default: 0 },
      carriedForward: { type: Number, default: 0 },
      used: { type: Number, default: 0 },
      pending: { type: Number, default: 0 },
      adjusted: { type: Number, default: 0 },
    },
    baseOptions,
  ),
);
LeaveBalanceSchema.index({ organizationId: 1, employeeId: 1, leaveTypeId: 1, year: 1 }, { unique: true });

/**
 * Every balance movement, keyed so the same movement can never apply twice
 * (retried approvals never double-deduct).
 */
export const LeaveLedgerSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true },
      leaveTypeId: { type: ObjectId, required: true },
      year: Number,
      movementKey: { type: String, required: true }, // e.g. "request:<id>:approve"
      field: { type: String, enum: ['used', 'pending', 'adjusted', 'entitled', 'carriedForward'] },
      delta: Number,
      requestId: ObjectId,
      byUserId: ObjectId,
      note: String,
    },
    baseOptions,
  ),
);
LeaveLedgerSchema.index({ organizationId: 1, movementKey: 1 }, { unique: true });

export const LeaveRequestSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      leaveTypeId: { type: ObjectId, required: true },
      startDate: { type: String, required: true },
      endDate: { type: String, required: true },
      partialDay: { type: String, enum: ['none', 'first_half', 'second_half'], default: 'none' },
      units: { type: Number, required: true },
      reason: String,
      attachmentFileId: ObjectId,
      status: { type: String, enum: ['pending', 'approved', 'rejected', 'cancelled', 'clarification'], default: 'pending', index: true },
      approvalId: ObjectId,
      decisionComment: String,
      decidedAt: Date,
      decidedBy: ObjectId,
    },
    baseOptions,
  ),
);
LeaveRequestSchema.index({ organizationId: 1, startDate: 1, endDate: 1 });

// ---------------------------------------------------------------- holidays, events, announcements
export const HolidaySchema = orgScoped(
  new Schema(
    {
      date: { type: String, required: true },
      name: { type: String, required: true },
      optional: { type: Boolean, default: false },
      locationIds: [ObjectId], // empty = organization-wide
    },
    baseOptions,
  ),
);
HolidaySchema.index({ organizationId: 1, date: 1 });

export const HrEventSchema = orgScoped(
  new Schema(
    {
      title: { type: String, required: true },
      description: String,
      startAt: { type: Date, required: true },
      endAt: Date,
      eventType: { type: String, enum: ['company', 'training', 'celebration', 'deadline', 'other'], default: 'company' },
      locationIds: [ObjectId],
      departmentIds: [ObjectId],
      visibility: { type: String, enum: ['organization', 'departments', 'locations'], default: 'organization' },
      createdBy: ObjectId,
      status: { type: String, enum: ['scheduled', 'cancelled', 'done'], default: 'scheduled' },
    },
    { ...baseOptions, collection: 'hr_events' },
  ),
);

export const AnnouncementSchema = orgScoped(
  new Schema(
    {
      kind: { type: String, enum: ['announcement', 'kudos'], default: 'announcement' },
      title: { type: String, required: true },
      body: String,
      toEmployeeId: ObjectId, // kudos
      audience: { departmentIds: [ObjectId], locationIds: [ObjectId] },
      pinned: { type: Boolean, default: false },
      publishedAt: Date,
      expiresAt: Date,
      createdBy: ObjectId,
      reactions: { type: Map, of: Number, default: {} },
    },
    baseOptions,
  ),
);
