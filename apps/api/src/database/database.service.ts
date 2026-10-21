import * as dns from 'node:dns';
import { Inject, Injectable, Logger, OnApplicationShutdown, OnModuleInit } from '@nestjs/common';
import mongoose, { Connection } from 'mongoose';
import { APP_CONFIG } from '../config/config.module';
import type { AppEnv } from '../config/env.schema';

/**
 * Owns the single MongoDB connection. Connecting happens in the background so the API can
 * start, report "unavailable" honestly, and recover when Atlas comes back, instead of crashing.
 * Feature modules (Phase 2+) register their schemas on `connection`.
 */
@Injectable()
export class DatabaseService implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger('Database');
  private conn?: Connection;

  constructor(@Inject(APP_CONFIG) private readonly env: AppEnv) {}

  get configured(): boolean {
    return Boolean(this.env.MONGODB_URI);
  }

  /** Created on first use: model providers are built before lifecycle hooks run. */
  get connection(): Connection {
    if (!this.conn) this.init();
    return this.conn!;
  }

  /** True when connected and usable. Routes other than health return 503 otherwise. */
  get ready(): boolean {
    return this.readyState === 'connected';
  }

  onModuleInit(): void {
    if (!this.conn) this.init();
  }

  private init(): void {
    if (!this.env.MONGODB_URI) {
      this.logger.warn('MONGODB_URI is not set. Running without a database (development only).');
      // An unopened connection still lets models register; data routes answer 503 until configured.
      this.conn = mongoose.createConnection();
      this.conn.set('bufferCommands', false);
      return;
    }
    if (this.env.MONGODB_URI.startsWith('mongodb+srv://')) {
      try {
        const current = dns.getServers();
        if (!current.includes('8.8.8.8')) {
          dns.setServers(['8.8.8.8', '8.8.4.4', ...current]);
        }
      } catch {
        // ignore if custom dns servers cannot be applied
      }
    }
    this.conn = mongoose.createConnection(this.env.MONGODB_URI, {
      dbName: this.env.MONGODB_DB_NAME,
      serverSelectionTimeoutMS: 5_000,
      autoIndex: this.env.APP_ENV !== 'production', // production indexes are created by migrations
    });
    this.conn.on('connected', () => this.logger.log(`Connected to database "${this.env.MONGODB_DB_NAME}"`));
    this.conn.on('disconnected', () => this.logger.warn('Database disconnected'));
    // The error text can contain hosts; log a generic message only.
    this.conn.on('error', () => this.logger.error('Database connection error (see driver logs on the server)'));
    this.conn.asPromise().catch(() => undefined);
  }

  /** 'connected' | 'connecting' | 'disconnected' */
  get readyState(): 'connected' | 'connecting' | 'disconnected' {
    if (!this.configured) return 'disconnected';
    const s = this.conn?.readyState;
    if (s === 1) return 'connected';
    if (s === 2) return 'connecting';
    return 'disconnected';
  }

  async ping(): Promise<void> {
    if (!this.conn?.db) throw new Error('not connected');
    await this.conn.db.admin().command({ ping: 1 });
  }

  private cachedStorageStats?: { stats: any; expiresAt: number };

  /**
   * Queries dbStats to monitor MongoDB Atlas storage capacity.
   * Calculates storage usage and whether it exceeds the 90% threshold.
   */
  async getStorageStats(): Promise<{
    dataSizeMb: number;
    storageSizeMb: number;
    indexSizeMb: number;
    totalSizeMb: number;
    limitMb: number;
    percentUsed: number;
    isAbove90Percent: boolean;
  }> {
    const now = Date.now();
    if (this.cachedStorageStats && now < this.cachedStorageStats.expiresAt) {
      return this.cachedStorageStats.stats;
    }
    if (!this.conn?.db) {
      return { dataSizeMb: 0, storageSizeMb: 0, indexSizeMb: 0, totalSizeMb: 0, limitMb: this.env.MONGODB_STORAGE_LIMIT_MB ?? 512, percentUsed: 0, isAbove90Percent: false };
    }
    try {
      const stats: any = await this.conn.db.command({ dbStats: 1 });
      const dataSizeMb = Math.round(((Number(stats.dataSize) || 0) / (1024 * 1024)) * 10) / 10;
      const storageSizeMb = Math.round(((Number(stats.storageSize) || 0) / (1024 * 1024)) * 10) / 10;
      const indexSizeMb = Math.round(((Number(stats.indexSize) || 0) / (1024 * 1024)) * 10) / 10;
      const totalSizeMb = Math.round((storageSizeMb + indexSizeMb || dataSizeMb) * 10) / 10;

      const fsTotalMb = stats.fsTotalSize ? Math.round(Number(stats.fsTotalSize) / (1024 * 1024)) : undefined;
      const fsUsedMb = stats.fsUsedSize ? Math.round(Number(stats.fsUsedSize) / (1024 * 1024)) : undefined;
      const limitMb = this.env.MONGODB_STORAGE_LIMIT_MB ?? (fsTotalMb && fsTotalMb > 0 ? fsTotalMb : 512);

      const usedMb = fsUsedMb && fsTotalMb ? fsUsedMb : totalSizeMb;
      const percentUsed = limitMb > 0 ? Math.min(100, Math.round((usedMb / limitMb) * 1000) / 10) : 0;
      const isAbove90Percent = percentUsed >= 90;

      const result = {
        dataSizeMb,
        storageSizeMb,
        indexSizeMb,
        totalSizeMb,
        limitMb,
        percentUsed,
        isAbove90Percent,
      };
      this.cachedStorageStats = { stats: result, expiresAt: now + 60_000 };
      return result;
    } catch {
      return { dataSizeMb: 0, storageSizeMb: 0, indexSizeMb: 0, totalSizeMb: 0, limitMb: this.env.MONGODB_STORAGE_LIMIT_MB ?? 512, percentUsed: 0, isAbove90Percent: false };
    }
  }

  async onApplicationShutdown(): Promise<void> {
    await this.conn?.close().catch(() => undefined);
  }
}
