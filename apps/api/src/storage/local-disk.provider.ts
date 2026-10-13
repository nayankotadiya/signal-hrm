import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { access, mkdir, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join, resolve, sep } from 'node:path';
import type { Readable } from 'node:stream';
import type { IStorageProvider, PutFileInput, StorageHealth, StoredFileRef } from './storage-provider.interface';

async function toBuffer(body: Buffer | Readable): Promise<Buffer> {
  if (Buffer.isBuffer(body)) return body;
  const chunks: Buffer[] = [];
  for await (const c of body) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
  return Buffer.concat(chunks);
}

/**
 * Stores files on the server's disk under LOCAL_STORAGE_DIR. Good for development and small
 * single-server installs; files are never served directly, only streamed by the API after a
 * permission check. Paths are generated (never from user input).
 */
export class LocalDiskStorageProvider implements IStorageProvider {
  readonly name = 'local';
  private readonly root: string;

  constructor(dir: string) {
    this.root = resolve(dir);
  }

  private pathOf(id: string): string {
    if (!/^[\w-]+\/[\w-]+\/[\w-]+$/.test(id)) throw new Error('invalid file id');
    const p = resolve(join(this.root, id));
    if (!p.startsWith(this.root + sep)) throw new Error('invalid file path');
    return p;
  }

  async put(input: PutFileInput): Promise<StoredFileRef> {
    const buf = await toBuffer(input.body);
    const folder = input.folder.replace(/[^\w-]/g, '_').slice(0, 60) || 'files';
    const id = `${input.organizationId}/${folder}/${randomUUID()}`;
    const p = this.pathOf(id);
    await mkdir(dirname(p), { recursive: true });
    await writeFile(p, buf, { mode: 0o600 });
    return { provider: this.name, providerFileId: id, mimeType: input.mimeType, sizeBytes: buf.length, checksum: createHash('sha256').update(buf).digest('hex') };
  }

  async get(ref: StoredFileRef): Promise<Readable> {
    return createReadStream(this.pathOf(ref.providerFileId));
  }

  async delete(ref: StoredFileRef): Promise<void> {
    await rm(this.pathOf(ref.providerFileId), { force: true });
  }

  async exists(ref: StoredFileRef): Promise<boolean> {
    try {
      const s = await stat(this.pathOf(ref.providerFileId));
      return s.isFile();
    } catch {
      return false;
    }
  }

  async healthCheck(): Promise<StorageHealth> {
    const start = Date.now();
    try {
      await mkdir(this.root, { recursive: true });
      const probe = join(this.root, '.health');
      await writeFile(probe, String(Date.now()));
      await access(probe);
      await rm(probe, { force: true });
      const latencyMs = Date.now() - start;
      return latencyMs > 500 ? { state: 'degraded', reason: 'slow_response', latencyMs } : { state: 'healthy', reason: 'ok', latencyMs };
    } catch {
      return { state: 'unavailable', reason: 'check_failed', latencyMs: Date.now() - start };
    }
  }
}
