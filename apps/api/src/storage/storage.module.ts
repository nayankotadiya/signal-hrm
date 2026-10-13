import { Global, Module } from '@nestjs/common';
import { APP_CONFIG } from '../config/config.module';
import type { AppEnv } from '../config/env.schema';
import { GoogleDriveStorageProvider } from './google-drive.provider';
import { LocalDiskStorageProvider } from './local-disk.provider';
import { NotConfiguredStorageProvider } from './not-configured.provider';
import { IStorageProvider, STORAGE_PROVIDER } from './storage-provider.interface';

@Global()
@Module({
  providers: [
    {
      provide: STORAGE_PROVIDER,
      inject: [APP_CONFIG],
      useFactory: (env: AppEnv): IStorageProvider => {
        switch (env.STORAGE_PROVIDER) {
          case 'google_drive':
            if (!env.GOOGLE_DRIVE_CREDENTIALS_JSON) throw new Error('STORAGE_PROVIDER=google_drive needs GOOGLE_DRIVE_CREDENTIALS_JSON');
            return new GoogleDriveStorageProvider(env.GOOGLE_DRIVE_CREDENTIALS_JSON, env.GOOGLE_DRIVE_ROOT_FOLDER_ID);
          case 'local':
            return new LocalDiskStorageProvider(env.LOCAL_STORAGE_DIR);
          case 'none':
          default:
            return new NotConfiguredStorageProvider();
        }
      },
    },
  ],
  exports: [STORAGE_PROVIDER],
})
export class StorageModule {}
