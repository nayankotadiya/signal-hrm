import { HttpStatus, Injectable } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model } from 'mongoose';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ApiError } from '../../common/errors/api-error';
import { InjectModel, serialize } from '../../database/model';
import { FilesService } from '../files/files.service';
import { JobsService } from '../system/jobs.service';

const EXPORT_TTL_DAYS = 7;

/**
 * Personal data export: a JSON file with the caller's own records. It is stored as an "export"
 * file that only the requester can download, and it expires after seven days.
 * Encrypted fields are never decrypted into the export; only their masked form is included.
 */
@Injectable()
export class PrivacyService {
  constructor(
    private readonly files: FilesService,
    private readonly audit: AuditService,
    private readonly jobs: JobsService,
    @InjectModel('DataExport') private readonly exportsModel: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Attendance') private readonly attendance: Model<any>,
    @InjectModel('LeaveRequest') private readonly leave: Model<any>,
    @InjectModel('LeaveBalance') private readonly balances: Model<any>,
    @InjectModel('Expense') private readonly expenses: Model<any>,
    @InjectModel('Payslip') private readonly payslips: Model<any>,
    @InjectModel('Task') private readonly tasks: Model<any>,
    @InjectModel('UserPreferences') private readonly prefs: Model<any>,
    @InjectModel('NotificationPreference') private readonly notifPrefs: Model<any>,
    @InjectModel('LoginEvent') private readonly logins: Model<any>,
    @InjectModel('Session') private readonly sessions: Model<any>,
    @InjectModel('DocumentAck') private readonly acks: Model<any>,
  ) {}

  async list(ctx: Ctx): Promise<any[]> {
    PermissionsService.require(ctx, 'privacy', 'export');
    return serialize(await this.exportsModel.find({ organizationId: ctx.orgOid, userId: ctx.userOid }).sort({ createdAt: -1 }).limit(20).lean());
  }

  async request(ctx: Ctx): Promise<any> {
    PermissionsService.require(ctx, 'privacy', 'export');
    const recent = await this.exportsModel.findOne({ organizationId: ctx.orgOid, userId: ctx.userOid, status: { $in: ['requested', 'building', 'ready'] }, createdAt: { $gt: new Date(Date.now() - 86400_000) } }).lean<any>();
    if (recent) throw new ApiError(HttpStatus.TOO_MANY_REQUESTS, 'EXPORT_RECENT', 'You already requested an export in the last 24 hours.', undefined, { exportId: String(recent._id) });
    const rec = await this.exportsModel.create({ organizationId: ctx.orgOid, userId: ctx.userOid, status: 'building' });
    await this.audit.record(ctx, { action: 'privacy.export_request', resourceType: 'data_export', resourceId: rec._id });
    try {
      const data = await this.collect(ctx);
      const buffer = Buffer.from(JSON.stringify(data, null, 2), 'utf8');
      const expiresAt = new Date(Date.now() + EXPORT_TTL_DAYS * 86400_000);
      const file = await this.files.storeGenerated(ctx.orgOid, { buffer, name: `signal-hrm-my-data-${new Date().toISOString().slice(0, 10)}.json`, mimeType: 'application/json', purpose: 'export', uploadedBy: ctx.userOid, deleteAfter: expiresAt });
      await this.exportsModel.updateOne({ _id: rec._id }, { $set: { status: 'ready', fileId: file._id, expiresAt } });
    } catch (e) {
      await this.exportsModel.updateOne({ _id: rec._id }, { $set: { status: 'failed', error: 'Export could not be built. Try again later.' } });
      throw e;
    }
    return serialize(await this.exportsModel.findById(rec._id).lean());
  }

  private async collect(ctx: Ctx): Promise<Record<string, unknown>> {
    const o = ctx.orgOid;
    const u = ctx.userOid;
    const e = ctx.employeeOid;
    const byEmp = <T>(p: Promise<T>) => (e ? p : Promise.resolve([] as unknown as T));
    const [user, employee, attendance, leave, balances, expenses, payslips, tasks, prefs, notifPrefs, logins, sessions, acks] = await Promise.all([
      this.users.findOne({ _id: u, organizationId: o }, { passwordHash: 0, failedLogins: 0, lockedUntil: 0, googleSub: 0, appleSub: 0, permissionsVersion: 0 }).lean(),
      e ? this.employees.findOne({ _id: e, organizationId: o }, { 'sensitive.bank.accountNumberEnc': 0, 'sensitive.tax.panEnc': 0, 'sensitive.tax.uanEnc': 0, 'sensitive.exitReason': 0 }).lean() : null,
      byEmp(this.attendance.find({ organizationId: o, employeeId: e }, { 'checkIn.selfieEvidenceId': 0, 'checkOut.selfieEvidenceId': 0, flags: 0 }).sort({ workDate: -1 }).limit(1000).lean()),
      byEmp(this.leave.find({ organizationId: o, employeeId: e }).sort({ startDate: -1 }).lean()),
      byEmp(this.balances.find({ organizationId: o, employeeId: e }).lean()),
      byEmp(this.expenses.find({ organizationId: o, employeeId: e }).sort({ expenseDate: -1 }).lean()),
      byEmp(this.payslips.find({ organizationId: o, employeeId: e, publishedAt: { $ne: null } }, { period: 1, net: 1, publishedAt: 1 }).sort({ period: -1 }).lean()),
      byEmp(this.tasks.find({ organizationId: o, assigneeIds: e }, { title: 1, status: 1, dueDate: 1, priority: 1, createdAt: 1, completedAt: 1 }).lean()),
      this.prefs.findOne({ organizationId: o, userId: u }).lean(),
      this.notifPrefs.find({ organizationId: o, userId: u }).lean(),
      this.logins.find({ organizationId: o, userId: u }, { provider: 1, outcome: 1, ip: 1, userAgent: 1, at: 1 }).sort({ at: -1 }).limit(200).lean(),
      this.sessions.find({ organizationId: o, userId: u }, { refreshHash: 0 }).sort({ createdAt: -1 }).limit(50).lean(),
      byEmp(this.acks.find({ organizationId: o, employeeId: e }).lean()),
    ]);
    return {
      exportedAt: new Date().toISOString(),
      notice: 'This file contains your own records in Signal HRM. Bank and tax numbers are shown masked only. Attendance selfies are not included; ask HR if you need them.',
      account: serialize(user),
      employee: serialize(employee),
      attendance: serialize(attendance),
      leaveRequests: serialize(leave),
      leaveBalances: serialize(balances),
      expenses: serialize(expenses),
      payslips: serialize(payslips),
      tasks: serialize(tasks),
      preferences: serialize(prefs),
      notificationPreferences: serialize(notifPrefs),
      loginHistory: serialize(logins),
      sessions: serialize(sessions),
      policyAcknowledgements: serialize(acks),
    };
  }

  /** Marks exports expired once their file is past its retention. */
  @Cron('15 3 * * *')
  async expire(): Promise<void> {
    await this.jobs.run('privacy.expire_exports', async () => {
      const r = await this.exportsModel.updateMany({ status: { $in: ['ready', 'downloaded'] }, expiresAt: { $lt: new Date() } }, { $set: { status: 'expired' } });
      return `${r.modifiedCount} expired`;
    });
  }
}
