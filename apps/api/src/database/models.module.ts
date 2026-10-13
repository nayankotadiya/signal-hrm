import { Global, Module } from '@nestjs/common';
import * as core from '../schemas/core.schemas';
import * as fin from '../schemas/finance.schemas';
import * as plat from '../schemas/platform.schemas';
import * as time from '../schemas/time.schemas';
import * as work from '../schemas/work.schemas';
import * as wf from '../schemas/workforce.schemas';
import { modelProvider } from './model';

/** Model name -> [schema, collection]. One registry so every module reads the same models. */
export const MODELS = {
  Organization: [core.OrganizationSchema, 'organizations'],
  User: [core.UserSchema, 'users'],
  Session: [core.SessionSchema, 'sessions'],
  Device: [core.DeviceSchema, 'devices'],
  Otp: [core.OtpSchema, 'otp_verifications'],
  Invitation: [core.InvitationSchema, 'invitations'],
  RecoveryCode: [core.RecoveryCodeSchema, 'recovery_codes'],
  LoginEvent: [core.LoginEventSchema, 'login_events'],
  Role: [core.RoleSchema, 'roles'],
  UserPermission: [core.UserPermissionSchema, 'user_permissions'],
  PermissionChange: [core.PermissionChangeSchema, 'permission_changes'],
  UserPreferences: [core.UserPreferencesSchema, 'user_preferences'],
  IdempotencyKey: [core.IdempotencyKeySchema, 'idempotency_keys'],
  AuditLog: [core.AuditLogSchema, 'audit_logs'],
  SecurityAlert: [core.SecurityAlertSchema, 'security_alerts'],

  Employee: [wf.EmployeeSchema, 'employees'],
  EmployeeHistory: [wf.EmployeeHistorySchema, 'employee_history'],
  Checklist: [wf.ChecklistSchema, 'employee_checklists'],
  Department: [wf.DepartmentSchema, 'departments'],
  Team: [wf.TeamSchema, 'teams'],

  Location: [time.LocationSchema, 'locations'],
  Shift: [time.ShiftSchema, 'shifts'],
  ShiftAssignment: [time.ShiftAssignmentSchema, 'shift_assignments'],
  ShiftChangeRequest: [time.ShiftChangeRequestSchema, 'shift_change_requests'],
  Attendance: [time.AttendanceSchema, 'attendance'],
  AttendanceCorrection: [time.AttendanceCorrectionSchema, 'attendance_corrections'],
  AttendanceEvidence: [time.AttendanceEvidenceSchema, 'attendance_evidence'],
  AttendanceFlag: [time.AttendanceFlagSchema, 'attendance_flags'],
  GpsAttempt: [time.GpsAttemptSchema, 'gps_attempts'],
  LeaveType: [time.LeaveTypeSchema, 'leave_types'],
  LeavePolicy: [time.LeavePolicySchema, 'leave_policies'],
  LeaveBalance: [time.LeaveBalanceSchema, 'leave_balances'],
  LeaveLedger: [time.LeaveLedgerSchema, 'leave_ledger'],
  LeaveRequest: [time.LeaveRequestSchema, 'leave_requests'],
  Holiday: [time.HolidaySchema, 'holidays'],
  HrEvent: [time.HrEventSchema, 'hr_events'],
  Announcement: [time.AnnouncementSchema, 'announcements'],

  ExpenseCategory: [fin.ExpenseCategorySchema, 'expense_categories'],
  Expense: [fin.ExpenseSchema, 'expenses'],
  Reimbursement: [fin.ReimbursementSchema, 'reimbursements'],
  SalaryStructure: [fin.SalaryStructureSchema, 'salary_structures'],
  StatutoryRule: [fin.StatutoryRuleSchema, 'statutory_rules'],
  PayrollRun: [fin.PayrollRunSchema, 'payroll_runs'],
  PayrollLine: [fin.PayrollLineSchema, 'payroll'],
  PayrollAdjustment: [fin.PayrollAdjustmentSchema, 'payroll_adjustments'],
  Payslip: [fin.PayslipSchema, 'payslips'],
  TravelRequest: [fin.TravelRequestSchema, 'travel_requests'],

  Task: [work.TaskSchema, 'tasks'],
  TaskComment: [work.TaskCommentSchema, 'task_comments'],
  TaskActivity: [work.TaskActivitySchema, 'task_activities'],
  TaskAttachment: [work.TaskAttachmentSchema, 'task_attachments'],
  Lead: [work.LeadSchema, 'leads'],
  LeadActivity: [work.LeadActivitySchema, 'lead_activities'],
  LeadAssignment: [work.LeadAssignmentSchema, 'lead_assignments'],
  LeadSource: [work.LeadSourceSchema, 'lead_sources'],
  Meeting: [work.MeetingSchema, 'meetings'],
  CallLog: [work.CallLogSchema, 'call_logs'],

  Document: [plat.DocumentSchema, 'documents'],
  DocumentVersion: [plat.DocumentVersionSchema, 'document_versions'],
  DocumentAck: [plat.DocumentAckSchema, 'document_acknowledgements'],
  DocumentAccessLog: [plat.DocumentAccessLogSchema, 'document_access_logs'],
  ApprovalRule: [plat.ApprovalRuleSchema, 'approval_rules'],
  Approval: [plat.ApprovalSchema, 'approvals'],
  ApprovalHistory: [plat.ApprovalHistorySchema, 'approval_history'],
  Delegation: [plat.DelegationSchema, 'delegations'],
  Notification: [plat.NotificationSchema, 'notifications'],
  NotificationPreference: [plat.NotificationPreferenceSchema, 'notification_preferences'],
  NotificationTemplate: [plat.NotificationTemplateSchema, 'notification_templates'],
  NotificationDelivery: [plat.NotificationDeliverySchema, 'notification_deliveries'],
  PushSubscription: [plat.PushSubscriptionSchema, 'push_subscriptions'],
  Folder: [plat.FolderSchema, 'folders'],
  File: [plat.FileSchema, 'files'],
  FileVersion: [plat.FileVersionSchema, 'file_versions'],
  BackupRecord: [plat.BackupRecordSchema, 'backup_records'],
  RestoreRecord: [plat.RestoreRecordSchema, 'restore_records'],
  ModerationReport: [plat.ModerationReportSchema, 'moderation_reports'],
  ModerationAction: [plat.ModerationActionSchema, 'moderation_actions'],
  IntegrationConnection: [plat.IntegrationConnectionSchema, 'integration_connections'],
  IntegrationSyncLog: [plat.IntegrationSyncLogSchema, 'integration_sync_logs'],
  SavedReport: [plat.SavedReportSchema, 'reports'],
  ReportSnapshot: [plat.ReportSnapshotSchema, 'report_snapshots'],
  DataExport: [plat.DataExportSchema, 'data_exports'],
  JobRun: [plat.JobRunSchema, 'job_runs'],
  ErrorLog: [plat.ErrorLogSchema, 'error_logs'],
  RequestMetric: [plat.RequestMetricSchema, 'request_metrics'],
  Snooze: [plat.SnoozeSchema, 'snoozes'],
} as const;

export type ModelName = keyof typeof MODELS;

const providers = (Object.keys(MODELS) as ModelName[]).map((name) => modelProvider(name, MODELS[name][0], MODELS[name][1]));

@Global()
@Module({ providers, exports: providers })
export class ModelsModule {}
