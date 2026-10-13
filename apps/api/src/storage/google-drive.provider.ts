import { drive, drive_v3 } from '@googleapis/drive';
import { createHash } from 'node:crypto';
import { PassThrough, Readable } from 'node:stream';
import { GoogleAuth } from 'google-auth-library';
import type { IStorageProvider, PutFileInput, StorageHealth, StoredFileRef } from './storage-provider.interface';

/**
 * Google Drive through a service account (credentials only on the server). Files are private to the
 * service account / shared drive; the API streams them after a permission check, so no Drive link is
 * ever exposed to users. Folder per organization/purpose is created on demand under ROOT_FOLDER_ID.
 */
export class GoogleDriveStorageProvider implements IStorageProvider {
  readonly name = 'google_drive';
  private readonly client: drive_v3.Drive;
  private folderCache = new Map<string, string>();

  constructor(credentialsJson: string, private readonly rootFolderId?: string) {
    const credentials = JSON.parse(credentialsJson);
    const auth = new GoogleAuth({ credentials, scopes: ['https://www.googleapis.com/auth/drive'] });
    this.client = drive({ version: 'v3', auth });
  }

  private async folder(name: string, parent?: string): Promise<string> {
    const key = `${parent ?? 'root'}/${name}`;
    const hit = this.folderCache.get(key);
    if (hit) return hit;
    const q = [`name = '${name.replace(/'/g, "\\'")}'`, "mimeType = 'application/vnd.google-apps.folder'", 'trashed = false', parent ? `'${parent}' in parents` : null].filter(Boolean).join(' and ');
    const found = await this.client.files.list({ q, fields: 'files(id)', supportsAllDrives: true, includeItemsFromAllDrives: true, pageSize: 1 });
    let id = found.data.files?.[0]?.id ?? undefined;
    if (!id) {
      const created = await this.client.files.create({ requestBody: { name, mimeType: 'application/vnd.google-apps.folder', parents: parent ? [parent] : undefined }, fields: 'id', supportsAllDrives: true });
      id = created.data.id!;
    }
    this.folderCache.set(key, id);
    return id;
  }

  async put(input: PutFileInput): Promise<StoredFileRef> {
    const buf = Buffer.isBuffer(input.body) ? input.body : await new Promise<Buffer>((res, rej) => {
      const chunks: Buffer[] = [];
      (input.body as Readable).on('data', (c) => chunks.push(Buffer.from(c))).on('end', () => res(Buffer.concat(chunks))).on('error', rej);
    });
    const org = await this.folder(input.organizationId, this.rootFolderId);
    const parent = await this.folder(input.folder.replace(/[^\w-]/g, '_') || 'files', org);
    const res = await this.client.files.create({
      requestBody: { name: input.fileName.slice(0, 200), parents: [parent] },
      media: { mimeType: input.mimeType, body: Readable.from(buf) },
      fields: 'id,size,md5Checksum',
      supportsAllDrives: true,
    });
    return { provider: this.name, providerFileId: res.data.id!, mimeType: input.mimeType, sizeBytes: buf.length, checksum: createHash('sha256').update(buf).digest('hex') };
  }

  async get(ref: StoredFileRef): Promise<Readable> {
    const res = await this.client.files.get({ fileId: ref.providerFileId, alt: 'media', supportsAllDrives: true }, { responseType: 'stream' });
    const out = new PassThrough();
    (res.data as unknown as Readable).pipe(out);
    return out;
  }

  async delete(ref: StoredFileRef): Promise<void> {
    await this.client.files.delete({ fileId: ref.providerFileId, supportsAllDrives: true });
  }

  async exists(ref: StoredFileRef): Promise<boolean> {
    try {
      const r = await this.client.files.get({ fileId: ref.providerFileId, fields: 'id,trashed', supportsAllDrives: true });
      return !!r.data.id && !r.data.trashed;
    } catch {
      return false;
    }
  }

  async healthCheck(): Promise<StorageHealth> {
    const start = Date.now();
    try {
      await this.client.about.get({ fields: 'user' });
      const latencyMs = Date.now() - start;
      return latencyMs > 1500 ? { state: 'degraded', reason: 'slow_response', latencyMs } : { state: 'healthy', reason: 'ok', latencyMs };
    } catch {
      return { state: 'unavailable', reason: 'check_failed', latencyMs: Date.now() - start };
    }
  }

  /** Storage quota for usage rings (Drive reports bytes). */
  async usage(): Promise<{ usedBytes?: number; limitBytes?: number }> {
    const r = await this.client.about.get({ fields: 'storageQuota' });
    return { usedBytes: Number(r.data.storageQuota?.usage ?? 0), limitBytes: r.data.storageQuota?.limit ? Number(r.data.storageQuota.limit) : undefined };
  }
}
