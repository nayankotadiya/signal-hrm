import { Inject, Injectable, Logger, OnApplicationShutdown, OnModuleInit } from '@nestjs/common';
import Redis from 'ioredis';
import { APP_CONFIG } from '../config/config.module';
import type { AppEnv } from '../config/env.schema';

/** Shared Redis client for cache, rate-limit storage, idempotency keys and queues (later phases). */
@Injectable()
export class RedisService implements OnModuleInit, OnApplicationShutdown {
  private readonly logger = new Logger('Redis');
  private redis?: Redis;

  constructor(@Inject(APP_CONFIG) private readonly env: AppEnv) {}

  get configured(): boolean {
    return Boolean(this.env.REDIS_URL);
  }

  get client(): Redis | undefined {
    return this.redis;
  }

  onModuleInit(): void {
    if (!this.env.REDIS_URL) {
      this.logger.warn('REDIS_URL is not set. Running without Redis (development only).');
      return;
    }
    this.redis = new Redis(this.env.REDIS_URL, {
      lazyConnect: false,
      enableOfflineQueue: false,
      maxRetriesPerRequest: 1,
      retryStrategy: (times) => Math.min(times * 500, 10_000),
    });
    this.redis.on('ready', () => this.logger.log('Redis ready'));
    this.redis.on('error', () => undefined); // state is surfaced through health checks; avoid log floods
  }

  async ping(): Promise<void> {
    if (!this.redis || this.redis.status !== 'ready') throw new Error('not connected');
    await this.redis.ping();
  }

  get status(): string {
    return this.redis?.status ?? 'disconnected';
  }

  async onApplicationShutdown(): Promise<void> {
    this.redis?.disconnect();
  }
}
