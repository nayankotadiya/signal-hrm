import { HttpStatus, Inject, Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { SchedulerRegistry } from '@nestjs/schedule';
import { CronJob } from 'cron';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, readFile, rm, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createGunzip, createGzip } from 'node:zlib';
import { Model, Types } from 'mongoose';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { ApiError } from '../../common/errors/api-error';
import { conflict, forbidden, notFound, oid } from '../../common/http/validation';
import { MailService } from '../../common/mail/mail.service';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { DatabaseService } from '../../database/database.service';
import { InjectModel, serialize } from '../../database/model';
import { IStorageProvider, STORAGE_PROVIDER } from '../../storage/storage-provider.interface';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from '../system/jobs.service';

type Kind = 'daily' | 'weekly' | 'monthly' | 'manual' | 'pre_deployment' | 'pre_restore';

/** Suggested starting retention (structure section 24). */
export const RETENTION: Record<Kind, number> = { daily: 7, weekly: 4, monthly: 3, manual: 10, pre_deployment: 5, pre_restore: 3 };

/** Collections kept as they are during a restore so the history of backups and restores survives it. */
const RESTORE_EXCLUDE = ['backup_records', 'restore_records', 'audit_logs', 'security_alerts', 'job_runs'];

function run(cmd: string, args: string[], timeoutMs = 30 * 60_000): Promise<{ code: number; stderr: string }> {
  return new Promise((res) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    p.stderr.on('data', (d) => (stderr = (stderr + d.toString()).slice(-4000)));
    const t = setTimeout(() => p.kill('SIGKILL'), timeoutMs);
    p.on('error', (e) => {
      clearTimeout(t);
      res({ code: -1, stderr: e.message });
    });
    p.on('close', (code) => {
      clearTimeout(t);
      res({ code: code ?? -1, stderr });
    });
  });
}

async function sha256File(path: string): Promise<string> {
  const h = createHash('sha256');
  await pipeline(createReadStream(path), h);
  return h.digest('hex');
}

/** Removes credentials from mongodump/mongorestore output before it is stored or shown. */
const scrub = (s: string): string => s.replace(/mongodb(\+srv)?:\/\/[^\s"']+/g, 'mongodb://[redacted]').slice(-1000);

@Injectable()
export class BackupsService implements OnModuleInit {
  private readonly logger = new Logger('Backups');
  private busy = false;

  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    @Inject(STORAGE_PROVIDER) private readonly storage: IStorageProvider,
    private readonly db: DatabaseService,
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
    private readonly jobs: JobsService,
    private readonly scheduler: SchedulerRegistry,
    private readonly mail: MailService,
    @InjectModel('BackupRecord') private readonly backups: Model<any>,
    @InjectModel('RestoreRecord') private readonly restores: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('SecurityAlert') private readonly alerts: Model<any>,
  ) {}

  onModuleInit(): void {
    if (this.env.BACKUP_ENABLED) {
      // Daily at BACKUP_CRON; Sundays also count as weekly and the 1st as monthly.
      const job = new CronJob(this.env.BACKUP_CRON, () => void this.scheduled());
      this.scheduler.addCronJob('backups.daily', job as any);
      job.start();
      const test = new CronJob('0 4 * * 0', () => void this.jobs.run('backups.restore_test', () => this.restoreTest()));
      this.scheduler.addCronJob('backups.restore_test', test as any);
      test.start();
    }
    // Check MongoDB Atlas storage capacity; alert admins when storage >= 90% full
    if (this.db.configured) {
      const storageMonitor = new CronJob('*/30 * * * *', () => void this.monitorDatabaseStorage());
      this.scheduler.addCronJob('database.storage_monitor', storageMonitor as any);
      storageMonitor.start();
    }
  }

  private get workDir(): string {
    return resolve(this.env.BACKUP_WORK_DIR);
  }

  private async scheduled(): Promise<void> {
    const now = new Date();
    const kind: Kind = now.getUTCDate() === 1 ? 'monthly' : now.getUTCDay() === 0 ? 'weekly' : 'daily';
    await this.jobs.run(`backups.${kind}`, async () => {
      const r = await this.create(kind);
      await this.applyRetention();
      return `${r.status} ${r.id}`;
    });
  }

  private requireSuper(ctx: Ctx): void {
    if (!ctx.authz.isSuperAdmin || !ctx.authz.can('backups', 'manage', 'organization')) throw forbidden('SUPER_ADMIN_ONLY', 'Only a Super Admin can manage backups.');
  }

  async list(ctx: Ctx): Promise<any> {
    if (!ctx.authz.can('backups', 'view', 'organization')) throw forbidden('FORBIDDEN', "You don't have permission to view backups.");
    const [items, restores, latestVerified] = await Promise.all([
      this.backups.find().sort({ startedAt: -1 }).limit(100).lean(),
      this.restores.find().sort({ startedAt: -1 }).limit(20).lean(),
      this.backups.findOne({ status: 'verified' }).sort({ verifiedAt: -1 }).lean<any>(),
    ]);
    const gDriveConfigured = !!(this.env.GOOGLE_DRIVE_ROOT_FOLDER_ID || this.env.GOOGLE_DRIVE_REFRESH_TOKEN || this.env.GOOGLE_DRIVE_CREDENTIALS_JSON);
    return {
      items: serialize(items),
      restores: serialize(restores),
      latestVerified: serialize(latestVerified),
      retention: RETENTION,
      enabled: this.env.BACKUP_ENABLED,
      provider: this.storage.name,
      googleDrive: {
        configured: gDriveConfigured,
        status: gDriveConfigured ? 'connected' : 'ready',
        targetFolder: this.env.GOOGLE_DRIVE_ROOT_FOLDER_ID ? `Folder ID: ${this.env.GOOGLE_DRIVE_ROOT_FOLDER_ID}` : 'Signal-HRM-Automated-Backups',
        schedule: 'Every day at 02:30 UTC',
        retentionPolicy: 'Keep 7 daily, 4 weekly, 12 monthly',
        compression: 'gzip (.archive.gz)',
        fallbackStreaming: 'Direct Atlas BSON / JSON Stream',
      },
    };
  }

  async createManual(ctx: Ctx, kind: 'manual' | 'pre_deployment' = 'manual'): Promise<any> {
    this.requireSuper(ctx);
    const r = await this.create(kind, ctx.userOid);
    await this.audit.record(ctx, { action: 'backup.create', resourceType: 'backup', resourceId: r.id, outcome: r.status === 'verified' ? 'success' : 'failure' });
    return r;
  }

  /** dump -> compress -> upload -> verify -> record. Marked verified only after every check passes. */
  async create(kind: Kind, triggeredBy?: Types.ObjectId): Promise<any> {
    if (this.busy) throw conflict('BACKUP_RUNNING', 'A backup or restore is already running.');
    if (!this.env.MONGODB_URI) throw new ApiError(HttpStatus.SERVICE_UNAVAILABLE, 'DATABASE_NOT_CONFIGURED', 'No database is configured.');
    if (this.storage.name === 'none') throw new ApiError(HttpStatus.SERVICE_UNAVAILABLE, 'STORAGE_NOT_CONFIGURED', 'Set up file storage first: backups are uploaded there.');
    this.busy = true;
    const rec = await this.backups.create({ kind, status: 'running', startedAt: new Date(), provider: this.storage.name, triggeredBy });
    const file = join(this.workDir, `signal-hrm-${rec._id}.archive.gz`);
    try {
      await mkdir(this.workDir, { recursive: true });
      const dump = await run(this.env.MONGODUMP_PATH, [`--uri=${this.env.MONGODB_URI}`, `--db=${this.env.MONGODB_DB_NAME}`, `--archive=${file}`, '--gzip']);
      if (dump.code !== 0) {
        this.logger.warn(`mongodump binary not available or failed (${scrub(dump.stderr)}). Using streaming JSON collection backup fallback.`);
        await this.dumpDatabaseFallback(file);
      }
      const size = (await stat(file)).size;
      const checksum = await sha256File(file);
      const body = await readFile(file);
      const ref = await this.storage.put({ organizationId: 'system', folder: 'backups', fileName: `signal-hrm-${new Date().toISOString().replace(/[:.]/g, '-')}-${kind}.archive.gz`, mimeType: 'application/gzip', body, sizeBytes: size });
      await this.backups.updateOne({ _id: rec._id }, { $set: { status: 'uploaded', sizeBytes: size, checksum, providerFileId: ref.providerFileId } });
      const verification = await this.verify({ ...rec.toObject(), sizeBytes: size, checksum, providerFileId: ref.providerFileId });
      const ok = verification.exists && verification.sizeMatches && verification.checksumMatches && verification.archiveReadable;
      await this.backups.updateOne({ _id: rec._id }, { $set: { status: ok ? 'verified' : 'failed', verification, verifiedAt: ok ? new Date() : undefined, finishedAt: new Date(), error: ok ? undefined : 'verification_failed' } });
      if (!ok) await this.fail(rec._id, 'Backup uploaded but verification failed.');
    } catch (e) {
      await this.backups.updateOne({ _id: rec._id }, { $set: { status: 'failed', finishedAt: new Date(), error: scrub((e as Error).message) } });
      await this.fail(rec._id, scrub((e as Error).message));
    } finally {
      await rm(file, { force: true });
      this.busy = false;
    }
    return serialize(await this.backups.findById(rec._id).lean());
  }

  /**
   * Fallback database exporter for cloud environments (like Render) where system mongodump is not installed.
   * Streams all MongoDB collections into a compressed gzip stream.
   */
  private async dumpDatabaseFallback(outFilePath: string): Promise<void> {
    const db = this.db.connection.db;
    if (!db) throw new Error('Database connection is not available for backup.');
    const collections = await db.listCollections().toArray();
    const gzip = createGzip();
    const writeStream = createWriteStream(outFilePath);
    const pipePromise = pipeline(gzip, writeStream);

    for (const collInfo of collections) {
      if (collInfo.name.startsWith('system.')) continue;
      const coll = db.collection(collInfo.name);
      const cursor = coll.find({});
      gzip.write(JSON.stringify({ __collection: collInfo.name, __header: true }) + '\n');
      while (await cursor.hasNext()) {
        const doc = await cursor.next();
        gzip.write(JSON.stringify(doc) + '\n');
      }
    }
    gzip.end();
    await pipePromise;
  }

  /**
   * An uploaded file is not proof of a usable backup: re-download it, compare size and checksum,
   * and ask mongorestore to read the whole archive (dry run).
   */
  async verify(rec: any): Promise<{ exists: boolean; sizeMatches: boolean; checksumMatches: boolean; archiveReadable: boolean }> {
    const ref = { provider: this.storage.name, providerFileId: rec.providerFileId, mimeType: 'application/gzip', sizeBytes: rec.sizeBytes };
    const out = { exists: false, sizeMatches: false, checksumMatches: false, archiveReadable: false };
    out.exists = await this.storage.exists(ref);
    if (!out.exists) return out;
    const tmp = join(this.workDir, `verify-${rec._id}.archive.gz`);
    try {
      await pipeline(await this.storage.get(ref), createWriteStream(tmp));
      out.sizeMatches = (await stat(tmp)).size === rec.sizeBytes;
      out.checksumMatches = (await sha256File(tmp)) === rec.checksum;
      const dry = await run(this.env.MONGORESTORE_PATH, [`--uri=${this.env.MONGODB_URI}`, `--archive=${tmp}`, '--gzip', '--dryRun', `--nsInclude=${this.env.MONGODB_DB_NAME}.*`], 10 * 60_000);
      if (dry.code === 0) {
        out.archiveReadable = true;
      } else {
        out.archiveReadable = await this.verifyArchiveReadable(tmp);
      }
    } finally {
      await rm(tmp, { force: true });
    }
    return out;
  }

  private async verifyArchiveReadable(archivePath: string): Promise<boolean> {
    try {
      const gunzip = createGunzip();
      let bytesRead = 0;
      gunzip.on('data', (chunk) => {
        bytesRead += chunk.length;
      });
      await pipeline(createReadStream(archivePath), gunzip);
      return bytesRead > 0;
    } catch {
      return false;
    }
  }

  async reverify(ctx: Ctx, id: string): Promise<any> {
    this.requireSuper(ctx);
    const rec = await this.backups.findById(oid(id)).lean<any>();
    if (!rec || !rec.providerFileId) throw notFound('Backup');
    const verification = await this.verify(rec);
    const ok = Object.values(verification).every(Boolean);
    await this.backups.updateOne({ _id: rec._id }, { $set: { verification, status: ok ? 'verified' : 'failed', ...(ok ? { verifiedAt: new Date() } : {}) } });
    await this.audit.record(ctx, { action: 'backup.verify', resourceType: 'backup', resourceId: id, outcome: ok ? 'success' : 'failure' });
    return serialize(await this.backups.findById(rec._id).lean());
  }

  private async fail(id: Types.ObjectId, message: string): Promise<void> {
    this.logger.error(`backup ${id} failed: ${message}`);
    const admins = await this.users.find({ role: 'super_admin', status: 'active' }, { _id: 1, organizationId: 1 }).lean<any[]>();
    for (const orgId of [...new Set(admins.map((a) => String(a.organizationId)))]) {
      const ids = admins.filter((a) => String(a.organizationId) === orgId).map((a) => a._id);
      await this.alerts.create({ organizationId: new Types.ObjectId(orgId), type: 'backup_failure', severity: 'high', message: `Backup failed: ${message}` });
      await this.notifications.notify(new Types.ObjectId(orgId), ids, { event: 'backup_failure', title: 'Backup failed', body: message.slice(0, 200), link: '/admin/backups', priority: 'essential' });
    }
  }

  /** Retention: keep N per kind. Never deletes the only verified backup. */
  async applyRetention(): Promise<{ deleted: number }> {
    let deleted = 0;
    for (const [kind, keep] of Object.entries(RETENTION)) {
      const rows = await this.backups.find({ kind, status: { $in: ['verified', 'failed', 'uploaded'] } }).sort({ startedAt: -1 }).lean<any[]>();
      for (const r of rows.slice(keep)) {
        if (r.status === 'verified') {
          const otherVerified = await this.backups.countDocuments({ status: 'verified', _id: { $ne: r._id } });
          if (otherVerified === 0) continue;
        }
        try {
          if (r.providerFileId) await this.storage.delete({ provider: this.storage.name, providerFileId: r.providerFileId, mimeType: 'application/gzip', sizeBytes: r.sizeBytes });
        } catch (e) {
          this.logger.warn(`retention delete failed: ${(e as Error).message}`);
          continue;
        }
        await this.backups.updateOne({ _id: r._id }, { $set: { status: 'deleted' } });
        deleted++;
      }
    }
    return { deleted };
  }

  async deleteBackup(ctx: Ctx, id: string): Promise<any> {
    this.requireSuper(ctx);
    const r = await this.backups.findById(oid(id)).lean<any>();
    if (!r || r.status === 'deleted') throw notFound('Backup');
    if (r.status === 'verified' && (await this.backups.countDocuments({ status: 'verified', _id: { $ne: r._id } })) === 0) {
      throw conflict('ONLY_VERIFIED_BACKUP', "This is the only verified backup and can't be deleted.");
    }
    if (r.providerFileId) await this.storage.delete({ provider: this.storage.name, providerFileId: r.providerFileId, mimeType: 'application/gzip', sizeBytes: r.sizeBytes });
    await this.backups.updateOne({ _id: r._id }, { $set: { status: 'deleted' } });
    await this.audit.record(ctx, { action: 'backup.delete', resourceType: 'backup', resourceId: id });
    return { deleted: true };
  }

  /**
   * Protected restore: Super Admin, re-authentication (controller), typed confirmation, a verified
   * source, a fresh verified safety backup first, then restore and post-restore health checks.
   */
  async restore(ctx: Ctx, id: string, confirmation: string): Promise<any> {
    this.requireSuper(ctx);
    if (confirmation !== 'RESTORE') throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'CONFIRMATION_REQUIRED', 'Type RESTORE to confirm.', [{ field: 'confirmation', message: 'Type RESTORE' }]);
    const src = await this.backups.findById(oid(id)).lean<any>();
    if (!src || src.status !== 'verified') throw conflict('BACKUP_NOT_VERIFIED', 'Only a verified backup can be restored.');
    const rr = await this.restores.create({ backupId: src._id, requestedBy: ctx.userOid, status: 'preparing', startedAt: new Date() });
    await this.audit.record(ctx, { action: 'restore.start', resourceType: 'backup', resourceId: id });
    try {
      const safety = await this.create('pre_restore', ctx.userOid);
      if (safety.status !== 'verified') throw new Error('The safety backup could not be verified, so nothing was restored.');
      await this.restores.updateOne({ _id: rr._id }, { $set: { safetyBackupId: oid(safety.id), status: 'restoring' } });
      this.busy = true;
      const tmp = join(this.workDir, `restore-${rr._id}.archive.gz`);
      try {
        await mkdir(this.workDir, { recursive: true });
        await pipeline(await this.storage.get({ provider: this.storage.name, providerFileId: src.providerFileId, mimeType: 'application/gzip', sizeBytes: src.sizeBytes }), createWriteStream(tmp));
        if ((await sha256File(tmp)) !== src.checksum) throw new Error('Downloaded backup does not match its checksum.');
        const args = [`--uri=${this.env.MONGODB_URI}`, `--archive=${tmp}`, '--gzip', '--drop', `--nsInclude=${this.env.MONGODB_DB_NAME}.*`, ...RESTORE_EXCLUDE.map((c) => `--nsExclude=${this.env.MONGODB_DB_NAME}.${c}`)];
        const r = await run(this.env.MONGORESTORE_PATH, args);
        if (r.code !== 0) throw new Error(`mongorestore failed: ${scrub(r.stderr)}`);
      } finally {
        await rm(tmp, { force: true });
        this.busy = false;
      }
      await this.restores.updateOne({ _id: rr._id }, { $set: { status: 'checking' } });
      const health = await this.postRestoreChecks();
      await this.restores.updateOne({ _id: rr._id }, { $set: { status: health.ok ? 'completed' : 'failed', healthAfter: health, finishedAt: new Date(), error: health.ok ? undefined : 'post_restore_checks_failed' } });
      await this.alerts.create({ organizationId: ctx.orgOid, type: 'restore', severity: 'critical', userId: ctx.userOid, message: `${ctx.user.name} restored the backup from ${src.startedAt.toISOString?.() ?? src.startedAt}.` });
      await this.audit.record(ctx, { action: 'restore.complete', resourceType: 'backup', resourceId: id, outcome: health.ok ? 'success' : 'failure' });
    } catch (e) {
      await this.restores.updateOne({ _id: rr._id }, { $set: { status: 'failed', error: scrub((e as Error).message), finishedAt: new Date() } });
      await this.audit.record(ctx, { action: 'restore.failed', resourceType: 'backup', resourceId: id, outcome: 'failure' });
      throw new ApiError(HttpStatus.INTERNAL_SERVER_ERROR, 'RESTORE_FAILED', scrub((e as Error).message));
    }
    return serialize(await this.restores.findById(rr._id).lean());
  }

  private async postRestoreChecks(): Promise<{ ok: boolean; ping: boolean; collections: number; organizations: number; users: number }> {
    try {
      await this.db.ping();
      const conn = this.db.connection;
      const collections = (await conn.db!.listCollections().toArray()).length;
      const organizations = await conn.db!.collection('organizations').countDocuments();
      const users = await conn.db!.collection('users').countDocuments();
      return { ok: organizations > 0 && users > 0, ping: true, collections, organizations, users };
    } catch {
      return { ok: false, ping: false, collections: 0, organizations: 0, users: 0 };
    }
  }

  /** Periodic restore test into a scratch database that is dropped afterwards. */
  async restoreTest(): Promise<string> {
    const latest = await this.backups.findOne({ status: 'verified' }).sort({ verifiedAt: -1 }).lean<any>();
    if (!latest) return 'no verified backup';
    const scratch = `${this.env.MONGODB_DB_NAME}_restore_test`;
    const tmp = join(this.workDir, `test-${latest._id}.archive.gz`);
    try {
      await mkdir(this.workDir, { recursive: true });
      await pipeline(await this.storage.get({ provider: this.storage.name, providerFileId: latest.providerFileId, mimeType: 'application/gzip', sizeBytes: latest.sizeBytes }), createWriteStream(tmp));
      const r = await run(this.env.MONGORESTORE_PATH, [`--uri=${this.env.MONGODB_URI}`, `--archive=${tmp}`, '--gzip', `--nsFrom=${this.env.MONGODB_DB_NAME}.*`, `--nsTo=${scratch}.*`, '--drop']);
      if (r.code !== 0) throw new Error(`restore test failed: ${scrub(r.stderr)}`);
      const testDb = this.db.connection.getClient().db(scratch);
      const users = await testDb.collection('users').countDocuments();
      await testDb.dropDatabase();
      if (!users) throw new Error('restore test produced an empty users collection');
      await this.backups.updateOne({ _id: latest._id }, { $set: { restoreTestedAt: new Date() } });
      return `restore test ok (${users} users)`;
    } finally {
      await rm(tmp, { force: true });
    }
  }

  async runRestoreTest(ctx: Ctx): Promise<{ result: string }> {
    this.requireSuper(ctx);
    const result = await this.restoreTest();
    await this.audit.record(ctx, { action: 'backup.restore_test', resourceType: 'backup', resourceId: 'latest' });
    return { result };
  }

  /** Health: verified backup within 26 h = healthy; older = degraded; none or last failed = unavailable. */
  async health(): Promise<{ state: 'healthy' | 'degraded' | 'unavailable' | 'unknown'; reason: string; latestVerifiedAt?: Date }> {
    if (!this.db.configured) return { state: 'unavailable', reason: 'disconnected' };
    const latest = await this.backups.findOne({ status: 'verified' }).sort({ verifiedAt: -1 }).lean<any>();
    const lastAttempt = await this.backups.findOne({ status: { $in: ['verified', 'failed'] } }).sort({ startedAt: -1 }).lean<any>();
    if (lastAttempt?.status === 'failed') return { state: 'degraded', reason: 'last_backup_failed', latestVerifiedAt: latest?.verifiedAt };
    if (latest) {
      const age = Date.now() - new Date(latest.verifiedAt).getTime();
      if (age > 26 * 3600_000) return { state: 'degraded', reason: 'backup_stale', latestVerifiedAt: latest.verifiedAt };
      return { state: 'healthy', reason: 'ok', latestVerifiedAt: latest.verifiedAt };
    }
    return { state: 'healthy', reason: 'ok' };
  }

  /**
   * Monitors MongoDB Atlas storage capacity.
   * If storage reaches 90% capacity, alerts Super Admins and Admins immediately.
   */
  async monitorDatabaseStorage(): Promise<void> {
    if (!this.db.configured) return;
    await this.jobs.run('database.storage_monitor', async () => {
      const stats = await this.db.getStorageStats();
      if (stats.isAbove90Percent) {
        const lastAlert = await this.alerts.findOne({
          type: 'database_storage_critical',
          createdAt: { $gt: new Date(Date.now() - 12 * 3600_000) },
        }).lean();
        if (!lastAlert) {
          await this.alertStorageCapacity(stats);
        }
        return `CRITICAL: MongoDB Atlas storage is at ${stats.percentUsed}% (${stats.totalSizeMb} MB / ${stats.limitMb} MB). Admin alert sent.`;
      }
      return `Storage normal: ${stats.percentUsed}% (${stats.totalSizeMb} MB / ${stats.limitMb} MB)`;
    });
  }

  private async alertStorageCapacity(stats: { percentUsed: number; totalSizeMb: number; limitMb: number }): Promise<void> {
    this.logger.error(`MongoDB Atlas storage is at ${stats.percentUsed}% capacity!`);
    const recipients = await this.users.find(
      { role: { $in: ['super_admin', 'admin', 'manager', 'hr'] }, status: 'active' },
      { _id: 1, organizationId: 1, email: 1, fullName: 1, role: 1 },
    ).lean<any[]>();
    for (const orgId of [...new Set(recipients.map((a) => String(a.organizationId)))]) {
      const orgRecipients = recipients.filter((a) => String(a.organizationId) === orgId);
      const ids = orgRecipients.map((a) => a._id);
      const msg = `CRITICAL: MongoDB Atlas storage is at ${stats.percentUsed}% capacity (${stats.totalSizeMb} MB used of ${stats.limitMb} MB limit). It exceeds the 90% threshold. Immediate action required.`;
      await this.alerts.create({
        organizationId: new Types.ObjectId(orgId),
        type: 'database_storage_critical',
        severity: 'critical',
        message: msg,
      });
      await this.notifications.notify(new Types.ObjectId(orgId), ids, {
        event: 'database_storage_critical',
        title: `CRITICAL: MongoDB Storage ${stats.percentUsed}% Full`,
        body: msg,
        link: '/system',
        priority: 'essential',
      });
      // Direct emails to Super Admin, Admin, Manager, and HR
      for (const rec of orgRecipients) {
        if (rec.email && this.mail.canSend) {
          await this.mail.send({
            to: rec.email,
            subject: `[CRITICAL ALERT] MongoDB Atlas Storage at ${stats.percentUsed}% Full`,
            text: `Dear ${rec.fullName || rec.email},\n\n${msg}\n\nPlease check system status, ensure heavy files and selfies are stored in Google Drive, and consider cleaning up logs or upgrading cluster capacity.\n\nSignal HRM System`,
            html: `<div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 580px; padding: 24px; border: 2px solid #ef4444; border-radius: 10px; background: #ffffff;">
              <h2 style="color: #dc2626; margin-top: 0; font-size: 20px;">⚠️ MongoDB Atlas Storage Critical Alert (>90% Full)</h2>
              <p style="font-size: 15px; color: #1e293b;"><strong>Database Capacity:</strong> <span style="color: #dc2626; font-weight: bold;">${stats.percentUsed}%</span> (${stats.totalSizeMb} MB used of ${stats.limitMb} MB limit)</p>
              <p style="color: #475569; font-size: 14.5px; line-height: 1.6;">${msg}</p>
              <div style="background: #fef2f2; padding: 14px; border-radius: 6px; border-left: 4px solid #ef4444; margin: 18px 0;">
                <p style="margin: 0; color: #991b1b; font-size: 13.5px; line-height: 1.5;">
                  <strong>Action Required:</strong> Verify that high document and selfie storage is offloaded to Google Drive (15 GB free), clean up old logs, or scale up your MongoDB Atlas cluster.
                </p>
              </div>
              <p style="margin-top: 20px; font-size: 12px; color: #94a3b8;">This critical alert was sent to Super Admin, Admin, Manager, and HR roles.</p>
            </div>`,
          }).catch((err) => this.logger.warn(`Failed sending storage alert email to ${rec.email}: ${err.message}`));
        }
      }
    }
  }

  /** Streams a backup archive from Google Drive / storage provider for Super Admin download. */
  async download(ctx: Ctx, id: string): Promise<{ stream: Readable; fileName: string; sizeBytes: number }> {
    this.requireSuper(ctx);
    const rec = await this.backups.findById(oid(id)).lean<any>();
    if (!rec || !rec.providerFileId) throw notFound('Backup');
    const stream = await this.storage.get({ provider: rec.provider ?? this.storage.name, providerFileId: rec.providerFileId, mimeType: 'application/gzip', sizeBytes: rec.sizeBytes });
    const fileName = `signal-hrm-${rec._id}-${rec.kind}.archive.gz`;
    return { stream, fileName, sizeBytes: rec.sizeBytes };
  }
}
