import { HttpStatus } from '@nestjs/common';
import type { Readable } from 'node:stream';
import { ApiError } from '../common/errors/api-error';
import type { IStorageProvider, PutFileInput, StorageHealth, StoredFileRef } from './storage-provider.interface';

/**
 * Used while STORAGE_PROVIDER=none. Every file operation fails loudly with a clear error,
 * and health reports "unknown / not_configured" (never healthy).
 */
export class NotConfiguredStorageProvider implements IStorageProvider {
  readonly name = 'none';

  private fail(): never {
    throw new ApiError(
      HttpStatus.SERVICE_UNAVAILABLE,
      'STORAGE_NOT_CONFIGURED',
      'File storage is not configured. A Super Admin can set a storage provider in Storage settings.',
    );
  }

  async put(_input: PutFileInput): Promise<StoredFileRef> {
    return this.fail();
  }
  async get(_ref: StoredFileRef): Promise<Readable> {
    return this.fail();
  }
  async delete(_ref: StoredFileRef): Promise<void> {
    return this.fail();
  }
  async exists(_ref: StoredFileRef): Promise<boolean> {
    return this.fail();
  }
  async healthCheck(): Promise<StorageHealth> {
    return { state: 'unknown', reason: 'not_configured' };
  }
}
