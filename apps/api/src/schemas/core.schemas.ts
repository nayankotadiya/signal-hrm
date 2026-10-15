import { Schema } from 'mongoose';
import { baseOptions, orgScoped } from '../database/model';

const { ObjectId, Mixed } = Schema.Types;

// ---------------------------------------------------------------- organizations
export const OrganizationSchema = new Schema(
  {
    name: { type: String, required: true, trim: true },
    legalName: String,
    logoFileId: { type: ObjectId, ref: 'File' },
    registration: { gstin: String, pan: String, cin: String, other: String },
    primaryContact: { name: String, email: String, phone: String },
    supportEmail: String,
    timezone: { type: String, default: 'Asia/Kolkata' },
    currency: { type: String, default: 'INR' },
    dateFormat: { type: String, default: 'dd MMM yyyy' },
    timeFormat: { type: String, enum: ['12h', '24h'], default: '12h' },
    weekStart: { type: Number, min: 0, max: 6, default: 1 }, // 0 Sunday ... 6 Saturday
    workingDays: { type: [Number], default: [1, 2, 3, 4, 5, 6] },
    offices: [{ label: String, address: String }],
    defaultLocale: { type: String, default: 'en' },
    status: { type: String, enum: ['active', 'suspended'], default: 'active' },
    branding: { primaryColor: String, accent: String },
    /** Module switches. A disabled module disappears from navigation and its API answers 403 FEATURE_DISABLED. */
    features: { type: Map, of: Boolean, default: {} },
    settings: {
      attendance: {
        // The user's Phase 4 rules: requirements per action, accuracy limit, server time only.
        checkIn: { requireLocation: { type: Boolean, default: true }, requireSelfie: { type: Boolean, default: true } },
        checkOut: { requireLocation: { type: Boolean, default: true }, requireSelfie: { type: Boolean, default: true } },
        maxAccuracyMeters: { type: Number, default: 100 },
        allowRemote: { type: Boolean, default: false },
        gpsRetryLimit: { type: Number, default: 2 },
        halfDayMinutes: { type: Number, default: 240 },
        fullDayMinutes: { type: Number, default: 480 },
        autoCheckoutHours: { type: Number, default: 16 },
        selfieRetentionDays: { type: Number, default: 45 }, // 1 month 15 days retention
      },
      leave: {
        approvalByHr: { type: Boolean, default: false },
        allowNegative: { type: Boolean, default: false },
        countWeekends: { type: Boolean, default: false },
        countHolidays: { type: Boolean, default: false },
      },
      payroll: {
        payDay: { type: Number, default: 1 },
        cutoffDay: { type: Number, default: 25 },
        lopBasis: { type: String, enum: ['calendar_days', 'working_days', 'fixed_30'], default: 'working_days' },
        roundNetPay: { type: Boolean, default: true },
      },
      security: {
        sessionDays: { type: Number, default: 30 },
        reauthMinutes: { type: Number, default: 10 },
        maxFailedLogins: { type: Number, default: 5 },
        lockMinutes: { type: Number, default: 15 },
        passwordLogin: { type: Boolean, default: true },
      },
      approvals: { preventSelfApproval: { type: Boolean, default: true }, escalationHours: { type: Number, default: 48 } },
      notifications: { essentialEvents: { type: [String], default: ['security_alert', 'backup_failure', 'system_incident'] } },
      expenses: { receiptRequiredAbove: { type: Number, default: 500 } },
    },
    /** Organization N UI defaults (users can override in their own preferences). */
    nuiDefaults: { type: Mixed, default: {} },
    nuiPresets: [{ name: String, prefs: Mixed, publishedBy: ObjectId, publishedAt: Date }],
  },
  { ...baseOptions, collection: 'organizations' },
);

// ---------------------------------------------------------------- users
export const UserSchema = orgScoped(
  new Schema(
    {
      email: { type: String, lowercase: true, trim: true },
      phone: { type: String, trim: true }, // E.164
      fullName: { type: String, required: true, trim: true },
      displayName: String,
      username: { type: String, lowercase: true, trim: true },
      photoFileId: ObjectId,
      emailVerified: { type: Boolean, default: false },
      phoneVerified: { type: Boolean, default: false },
      role: { type: String, required: true, default: 'employee' },
      /** Account status. Only `active` may sign in. */
      status: { type: String, enum: ['invited', 'pending', 'active', 'suspended', 'inactive', 'blocked'], default: 'invited' },
      employeeId: { type: ObjectId, ref: 'Employee' },
      timezone: String,
      language: { type: String, default: 'en' },
      googleSub: String,
      appleSub: String,
      passwordHash: { type: String, select: false },
      /** Set when an administrator issued a temporary password: the user must choose their own. */
      mustChangePassword: { type: Boolean, default: false },
      passwordSetAt: Date,
      failedLogins: { type: Number, default: 0 },
      lockedUntil: Date,
      lastLoginAt: Date,
      /** Bumped on any permission change so cached permission sets refresh. */
      permissionsVersion: { type: Number, default: 1 },
      recoveryCodesGeneratedAt: Date,
      invitedBy: ObjectId,
      createdBy: ObjectId,
    },
    baseOptions,
  ),
);
UserSchema.index({ organizationId: 1, email: 1 }, { unique: true, partialFilterExpression: { email: { $type: 'string' } } });
UserSchema.index({ organizationId: 1, phone: 1 }, { unique: true, partialFilterExpression: { phone: { $type: 'string' } } });
UserSchema.index({ organizationId: 1, username: 1 }, { unique: true, partialFilterExpression: { username: { $type: 'string' } } });
UserSchema.index({ googleSub: 1 }, { sparse: true });
UserSchema.index({ appleSub: 1 }, { sparse: true });
UserSchema.index({ email: 1 });

// ---------------------------------------------------------------- sessions and devices
export const SessionSchema = orgScoped(
  new Schema(
    {
      userId: { type: ObjectId, required: true, index: true },
      refreshHash: { type: String, required: true },
      previousRefreshHash: String,
      /** Rotation family: reuse of an old refresh token revokes the whole family. */
      family: { type: String, required: true, index: true },
      deviceId: String,
      deviceName: String,
      userAgent: String,
      ip: String,
      provider: String,
      lastUsedAt: Date,
      expiresAt: { type: Date, required: true },
      revokedAt: Date,
      revokedReason: String,
      reauthAt: Date,
    },
    baseOptions,
  ),
);
SessionSchema.index({ expiresAt: 1 }, { expireAfterSeconds: 7 * 24 * 3600 });

export const DeviceSchema = orgScoped(
  new Schema(
    {
      deviceId: { type: String, required: true },
      userIds: [ObjectId],
      userAgent: String,
      firstSeenAt: Date,
      lastSeenAt: Date,
      trusted: { type: Boolean, default: false },
    },
    baseOptions,
  ),
);
DeviceSchema.index({ organizationId: 1, deviceId: 1 }, { unique: true });

// ---------------------------------------------------------------- OTP (hashed, single use)
export const OtpSchema = new Schema(
  {
    organizationId: { type: ObjectId, index: true },
    channel: { type: String, enum: ['email', 'phone'], required: true },
    identifier: { type: String, required: true },
    purpose: { type: String, enum: ['login', 'reauth', 'recovery', 'verify'], default: 'login' },
    codeHash: { type: String, required: true },
    attempts: { type: Number, default: 0 },
    expiresAt: { type: Date, required: true },
    consumedAt: Date,
    ip: String,
  },
  { ...baseOptions, collection: 'otp_verifications' },
);
OtpSchema.index({ identifier: 1, purpose: 1, createdAt: -1 });
OtpSchema.index({ expiresAt: 1 }, { expireAfterSeconds: 3600 });

// ---------------------------------------------------------------- invitations
export const InvitationSchema = orgScoped(
  new Schema(
    {
      email: { type: String, lowercase: true, trim: true },
      phone: String,
      role: { type: String, required: true },
      userId: ObjectId,
      employeeId: ObjectId,
      tokenHash: { type: String, required: true, index: true },
      status: { type: String, enum: ['pending', 'accepted', 'revoked', 'expired'], default: 'pending' },
      expiresAt: { type: Date, required: true },
      invitedBy: ObjectId,
      acceptedAt: Date,
    },
    baseOptions,
  ),
);

// ---------------------------------------------------------------- recovery codes (hash only)
export const RecoveryCodeSchema = orgScoped(
  new Schema({ userId: { type: ObjectId, required: true, index: true }, codeHash: { type: String, required: true }, usedAt: Date }, baseOptions),
);

// ---------------------------------------------------------------- login history
export const LoginEventSchema = orgScoped(
  new Schema(
    {
      userId: ObjectId,
      identifier: String, // masked
      provider: String,
      outcome: { type: String, enum: ['success', 'failure', 'blocked', 'locked'] },
      reason: String,
      ip: String,
      userAgent: String,
      deviceId: String,
      at: { type: Date, default: Date.now },
    },
    { ...baseOptions, timestamps: false },
  ),
);
LoginEventSchema.index({ organizationId: 1, at: -1 });

// ---------------------------------------------------------------- access
export const RoleSchema = orgScoped(
  new Schema(
    {
      key: { type: String, required: true },
      name: { type: String, required: true },
      description: String,
      grants: { type: [String], default: [] },
      system: { type: Boolean, default: false },
      version: { type: Number, default: 1 },
    },
    baseOptions,
  ),
);
RoleSchema.index({ organizationId: 1, key: 1 }, { unique: true });

export const UserPermissionSchema = orgScoped(
  new Schema(
    {
      userId: { type: ObjectId, required: true, index: true },
      grant: { type: String, required: true },
      recordIds: [String],
      grantedBy: ObjectId,
      reason: String,
      expiresAt: Date,
    },
    baseOptions,
  ),
);
UserPermissionSchema.index({ organizationId: 1, userId: 1, grant: 1 }, { unique: true });

/** Append-only history of every role and permission change. */
export const PermissionChangeSchema = orgScoped(
  new Schema(
    {
      actorId: ObjectId,
      targetUserId: ObjectId,
      roleKey: String,
      change: { type: String, enum: ['role_assigned', 'grant_added', 'grant_removed', 'role_updated', 'feature_toggled'] },
      before: Mixed,
      after: Mixed,
      at: { type: Date, default: Date.now },
    },
    { ...baseOptions, timestamps: false },
  ),
);

// ---------------------------------------------------------------- user preferences (N UI)
export const UserPreferencesSchema = orgScoped(
  new Schema({ userId: { type: ObjectId, required: true }, nui: { type: Mixed, default: {} }, dashboard: { type: Mixed, default: {} } }, baseOptions),
);
UserPreferencesSchema.index({ organizationId: 1, userId: 1 }, { unique: true });

// ---------------------------------------------------------------- idempotency
export const IdempotencyKeySchema = new Schema(
  {
    scope: { type: String, required: true }, // org:user
    key: { type: String, required: true },
    method: String,
    path: String,
    status: { type: String, enum: ['in_progress', 'completed'], default: 'in_progress' },
    responseStatus: Number,
    responseBody: Mixed,
    expiresAt: { type: Date, required: true },
  },
  { ...baseOptions, collection: 'idempotency_keys' },
);
IdempotencyKeySchema.index({ scope: 1, key: 1 }, { unique: true });
IdempotencyKeySchema.index({ expiresAt: 1 }, { expireAfterSeconds: 0 });

// ---------------------------------------------------------------- audit (append-only)
export const AuditLogSchema = new Schema(
  {
    organizationId: { type: ObjectId, index: true },
    actorId: ObjectId,
    actorName: String,
    action: { type: String, required: true },
    resourceType: { type: String, required: true },
    resourceId: String,
    outcome: { type: String, enum: ['success', 'failure', 'denied'], default: 'success' },
    changes: Mixed, // { field: { from, to } } with secrets removed
    correlationId: String,
    sessionId: String,
    ip: String,
    at: { type: Date, default: Date.now },
  },
  { versionKey: false, collection: 'audit_logs' },
);
AuditLogSchema.index({ organizationId: 1, at: -1 });
AuditLogSchema.index({ organizationId: 1, resourceType: 1, resourceId: 1, at: -1 });
AuditLogSchema.index({ organizationId: 1, actorId: 1, at: -1 });
// Audit records are protected from modification.
for (const op of ['updateOne', 'updateMany', 'findOneAndUpdate', 'replaceOne', 'deleteOne', 'deleteMany', 'findOneAndDelete'] as const) {
  AuditLogSchema.pre(op, function () {
    throw new Error('audit_logs are append-only');
  });
}

// ---------------------------------------------------------------- security alerts
export const SecurityAlertSchema = orgScoped(
  new Schema(
    {
      type: { type: String, required: true }, // failed_logins, refresh_reuse, new_super_admin, restore, permission_escalation
      severity: { type: String, enum: ['low', 'medium', 'high', 'critical'], default: 'medium' },
      userId: ObjectId,
      message: String,
      data: Mixed,
      status: { type: String, enum: ['open', 'acknowledged', 'resolved'], default: 'open' },
      resolvedBy: ObjectId,
      resolvedAt: Date,
    },
    baseOptions,
  ),
);
