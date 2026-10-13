import { Schema } from 'mongoose';
import { baseOptions, orgScoped } from '../database/model';

const { ObjectId, Mixed } = Schema.Types;

// ---------------------------------------------------------------- documents and policies
export const DocumentSchema = orgScoped(
  new Schema(
    {
      title: { type: String, required: true, trim: true },
      category: { type: String, default: 'general' }, // policy, contract, id_proof, letter, certificate, general
      isPolicy: { type: Boolean, default: false, index: true },
      ownerUserId: ObjectId,
      relatedEmployeeId: { type: ObjectId, index: true },
      currentVersion: { type: Number, default: 1 },
      currentFileId: ObjectId,
      mimeType: String,
      sizeBytes: Number,
      checksum: String,
      /** organization | departments | employees | private (owner + related employee + documents managers) */
      access: {
        scope: { type: String, enum: ['organization', 'departments', 'employees', 'private'], default: 'private' },
        departmentIds: [ObjectId],
        employeeIds: [ObjectId],
      },
      expiryDate: { type: String, index: true },
      requiresAcknowledgement: { type: Boolean, default: false },
      retention: { type: String, enum: ['standard', 'legal_hold', 'delete_after_exit', 'permanent'], default: 'standard' },
      status: { type: String, enum: ['active', 'archived'], default: 'active' },
      uploadedBy: ObjectId,
      tags: [String],
    },
    baseOptions,
  ),
);

export const DocumentVersionSchema = orgScoped(
  new Schema(
    {
      documentId: { type: ObjectId, required: true, index: true },
      version: { type: Number, required: true },
      fileId: { type: ObjectId, required: true },
      mimeType: String,
      sizeBytes: Number,
      checksum: String,
      note: String,
      uploadedBy: ObjectId,
    },
    { ...baseOptions, collection: 'document_versions' },
  ),
);
DocumentVersionSchema.index({ organizationId: 1, documentId: 1, version: 1 }, { unique: true });

export const DocumentAckSchema = orgScoped(
  new Schema(
    { documentId: { type: ObjectId, required: true }, version: Number, employeeId: { type: ObjectId, required: true }, acknowledgedAt: Date, assignedAt: Date },
    { ...baseOptions, collection: 'document_acknowledgements' },
  ),
);
DocumentAckSchema.index({ organizationId: 1, documentId: 1, employeeId: 1, version: 1 }, { unique: true });

export const DocumentAccessLogSchema = orgScoped(
  new Schema(
    { documentId: { type: ObjectId, required: true, index: true }, userId: ObjectId, action: { type: String, enum: ['view', 'download', 'share', 'denied'] }, at: { type: Date, default: Date.now }, ip: String },
    { ...baseOptions, timestamps: false, collection: 'document_access_logs' },
  ),
);

// ---------------------------------------------------------------- approvals
const StageSchema = new Schema(
  {
    name: { type: String, required: true },
    /** Who approves: reporting manager, department head, holders of a role, specific users. */
    approverType: { type: String, enum: ['manager', 'department_head', 'role', 'users', 'permission'], required: true },
    role: String,
    permission: String, // e.g. "payroll:approve" = everyone holding that grant
    userIds: [ObjectId],
    /** sequential: one approver; parallel_any: first of several; parallel_all: everyone must approve. */
    mode: { type: String, enum: ['single', 'parallel_any', 'parallel_all'], default: 'single' },
    /** Only run this stage when the condition matches, e.g. { field: 'amount', op: 'gt', value: 5000 }. */
    condition: { field: String, op: { type: String, enum: ['gt', 'gte', 'lt', 'lte', 'eq', 'ne', 'in'] }, value: Mixed },
    dueHours: { type: Number, default: 48 },
    escalateTo: { type: String, enum: ['none', 'manager_of_approver', 'role', 'users'], default: 'none' },
    escalateRole: String,
    escalateUserIds: [ObjectId],
  },
  { _id: false },
);

export const ApprovalRuleSchema = orgScoped(
  new Schema(
    {
      requestType: { type: String, required: true }, // leave, expense, travel, payroll, attendance_correction, shift_change, onboarding, offboarding, salary_change, role_change
      name: String,
      priority: { type: Number, default: 0 }, // higher wins when several match
      match: { departmentIds: [ObjectId], minAmount: Number, maxAmount: Number, leaveTypeIds: [ObjectId] },
      stages: { type: [StageSchema], default: [] },
      preventSelfApproval: { type: Boolean, default: true },
      requireRejectComment: { type: Boolean, default: false },
      active: { type: Boolean, default: true },
      updatedBy: ObjectId,
    },
    { ...baseOptions, collection: 'approval_rules' },
  ),
);

const StageStateSchema = new Schema(
  {
    name: String,
    mode: String,
    approverIds: [ObjectId], // resolved user ids
    decisions: [{ _id: false, userId: ObjectId, onBehalfOf: ObjectId, decision: String, comment: String, at: Date }],
    status: { type: String, enum: ['waiting', 'active', 'approved', 'rejected', 'skipped'], default: 'waiting' },
    dueAt: Date,
    escalatedAt: Date,
    escalationLevel: { type: Number, default: 0 },
  },
  { _id: false },
);

export const ApprovalSchema = orgScoped(
  new Schema(
    {
      requestType: { type: String, required: true },
      requestId: { type: ObjectId, required: true },
      requestedBy: { type: ObjectId, required: true }, // user id
      subjectEmployeeId: ObjectId,
      title: String,
      summary: String,
      amount: Number,
      ruleId: ObjectId,
      stages: { type: [StageStateSchema], default: [] },
      currentStage: { type: Number, default: 0 },
      currentApproverIds: { type: [ObjectId], index: true },
      status: { type: String, enum: ['pending', 'approved', 'rejected', 'cancelled', 'clarification'], default: 'pending', index: true },
      escalated: { type: Boolean, default: false },
      dueAt: Date,
      decidedAt: Date,
      decisionComment: String,
    },
    baseOptions,
  ),
);
ApprovalSchema.index({ organizationId: 1, requestType: 1, requestId: 1 }, { unique: true });

/** Append-only decision history. Unique decision key = idempotent processing. */
export const ApprovalHistorySchema = orgScoped(
  new Schema(
    {
      approvalId: { type: ObjectId, required: true, index: true },
      stage: Number,
      actorId: ObjectId,
      onBehalfOf: ObjectId,
      action: { type: String, enum: ['submitted', 'approved', 'rejected', 'clarification', 'resubmitted', 'cancelled', 'escalated', 'delegated', 'reminded', 'skipped'] },
      comment: String,
      decisionKey: String,
      at: { type: Date, default: Date.now },
    },
    { ...baseOptions, timestamps: false, collection: 'approval_history' },
  ),
);
ApprovalHistorySchema.index({ organizationId: 1, decisionKey: 1 }, { unique: true, partialFilterExpression: { decisionKey: { $type: 'string' } } });

export const DelegationSchema = orgScoped(
  new Schema(
    {
      fromUserId: { type: ObjectId, required: true, index: true },
      toUserId: { type: ObjectId, required: true },
      requestTypes: [String], // empty = all
      startsAt: { type: Date, required: true },
      endsAt: { type: Date, required: true }, // delegation always expires
      reason: String,
      active: { type: Boolean, default: true },
    },
    baseOptions,
  ),
);

// ---------------------------------------------------------------- notifications
export const NotificationSchema = orgScoped(
  new Schema(
    {
      userId: { type: ObjectId, required: true },
      event: { type: String, required: true },
      title: { type: String, required: true },
      body: String,
      link: String, // deep link in the app, e.g. /approvals/123
      priority: { type: String, enum: ['normal', 'high', 'essential'], default: 'normal' },
      readAt: Date,
      data: Mixed,
    },
    baseOptions,
  ),
);
NotificationSchema.index({ organizationId: 1, userId: 1, createdAt: -1 });
NotificationSchema.index({ createdAt: 1 }, { expireAfterSeconds: 180 * 24 * 3600 });

export const NotificationPreferenceSchema = orgScoped(
  new Schema({ userId: { type: ObjectId, required: true }, channels: { type: Mixed, default: {} } }, { ...baseOptions, collection: 'notification_preferences' }),
);
NotificationPreferenceSchema.index({ organizationId: 1, userId: 1 }, { unique: true });

export const NotificationTemplateSchema = orgScoped(
  new Schema(
    { event: { type: String, required: true }, channel: { type: String, enum: ['in_app', 'email', 'push', 'whatsapp', 'sms'], required: true }, subject: String, body: { type: String, required: true }, active: { type: Boolean, default: true } },
    { ...baseOptions, collection: 'notification_templates' },
  ),
);
NotificationTemplateSchema.index({ organizationId: 1, event: 1, channel: 1 }, { unique: true });

/** Delivery tracking without storing message content (no sensitive data in logs). */
export const NotificationDeliverySchema = orgScoped(
  new Schema(
    {
      notificationId: ObjectId,
      userId: ObjectId,
      event: String,
      channel: String,
      status: { type: String, enum: ['queued', 'sent', 'failed', 'skipped'], default: 'queued' },
      attempts: { type: Number, default: 0 },
      error: String,
      sentAt: Date,
      nextAttemptAt: Date,
    },
    { ...baseOptions, collection: 'notification_deliveries' },
  ),
);
NotificationDeliverySchema.index({ status: 1, nextAttemptAt: 1 });

export const PushSubscriptionSchema = orgScoped(
  new Schema({ userId: { type: ObjectId, required: true, index: true }, endpoint: { type: String, required: true }, keys: Mixed, userAgent: String }, { ...baseOptions, collection: 'push_subscriptions' }),
);

// ---------------------------------------------------------------- files and storage
export const FolderSchema = orgScoped(
  new Schema({ name: { type: String, required: true }, parentId: ObjectId, path: String, createdBy: ObjectId }, baseOptions),
);

export const FileSchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true },
      folderId: ObjectId,
      purpose: { type: String, default: 'general' }, // document, receipt, selfie, avatar, payslip, backup, export, attachment
      provider: String,
      providerFileId: String,
      mimeType: String,
      sizeBytes: Number,
      checksum: String,
      version: { type: Number, default: 1 },
      uploadedBy: ObjectId,
      ownerEmployeeId: ObjectId,
      /** Which record controls access (download checks permission on that record). */
      linked: { type: { type: String }, id: ObjectId },
      status: { type: String, enum: ['uploading', 'stored', 'failed', 'deleted'], default: 'uploading' },
      error: String,
      deleteAfter: Date,
    },
    baseOptions,
  ),
);
FileSchema.index({ organizationId: 1, status: 1 });
FileSchema.index({ organizationId: 1, 'linked.type': 1, 'linked.id': 1 });

export const FileVersionSchema = orgScoped(
  new Schema({ fileId: { type: ObjectId, required: true, index: true }, version: Number, providerFileId: String, sizeBytes: Number, checksum: String, uploadedBy: ObjectId }, { ...baseOptions, collection: 'file_versions' }),
);

// ---------------------------------------------------------------- backups
export const BackupRecordSchema = new Schema(
  {
    kind: { type: String, enum: ['daily', 'weekly', 'monthly', 'manual', 'pre_deployment', 'pre_restore'], required: true },
    status: { type: String, enum: ['running', 'uploaded', 'verified', 'failed', 'deleted'], default: 'running', index: true },
    startedAt: Date,
    finishedAt: Date,
    sizeBytes: Number,
    checksum: String, // sha256 of the archive
    provider: String,
    providerFileId: String,
    verifiedAt: Date,
    verification: { exists: Boolean, sizeMatches: Boolean, checksumMatches: Boolean, archiveReadable: Boolean },
    error: String,
    triggeredBy: Schema.Types.ObjectId,
    restoreTestedAt: Date,
  },
  { ...baseOptions, collection: 'backup_records' },
);

export const RestoreRecordSchema = new Schema(
  {
    backupId: { type: ObjectId, required: true },
    safetyBackupId: ObjectId,
    requestedBy: ObjectId,
    status: { type: String, enum: ['preparing', 'restoring', 'checking', 'completed', 'failed'], default: 'preparing' },
    healthAfter: Mixed,
    error: String,
    startedAt: Date,
    finishedAt: Date,
  },
  { ...baseOptions, collection: 'restore_records' },
);

// ---------------------------------------------------------------- moderation
export const ModerationReportSchema = orgScoped(
  new Schema(
    {
      reporterId: ObjectId,
      contentType: { type: String, enum: ['announcement', 'kudos', 'task_comment', 'document', 'profile', 'file', 'other'], required: true },
      contentId: ObjectId,
      reportedUserId: ObjectId,
      reason: { type: String, required: true },
      severity: { type: String, enum: ['low', 'medium', 'high', 'critical'], default: 'medium' },
      context: Mixed, // minimal snapshot needed for review
      assignedModeratorId: ObjectId,
      status: { type: String, enum: ['open', 'in_review', 'actioned', 'dismissed', 'escalated'], default: 'open', index: true },
      action: String,
      decisionNotes: String,
      escalatedTo: ObjectId,
      resolvedAt: Date,
    },
    { ...baseOptions, collection: 'moderation_reports' },
  ),
);

export const ModerationActionSchema = orgScoped(
  new Schema(
    {
      reportId: ObjectId,
      moderatorId: ObjectId,
      targetUserId: ObjectId,
      action: { type: String, enum: ['dismiss', 'warn', 'hide_content', 'restrict', 'escalate', 'restore'], required: true },
      notes: String,
      expiresAt: Date,
    },
    { ...baseOptions, collection: 'moderation_actions' },
  ),
);

// ---------------------------------------------------------------- integrations
export const IntegrationConnectionSchema = orgScoped(
  new Schema(
    {
      provider: { type: String, required: true }, // meta_leads, whatsapp, sms, google_calendar
      name: String,
      status: { type: String, enum: ['connected', 'error', 'disabled', 'expired'], default: 'disabled' },
      tokenEnc: String, // AES-GCM encrypted
      tokenExpiresAt: Date,
      config: Mixed, // non-secret settings (page id, form ids, default owner)
      lastSyncAt: Date,
      lastError: String,
      verifiedAt: Date,
    },
    { ...baseOptions, collection: 'integration_connections' },
  ),
);
IntegrationConnectionSchema.index({ organizationId: 1, provider: 1 }, { unique: true });

export const IntegrationSyncLogSchema = orgScoped(
  new Schema(
    {
      connectionId: ObjectId,
      provider: String,
      direction: { type: String, enum: ['inbound', 'outbound'] },
      externalId: String,
      outcome: { type: String, enum: ['created', 'duplicate', 'failed', 'retrying', 'ignored'] },
      attempts: { type: Number, default: 1 },
      error: String,
      at: { type: Date, default: Date.now },
    },
    { ...baseOptions, timestamps: false, collection: 'integration_sync_logs' },
  ),
);
IntegrationSyncLogSchema.index({ organizationId: 1, at: -1 });

// ---------------------------------------------------------------- reports
export const SavedReportSchema = orgScoped(
  new Schema(
    {
      ownerId: ObjectId,
      name: { type: String, required: true },
      reportKey: { type: String, required: true },
      filters: Mixed,
      chart: String,
      fields: [String],
      pinned: { type: Boolean, default: false },
      schedule: { cron: String, emailTo: [String], format: String },
      lastRunAt: Date,
    },
    { ...baseOptions, collection: 'reports' },
  ),
);

export const ReportSnapshotSchema = orgScoped(
  new Schema({ reportId: ObjectId, reportKey: String, filters: Mixed, rows: Mixed, generatedBy: ObjectId, fileId: ObjectId }, { ...baseOptions, collection: 'report_snapshots' }),
);

// ---------------------------------------------------------------- privacy exports
export const DataExportSchema = orgScoped(
  new Schema(
    {
      userId: { type: ObjectId, required: true },
      status: { type: String, enum: ['requested', 'building', 'ready', 'downloaded', 'expired', 'failed'], default: 'requested' },
      fileId: ObjectId,
      expiresAt: Date,
      downloadedAt: Date,
      error: String,
    },
    { ...baseOptions, collection: 'data_exports' },
  ),
);

// ---------------------------------------------------------------- jobs, errors, snoozes
export const JobRunSchema = new Schema(
  {
    job: { type: String, required: true, index: true },
    status: { type: String, enum: ['running', 'succeeded', 'failed'], default: 'running' },
    startedAt: { type: Date, default: Date.now },
    finishedAt: Date,
    durationMs: Number,
    detail: String,
    error: String,
  },
  { versionKey: false, collection: 'job_runs' },
);
JobRunSchema.index({ startedAt: 1 }, { expireAfterSeconds: 30 * 24 * 3600 });

export const ErrorLogSchema = new Schema(
  {
    organizationId: ObjectId,
    correlationId: String,
    method: String,
    path: String,
    status: Number,
    code: String,
    message: String, // generic; stack only in server logs
    at: { type: Date, default: Date.now },
  },
  { versionKey: false, collection: 'error_logs' },
);
ErrorLogSchema.index({ at: 1 }, { expireAfterSeconds: 30 * 24 * 3600 });

export const RequestMetricSchema = new Schema(
  { minute: { type: Date, required: true }, count: Number, errors: Number, totalMs: Number, maxMs: Number, p95Ms: Number },
  { versionKey: false, collection: 'request_metrics', suppressReservedKeysWarning: true },
);
RequestMetricSchema.index({ minute: 1 }, { unique: true, expireAfterSeconds: 14 * 24 * 3600 });

/** Snoozed needs-attention items (audited). */
export const SnoozeSchema = orgScoped(
  new Schema({ userId: ObjectId, itemKey: { type: String, required: true }, until: Date, reason: { type: String, required: true } }, baseOptions),
);
SnoozeSchema.index({ organizationId: 1, userId: 1, itemKey: 1 }, { unique: true });
