import { Global, Module } from '@nestjs/common';
import type { Readable } from 'node:stream';
import { APP_CONFIG } from '../config/config.module';
import type { AppEnv } from '../config/env.schema';
import { DatabaseService } from '../database/database.service';
import { GoogleDriveStorageProvider } from './google-drive.provider';
import { LocalDiskStorageProvider } from './local-disk.provider';
import { MongoGridFSStorageProvider } from './mongodb.provider';
import { NotConfiguredStorageProvider } from './not-configured.provider';
import { IStorageProvider, PutFileInput, STORAGE_PROVIDER, StorageHealth, StoredFileRef } from './storage-provider.interface';

class CompositeStorageProvider implements IStorageProvider {
  constructor(
    private readonly primary: IStorageProvider,
    private readonly mongo: MongoGridFSStorageProvider,
    private readonly local?: LocalDiskStorageProvider,
    private readonly drive?: GoogleDriveStorageProvider,
  ) {}

  get name(): string {
    return this.primary.name;
  }

  async put(input: PutFileInput): Promise<StoredFileRef> {
    try {
      return await this.primary.put(input);
    } catch (err: any) {
      // Fallback: If primary storage fails (e.g. read-only disk on cloud or not configured), use MongoDB GridFS
      if (this.primary !== this.mongo) {
        console.warn(`[Storage] Primary storage '${this.primary.name}' put failed (${err?.message || err}). Falling back to MongoDB GridFS.`);
        return await this.mongo.put(input);
      }
      throw err;
    }
  }

  async get(ref: StoredFileRef): Promise<Readable> {
    if (ref.provider === 'mongodb') return this.mongo.get(ref);
    if (ref.provider === 'local' && this.local) return this.local.get(ref);
    if (ref.provider === 'google_drive' && this.drive) return this.drive.get(ref);
    return this.primary.get(ref);
  }

  async delete(ref: StoredFileRef): Promise<void> {
    if (ref.provider === 'mongodb') return this.mongo.delete(ref);
    if (ref.provider === 'local' && this.local) return this.local.delete(ref);
    if (ref.provider === 'google_drive' && this.drive) return this.drive.delete(ref);
    return this.primary.delete(ref);
  }

  async exists(ref: StoredFileRef): Promise<boolean> {
    if (ref.provider === 'mongodb') return this.mongo.exists(ref);
    if (ref.provider === 'local' && this.local) return this.local.exists(ref);
    if (ref.provider === 'google_drive' && this.drive) return this.drive.exists(ref);
    return this.primary.exists(ref);
  }

  async healthCheck(): Promise<StorageHealth> {
    return this.primary.healthCheck();
  }
}

@Global()
@Module({
  providers: [
    {
      provide: STORAGE_PROVIDER,
      inject: [APP_CONFIG, DatabaseService],
      useFactory: (env: AppEnv, db: DatabaseService): IStorageProvider => {
        const mongo = new MongoGridFSStorageProvider(db);
        const local = new LocalDiskStorageProvider(env.LOCAL_STORAGE_DIR);
        let drive: GoogleDriveStorageProvider | undefined;
        const hasDriveConfig = !!(env.GOOGLE_DRIVE_REFRESH_TOKEN || env.GOOGLE_DRIVE_CREDENTIALS_JSON);
        if (hasDriveConfig) {
          const clientId = env.GOOGLE_DRIVE_CLIENT_ID || env.GOOGLE_CLIENT_IDS[0];
          const clientSecret = env.GOOGLE_DRIVE_CLIENT_SECRET || env.GOOGLE_CLIENT_SECRET;
          drive = new GoogleDriveStorageProvider({
            credentialsJson: env.GOOGLE_DRIVE_CREDENTIALS_JSON,
            clientId,
            clientSecret,
            refreshToken: env.GOOGLE_DRIVE_REFRESH_TOKEN,
            rootFolderId: env.GOOGLE_DRIVE_ROOT_FOLDER_ID,
          });
        }

        let primary: IStorageProvider;
        switch (env.STORAGE_PROVIDER) {
          case 'google_drive':
            if (!drive) throw new Error('STORAGE_PROVIDER=google_drive requires GOOGLE_DRIVE_REFRESH_TOKEN or GOOGLE_DRIVE_CREDENTIALS_JSON');
            primary = drive;
            break;
          case 'local':
            primary = local;
            break;
          case 'mongodb':
            primary = mongo;
            break;
          case 'none':
          default:
            primary = drive ?? (db.configured ? mongo : new NotConfiguredStorageProvider());
            break;
        }

        return new CompositeStorageProvider(primary, mongo, local, drive);
      },
    },
  ],
  exports: [STORAGE_PROVIDER],
})
export class StorageModule {}
