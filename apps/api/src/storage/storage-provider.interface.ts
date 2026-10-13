import type { Readable } from 'node:stream';

export const STORAGE_PROVIDER = Symbol('STORAGE_PROVIDER');

export interface StoredFileRef {
  /** e.g. "google_drive", "r2", "s3" */
  provider: string;
  /** Provider's own ID. Never a public URL. */
  providerFileId: string;
  mimeType: string;
  sizeBytes: number;
  /** sha256 hex when the provider or upload path can compute it */
  checksum?: string;
}

export interface PutFileInput {
  organizationId: string;
  /** Logical folder such as "attendance-evidence/2026-10" */
  folder: string;
  fileName: string;
  mimeType: string;
  body: Buffer | Readable;
  sizeBytes: number;
}

export interface StorageHealth {
  state: 'healthy' | 'degraded' | 'unavailable' | 'unknown';
  reason: 'ok' | 'not_configured' | 'not_implemented' | 'timeout' | 'check_failed' | 'slow_response';
  latencyMs?: number;
}

/**
 * Backend-only storage abstraction. Business modules depend on this interface, never on Google Drive,
 * so a Cloudflare R2 or S3-compatible provider can replace Drive without touching them.
 * Clients never receive provider credentials or unrestricted links; downloads stream through the API
 * after a permission check, or use short-lived signed URLs where the provider supports them.
 */
export interface IStorageProvider {
  readonly name: string;
  put(input: PutFileInput): Promise<StoredFileRef>;
  get(ref: StoredFileRef): Promise<Readable>;
  delete(ref: StoredFileRef): Promise<void>;
  exists(ref: StoredFileRef): Promise<boolean>;
  healthCheck(): Promise<StorageHealth>;
}
