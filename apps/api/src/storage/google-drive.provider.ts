import { drive, drive_v3 } from '@googleapis/drive';
import { createHash } from 'node:crypto';
import { PassThrough, Readable } from 'node:stream';
import { GoogleAuth, OAuth2Client } from 'google-auth-library';
import type { IStorageProvider, PutFileInput, StorageHealth, StoredFileRef } from './storage-provider.interface';

export interface GoogleDriveConfig {
  credentialsJson?: string;
  clientId?: string;
  clientSecret?: string;
  refreshToken?: string;
  rootFolderId?: string;
}

/**
 * Google Drive Storage Provider:
 * Supports:
 * 1. Personal Google Drive (15 GB Free): Using OAuth2 refresh token (client_id, client_secret, refresh_token).
 * 2. Google Workspace Shared Drive: Using a Service Account (credentials JSON) added to the Shared Drive.
 */
export class GoogleDriveStorageProvider implements IStorageProvider {
  readonly name = 'google_drive';
  private readonly client: drive_v3.Drive;
  private readonly rootFolderId?: string;
  private folderCache = new Map<string, string>();

  constructor(configOrJson: string | GoogleDriveConfig, rootFolderId?: string) {
    let cfg: GoogleDriveConfig;
    if (typeof configOrJson === 'string') {
      cfg = { credentialsJson: configOrJson, rootFolderId };
    } else {
      cfg = configOrJson;
    }
    this.rootFolderId = cfg.rootFolderId;

    if (cfg.refreshToken && cfg.clientId) {
      const oauth2 = new OAuth2Client(cfg.clientId, cfg.clientSecret);
      oauth2.setCredentials({ refresh_token: cfg.refreshToken });
      this.client = drive({ version: 'v3', auth: oauth2 });
    } else if (cfg.credentialsJson) {
      const parsed = JSON.parse(cfg.credentialsJson);
      if (parsed.refresh_token || parsed.type === 'authorized_user') {
        const oauth2 = new OAuth2Client(parsed.client_id, parsed.client_secret);
        oauth2.setCredentials({ refresh_token: parsed.refresh_token });
        this.client = drive({ version: 'v3', auth: oauth2 });
      } else {
        const auth = new GoogleAuth({ credentials: parsed, scopes: ['https://www.googleapis.com/auth/drive'] });
        this.client = drive({ version: 'v3', auth });
      }
    } else {
      throw new Error('GoogleDriveStorageProvider requires credentialsJson or refreshToken + clientId');
    }
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
    // When a dedicated root folder is configured, place files directly in that folder.
    let parent = this.rootFolderId;
    if (!parent) {
      const org = await this.folder(input.organizationId);
      parent = await this.folder(input.folder.replace(/[^\w-]/g, '_') || 'files', org);
    }
    try {
      const res = await this.client.files.create({
        requestBody: { name: input.fileName.slice(0, 200), parents: [parent] },
        media: { mimeType: input.mimeType, body: Readable.from(buf) },
        fields: 'id,size,md5Checksum',
        supportsAllDrives: true,
      });
      return { provider: this.name, providerFileId: res.data.id!, mimeType: input.mimeType, sizeBytes: buf.length, checksum: createHash('sha256').update(buf).digest('hex') };
    } catch (err: any) {
      if (err?.message?.includes('storageQuotaExceeded') || err?.message?.includes('storage quota')) {
        throw new Error(
          'Google Drive quota exceeded: Service accounts cannot own files in personal Google Drive. Use a Google Workspace Shared Drive or configure GOOGLE_DRIVE_REFRESH_TOKEN for personal Drive.'
        );
      }
      throw err;
    }
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
      await this.client.about.get({ fields: 'user,storageQuota' });
      const latencyMs = Date.now() - start;
      return latencyMs > 2000 ? { state: 'degraded', reason: 'slow_response', latencyMs } : { state: 'healthy', reason: 'ok', latencyMs };
    } catch (err: any) {
      return { state: 'unavailable', reason: err?.message?.slice(0, 80) || 'check_failed', latencyMs: Date.now() - start };
    }
  }

  /** Storage quota for usage rings (Drive reports bytes). */
  async usage(): Promise<{ usedBytes?: number; limitBytes?: number }> {
    const r = await this.client.about.get({ fields: 'storageQuota' });
    return { usedBytes: Number(r.data.storageQuota?.usage ?? 0), limitBytes: r.data.storageQuota?.limit ? Number(r.data.storageQuota.limit) : undefined };
  }
}
