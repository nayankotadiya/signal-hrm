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
    } catch (err) {
      // Fallback: If primary storage fails (e.g. read-only disk on cloud or not configured), use MongoDB GridFS
      if (this.primary !== this.mongo) {
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
        if (env.STORAGE_PROVIDER === 'google_drive' && env.GOOGLE_DRIVE_CREDENTIALS_JSON) {
          drive = new GoogleDriveStorageProvider(env.GOOGLE_DRIVE_CREDENTIALS_JSON, env.GOOGLE_DRIVE_ROOT_FOLDER_ID);
        }

        let primary: IStorageProvider;
        switch (env.STORAGE_PROVIDER) {
          case 'google_drive':
            if (!drive) throw new Error('STORAGE_PROVIDER=google_drive needs GOOGLE_DRIVE_CREDENTIALS_JSON');
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
            primary = db.configured ? mongo : new NotConfiguredStorageProvider();
            break;
        }

        return new CompositeStorageProvider(primary, mongo, local, drive);
      },
    },
  ],
  exports: [STORAGE_PROVIDER],
})
export class StorageModule {}
