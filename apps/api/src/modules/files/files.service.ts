import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import type { Readable } from 'node:stream';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { ApiError } from '../../common/errors/api-error';
import { badRequest, ListQuery, notFound, oid, Paged } from '../../common/http/validation';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { InjectModel, serialize } from '../../database/model';
import { IStorageProvider, STORAGE_PROVIDER } from '../../storage/storage-provider.interface';
import { JobsService } from '../system/jobs.service';

export type FilePurpose = 'document' | 'receipt' | 'selfie' | 'avatar' | 'payslip' | 'export' | 'attachment' | 'logo' | 'letter' | 'report';

/** Allowed types per purpose (checked by magic bytes, not just the declared type). */
const ALLOWED: Record<FilePurpose, string[]> = {
  document: ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'text/plain'],
  receipt: ['application/pdf', 'image/jpeg', 'image/png', 'image/webp'],
  selfie: ['image/jpeg', 'image/png', 'image/webp'],
  avatar: ['image/jpeg', 'image/png', 'image/webp'],
  logo: ['image/jpeg', 'image/png', 'image/webp'],
  payslip: ['application/pdf'],
  letter: ['application/pdf'],
  export: ['application/json', 'text/csv', 'application/zip'],
  report: ['text/csv', 'application/pdf'],
  attachment: ['application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/plain', 'text/csv', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
};

/** Detects common types from the first bytes so a renamed executable can't pass as a PDF. */
export function sniff(buf: Buffer): string | null {
  const h = buf.subarray(0, 12);
  if (h.subarray(0, 4).toString('latin1') === '%PDF') return 'application/pdf';
  if (h[0] === 0xff && h[1] === 0xd8 && h[2] === 0xff) return 'image/jpeg';
  if (h.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (h.subarray(0, 4).toString('latin1') === 'RIFF' && h.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
  if (h[0] === 0x50 && h[1] === 0x4b && h[2] === 0x03 && h[3] === 0x04) return 'application/zip'; // docx/xlsx/zip
  return null;
}

function typeMatches(declared: string, sniffed: string | null, buf: Buffer): boolean {
  if (['text/plain', 'text/csv', 'application/json'].includes(declared)) {
    return sniffed === null && !buf.subarray(0, 4096).includes(0); // text, no NUL bytes
  }
  if (declared.startsWith('application/vnd.openxmlformats')) return sniffed === 'application/zip';
  return declared === sniffed;
}

export type Authorizer = (ctx: Ctx, file: any) => Promise<boolean>;

@Injectable()
export class FilesService {
  private readonly logger = new Logger('Files');
  private authorizers = new Map<string, Authorizer>();

  constructor(
    @Inject(STORAGE_PROVIDER) private readonly storage: IStorageProvider,
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly audit: AuditService,
    private readonly jobs: JobsService,
    @InjectModel('File') private readonly files: Model<any>,
    @InjectModel('FileVersion') private readonly versions: Model<any>,
    @InjectModel('Folder') private readonly folders: Model<any>,
  ) {}

  get providerName(): string {
    return this.storage.name;
  }

  /** Modules register who may download files linked to their records. Default: deny. */
  registerAuthorizer(linkedType: string, fn: Authorizer): void {
    this.authorizers.set(linkedType, fn);
  }

  async upload(
    ctx: Ctx,
    input: { buffer: Buffer; originalName: string; mimeType: string; purpose: FilePurpose; folderId?: string; ownerEmployeeId?: Types.ObjectId; linked?: { type: string; id: Types.ObjectId }; deleteAfter?: Date },
  ): Promise<any> {
    const allowed = ALLOWED[input.purpose];
    if (!allowed) throw badRequest('PURPOSE_INVALID', 'Unknown file purpose.');
    if (!input.buffer?.length) throw badRequest('FILE_EMPTY', 'The file is empty.', 'file');
    const max = (input.purpose === 'selfie' ? 5 : this.env.MAX_UPLOAD_MB) * 1024 * 1024;
    if (input.buffer.length > max) throw new ApiError(HttpStatus.PAYLOAD_TOO_LARGE, 'FILE_TOO_LARGE', `Files can be up to ${Math.round(max / 1048576)} MB.`, [{ field: 'file', message: 'Too large' }]);
    const declared = input.mimeType.toLowerCase().split(';')[0].trim();
    if (!allowed.includes(declared)) throw badRequest('FILE_TYPE_NOT_ALLOWED', `This file type isn't allowed here. Use ${allowed.map((a) => a.split('/')[1].split('.').pop()).join(', ')}.`, 'file');
    if (!typeMatches(declared, sniff(input.buffer), input.buffer)) throw badRequest('FILE_CONTENT_MISMATCH', "The file's content doesn't match its type.", 'file');

    const name = input.originalName.replace(/[^\w.\- ()]/g, '_').slice(0, 150) || 'file';
    const rec = await this.files.create({
      organizationId: ctx.orgOid,
      name,
      folderId: input.folderId ? oid(input.folderId) : undefined,
      purpose: input.purpose,
      provider: this.storage.name,
      mimeType: declared,
      sizeBytes: input.buffer.length,
      uploadedBy: ctx.userOid,
      ownerEmployeeId: input.ownerEmployeeId ?? ctx.employeeOid,
      linked: input.linked,
      status: 'uploading',
      deleteAfter: input.deleteAfter,
    });
    try {
      const ref = await this.storage.put({ organizationId: ctx.user.orgId, folder: input.purpose, fileName: name, mimeType: declared, body: input.buffer, sizeBytes: input.buffer.length });
      await this.files.updateOne({ _id: rec._id }, { $set: { status: 'stored', providerFileId: ref.providerFileId, checksum: ref.checksum } });
      await this.versions.create({ organizationId: ctx.orgOid, fileId: rec._id, version: 1, providerFileId: ref.providerFileId, sizeBytes: ref.sizeBytes, checksum: ref.checksum, uploadedBy: ctx.userOid });
    } catch (e) {
      // Recorded as a failed upload (visible in Storage > Failed uploads) and reported to the user.
      await this.files.updateOne({ _id: rec._id }, { $set: { status: 'failed', error: e instanceof ApiError ? e.code : 'provider_error' } });
      if (e instanceof ApiError) throw e;
      this.logger.error(`upload failed: ${(e as Error).message}`);
      throw new ApiError(HttpStatus.BAD_GATEWAY, 'UPLOAD_FAILED', "The file couldn't be stored. Try again in a moment.");
    }
    return serialize(await this.files.findById(rec._id).lean());
  }

  /** Stores a server-generated file (payslip PDF, export) without a user upload. */
  async storeGenerated(orgId: Types.ObjectId, input: { buffer: Buffer; name: string; mimeType: string; purpose: FilePurpose; ownerEmployeeId?: Types.ObjectId; linked?: { type: string; id: Types.ObjectId }; uploadedBy?: Types.ObjectId; deleteAfter?: Date }): Promise<any> {
    const ref = await this.storage.put({ organizationId: String(orgId), folder: input.purpose, fileName: input.name, mimeType: input.mimeType, body: input.buffer, sizeBytes: input.buffer.length });
    const rec = await this.files.create({ organizationId: orgId, name: input.name, purpose: input.purpose, provider: this.storage.name, providerFileId: ref.providerFileId, mimeType: input.mimeType, sizeBytes: ref.sizeBytes, checksum: ref.checksum, uploadedBy: input.uploadedBy, ownerEmployeeId: input.ownerEmployeeId, linked: input.linked, status: 'stored', deleteAfter: input.deleteAfter });
    return rec.toObject();
  }

  async link(fileId: Types.ObjectId | string, linked: { type: string; id: Types.ObjectId }): Promise<void> {
    await this.files.updateOne({ _id: oid(String(fileId)) }, { $set: { linked } });
  }

  async setDeleteAfter(fileId: Types.ObjectId | string, deleteAfter: Date): Promise<void> {
    await this.files.updateOne({ _id: oid(String(fileId)) }, { $set: { deleteAfter } });
  }

  /** Validates that a file the client references was uploaded by this user for this purpose. */
  async requireOwnUpload(ctx: Ctx, fileId: string, purpose: FilePurpose, maxAgeMinutes?: number): Promise<any> {
    const f = await this.files.findOne({ _id: oid(fileId), organizationId: ctx.orgOid, uploadedBy: ctx.userOid, purpose, status: 'stored' }).lean<any>();
    if (!f) throw badRequest('FILE_INVALID', 'Upload the file again.', 'fileId');
    if (maxAgeMinutes && Date.now() - new Date(f.createdAt).getTime() > maxAgeMinutes * 60_000) throw badRequest('FILE_STALE', 'That photo is too old. Take a new one.', 'fileId');
    return f;
  }

  async canDownload(ctx: Ctx, f: any): Promise<boolean> {
    if (f.purpose === 'avatar' || f.purpose === 'logo') return true; // visible to the organization
    if (f.purpose === 'export' || f.purpose === 'report') return String(f.uploadedBy) === ctx.user.userId;
    if (f.linked?.type) {
      const fn = this.authorizers.get(f.linked.type);
      return fn ? fn(ctx, f) : false;
    }
    return String(f.uploadedBy) === ctx.user.userId || ctx.authz.can('storage', 'manage', 'organization');
  }

  /** Streams a file after the permission check. Never redirects to a provider link. */
  async open(ctx: Ctx, id: string): Promise<{ stream: Readable; file: any }> {
    const f = await this.files.findOne({ _id: oid(id), organizationId: ctx.orgOid, status: 'stored' }).lean<any>();
    if (!f || !(await this.canDownload(ctx, f))) {
      if (f) await this.audit.record(ctx, { action: 'file.download', resourceType: 'file', resourceId: id, outcome: 'denied' });
      throw notFound('File');
    }
    const stream = await this.storage.get({ provider: f.provider, providerFileId: f.providerFileId, mimeType: f.mimeType, sizeBytes: f.sizeBytes });
    return { stream, file: f };
  }

  async readBuffer(file: any): Promise<Buffer> {
    const s = await this.storage.get({ provider: file.provider, providerFileId: file.providerFileId, mimeType: file.mimeType, sizeBytes: file.sizeBytes });
    const chunks: Buffer[] = [];
    for await (const c of s) chunks.push(Buffer.from(c));
    return Buffer.concat(chunks);
  }

  async remove(fileId: Types.ObjectId | string): Promise<void> {
    const f = await this.files.findById(fileId).lean<any>();
    if (!f || f.status === 'deleted') return;
    try {
      if (f.providerFileId) await this.storage.delete({ provider: f.provider, providerFileId: f.providerFileId, mimeType: f.mimeType, sizeBytes: f.sizeBytes });
    } catch (e) {
      this.logger.warn(`provider delete failed for ${fileId}: ${(e as Error).message}`);
    }
    await this.files.updateOne({ _id: f._id }, { $set: { status: 'deleted' } });
  }

  // ------------------------------------------------------------------ storage admin

  async list(ctx: Ctx, q: ListQuery & { purpose?: string; folderId?: string }): Promise<Paged<any>> {
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid, status: q.status ?? 'stored' };
    if (q.purpose) filter.purpose = q.purpose;
    if (q.folderId) filter.folderId = oid(q.folderId);
    if (q.q) filter.name = new RegExp(q.q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');
    const [items, total] = await Promise.all([this.files.find(filter).sort({ createdAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean(), this.files.countDocuments(filter)]);
    return { items: serialize(items), page: q.page, limit: q.limit, total, hasMore: q.page * q.limit < total };
  }

  async usage(orgId: Types.ObjectId): Promise<{ byPurpose: { purpose: string; bytes: number; count: number }[]; totalBytes: number; failedUploads: number; provider: string; providerQuota?: { usedBytes?: number; limitBytes?: number } }> {
    const rows = await this.files.aggregate([{ $match: { organizationId: orgId, status: 'stored' } }, { $group: { _id: '$purpose', bytes: { $sum: '$sizeBytes' }, count: { $sum: 1 } } }, { $sort: { bytes: -1 } }]);
    const failedUploads = await this.files.countDocuments({ organizationId: orgId, status: 'failed' });
    let providerQuota: { usedBytes?: number; limitBytes?: number } | undefined;
    const p = this.storage as unknown as { usage?: () => Promise<{ usedBytes?: number; limitBytes?: number }> };
    if (p.usage) providerQuota = await p.usage().catch(() => undefined);
    return {
      byPurpose: rows.map((r: any) => ({ purpose: r._id, bytes: r.bytes, count: r.count })),
      totalBytes: rows.reduce((a: number, r: any) => a + r.bytes, 0),
      failedUploads,
      provider: this.storage.name,
      providerQuota,
    };
  }

  async createFolder(ctx: Ctx, name: string, parentId?: string): Promise<any> {
    const parent = parentId ? await this.folders.findOne({ _id: oid(parentId), organizationId: ctx.orgOid }).lean<any>() : null;
    if (parentId && !parent) throw notFound('Folder');
    const f = await this.folders.create({ organizationId: ctx.orgOid, name, parentId: parent?._id, path: `${parent?.path ?? ''}/${name}`, createdBy: ctx.userOid });
    return serialize(f.toObject());
  }

  async listFolders(ctx: Ctx): Promise<any[]> {
    return serialize(await this.folders.find({ organizationId: ctx.orgOid }).sort({ path: 1 }).lean());
  }

  /** Deletes files past their retention date (selfies, temporary exports). */
  @Cron('0 3 * * *')
  async retention(): Promise<void> {
    await this.jobs.run('files.retention', async () => {
      const due = await this.files.find({ status: 'stored', deleteAfter: { $lt: new Date() } }, { _id: 1 }).limit(1000).lean<any[]>();
      for (const f of due) await this.remove(f._id);
      // Uploads abandoned mid-way (never linked) older than a day.
      const stale = await this.files.find({ status: 'uploading', createdAt: { $lt: new Date(Date.now() - 86400_000) } }, { _id: 1 }).lean<any[]>();
      await this.files.updateMany({ _id: { $in: stale.map((s) => s._id) } }, { $set: { status: 'failed', error: 'abandoned' } });
      return `${due.length} expired, ${stale.length} abandoned`;
    });
  }

  async health(): Promise<ReturnType<IStorageProvider['healthCheck']>> {
    return this.storage.healthCheck();
  }
}
