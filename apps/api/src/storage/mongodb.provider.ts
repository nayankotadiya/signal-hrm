import { createHash } from 'node:crypto';
import type { Readable } from 'node:stream';
import mongoose from 'mongoose';
import type { DatabaseService } from '../database/database.service';
import type { IStorageProvider, PutFileInput, StorageHealth, StoredFileRef } from './storage-provider.interface';

async function toBuffer(body: Buffer | Readable): Promise<Buffer> {
  if (Buffer.isBuffer(body)) return body;
  const chunks: Buffer[] = [];
  for await (const c of body) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
  return Buffer.concat(chunks);
}

/**
 * Stores files directly in MongoDB using GridFS.
 * This ensures that deployments on platforms without persistent local disks (Render, Railway, Heroku, etc.)
 * can store selfies, receipts, avatars, and documents securely without needing third-party cloud credentials.
 */
export class MongoGridFSStorageProvider implements IStorageProvider {
  readonly name = 'mongodb';

  constructor(private readonly dbService: DatabaseService) {}

  private getBucket(): mongoose.mongo.GridFSBucket {
    const conn = this.dbService.connection;
    if (!conn.db) throw new Error('Database is not connected yet');
    return new mongoose.mongo.GridFSBucket(conn.db, { bucketName: 'signal_files' });
  }

  async put(input: PutFileInput): Promise<StoredFileRef> {
    const buf = await toBuffer(input.body);
    const bucket = this.getBucket();
    const folder = input.folder.replace(/[^\w-]/g, '_').slice(0, 60) || 'files';
    const filename = `${input.organizationId}/${folder}/${input.fileName}`;

    const uploadStream = bucket.openUploadStream(filename, {
      contentType: input.mimeType,
      metadata: {
        organizationId: input.organizationId,
        folder: input.folder,
        fileName: input.fileName,
      },
    });

    await new Promise<void>((resolve, reject) => {
      uploadStream.on('error', reject);
      uploadStream.on('finish', () => resolve());
      uploadStream.end(buf);
    });

    return {
      provider: this.name,
      providerFileId: uploadStream.id.toString(),
      mimeType: input.mimeType,
      sizeBytes: buf.length,
      checksum: createHash('sha256').update(buf).digest('hex'),
    };
  }

  async get(ref: StoredFileRef): Promise<Readable> {
    const bucket = this.getBucket();
    return bucket.openDownloadStream(new mongoose.Types.ObjectId(ref.providerFileId));
  }

  async delete(ref: StoredFileRef): Promise<void> {
    try {
      const bucket = this.getBucket();
      await bucket.delete(new mongoose.Types.ObjectId(ref.providerFileId));
    } catch {
      // ignore if file doesn't exist
    }
  }

  async exists(ref: StoredFileRef): Promise<boolean> {
    try {
      const bucket = this.getBucket();
      const files = await bucket.find({ _id: new mongoose.Types.ObjectId(ref.providerFileId) }).toArray();
      return files.length > 0;
    } catch {
      return false;
    }
  }

  async healthCheck(): Promise<StorageHealth> {
    return {
      state: this.dbService.ready ? 'healthy' : 'degraded',
      reason: this.dbService.ready ? 'ok' : 'check_failed',
    };
  }
}
