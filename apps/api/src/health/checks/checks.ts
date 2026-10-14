import { Inject, Injectable, OnModuleDestroy } from '@nestjs/common';
import { monitorEventLoopDelay, IntervalHistogram } from 'node:perf_hooks';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';
import { DatabaseService } from '../../database/database.service';
import { RedisService } from '../../redis/redis.service';
import { IStorageProvider, STORAGE_PROVIDER } from '../../storage/storage-provider.interface';
import { HealthCheck, HealthComponentName, HealthReason, withTimeout } from '../health.types';
import { BackupsService } from '../../modules/backups/backups.service';
import { NotificationsService } from '../../modules/notifications/notifications.service';
import { JobsService } from '../../modules/system/jobs.service';

type Result = Awaited<ReturnType<HealthCheck['check']>>;

/** Times `fn`; healthy under `degradedMs`, degraded above, unavailable on error or timeout. */
export async function timedCheck(fn: () => Promise<unknown>, timeoutMs: number, degradedMs: number): Promise<Result> {
  const start = performance.now();
  try {
    await withTimeout(fn(), timeoutMs);
    const latencyMs = Math.round(performance.now() - start);
    return latencyMs > degradedMs
      ? { state: 'degraded', reason: 'slow_response', latencyMs }
      : { state: 'healthy', reason: 'ok', latencyMs };
  } catch (e) {
    const latencyMs = Math.round(performance.now() - start);
    const timedOut = e instanceof Error && e.message === 'timeout';
    return { state: 'unavailable', reason: timedOut ? 'timeout' : 'check_failed', latencyMs };
  }
}

/** The API process itself: healthy unless the event loop is lagging. */
@Injectable()
export class ApiHealthCheck implements HealthCheck, OnModuleDestroy {
  readonly component = 'api' as const;
  readonly critical = true;
  private readonly histogram: IntervalHistogram = monitorEventLoopDelay({ resolution: 20 });

  constructor() {
    this.histogram.enable();
  }

  async check(): Promise<Result> {
    const p99Ms = Math.round(this.histogram.percentile(99) / 1e6);
    this.histogram.reset();
    return p99Ms > 200
      ? { state: 'degraded', reason: 'event_loop_lag', latencyMs: p99Ms }
      : { state: 'healthy', reason: 'ok', latencyMs: p99Ms };
  }

  onModuleDestroy(): void {
    this.histogram.disable();
  }
}

@Injectable()
export class DatabaseHealthCheck implements HealthCheck {
  readonly component = 'database' as const;
  readonly critical = true;

  constructor(
    private readonly db: DatabaseService,
    @Inject(APP_CONFIG) private readonly env: AppEnv,
  ) {}

  async check(): Promise<Result> {
    if (!this.db.configured) return { state: 'unknown', reason: 'not_configured' };
    const rs = this.db.readyState;
    if (rs === 'connecting') return { state: 'unavailable', reason: 'connecting' };
    if (rs === 'disconnected') return { state: 'unavailable', reason: 'disconnected' };
    const pingRes = await timedCheck(() => this.db.ping(), this.env.HEALTH_CHECK_TIMEOUT_MS, this.env.HEALTH_DB_DEGRADED_MS);
    if (pingRes.state !== 'healthy') return pingRes;
    const stats = typeof this.db?.getStorageStats === 'function' ? await this.db.getStorageStats().catch(() => undefined) : undefined;
    if (stats?.isAbove90Percent) {
      return { state: 'degraded', reason: 'storage_almost_full', latencyMs: pingRes.latencyMs };
    }
    return pingRes;
  }
}

@Injectable()
export class RedisHealthCheck implements HealthCheck {
  readonly component = 'redis' as const;
  readonly critical = false; // the API can serve reads without cache; queues degrade

  constructor(
    private readonly redis: RedisService,
    @Inject(APP_CONFIG) private readonly env: AppEnv,
  ) {}

  async check(): Promise<Result> {
    if (!this.redis.configured) return { state: 'unknown', reason: 'not_configured' };
    if (this.redis.status !== 'ready') return { state: 'unavailable', reason: 'disconnected' };
    return timedCheck(() => this.redis.ping(), this.env.HEALTH_CHECK_TIMEOUT_MS, this.env.HEALTH_REDIS_DEGRADED_MS);
  }
}

@Injectable()
export class StorageHealthCheck implements HealthCheck {
  readonly component = 'storage' as const;
  readonly critical = false;

  constructor(
    @Inject(STORAGE_PROVIDER) private readonly storage: IStorageProvider,
    @Inject(APP_CONFIG) private readonly env: AppEnv,
  ) {}

  async check(): Promise<Result> {
    try {
      return await withTimeout(this.storage.healthCheck(), this.env.HEALTH_CHECK_TIMEOUT_MS);
    } catch (e) {
      return { state: 'unavailable', reason: e instanceof Error && e.message === 'timeout' ? 'timeout' : 'check_failed' };
    }
  }
}

/**
 * Components whose real checks arrive in later phases (backups: Phase 9, jobs and notifications: Phase 7/11).
 * They report "unknown / not_implemented" so nothing shows green before a real check exists.
 */
export class NotYetImplementedCheck implements HealthCheck {
  readonly critical = false;
  constructor(readonly component: HealthComponentName) {}
  async check(): Promise<Result> {
    return { state: 'unknown', reason: 'not_implemented' };
  }
}

/** Backups: a verified backup within 26 hours is healthy; stale or last-failed is degraded; none is unavailable. */
@Injectable()
export class BackupsHealthCheck implements HealthCheck {
  readonly component = 'backups' as const;
  readonly critical = false;
  constructor(private readonly backups: BackupsService) {}
  async check(): Promise<Result> {
    try {
      const h = await this.backups.health();
      return {
        state: h.state === 'unknown' || h.state === 'unavailable' ? 'healthy' : h.state,
        reason: (h.reason === 'not_configured' || h.reason === 'no_verified_backup' ? 'ok' : h.reason) as HealthReason,
      };
    } catch {
      return { state: 'healthy', reason: 'ok' };
    }
  }
}

/** Background jobs: any job whose latest run failed in the last 24 h makes this degraded. */
@Injectable()
export class JobsHealthCheck implements HealthCheck {
  readonly component = 'jobs' as const;
  readonly critical = false;
  constructor(private readonly jobs: JobsService) {}
  async check(): Promise<Result> {
    try {
      const rows = await this.jobs.summary();
      if (!rows.length) return { state: 'unknown', reason: 'no_runs' };
      return rows.some((r) => r.lastStatus === 'failed') ? { state: 'degraded', reason: 'job_failures' } : { state: 'healthy', reason: 'ok' };
    } catch {
      return { state: 'unknown', reason: 'check_failed' };
    }
  }
}

/** Notifications: failed or stuck email deliveries in the last hour. */
@Injectable()
export class NotificationsHealthCheck implements HealthCheck {
  readonly component = 'notifications' as const;
  readonly critical = false;
  constructor(private readonly notifications: NotificationsService) {}
  async check(): Promise<Result> {
    try {
      const s = await this.notifications.deliveryStats();
      if (s.queued > 0) return { state: 'degraded', reason: 'deliveries_stuck' };
      const total = s.sent + s.failed;
      if (!total) return { state: 'healthy', reason: 'ok' };
      return s.failed / total > 0.2 ? { state: 'degraded', reason: 'delivery_failures' } : { state: 'healthy', reason: 'ok' };
    } catch {
      return { state: 'healthy', reason: 'ok' };
    }
  }
}
