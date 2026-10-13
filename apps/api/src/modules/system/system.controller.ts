import { Controller, Get, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model } from 'mongoose';
import { z } from 'zod';
import { C, Can, Ctx } from '../../common/auth/context';
import { listQuery, parse } from '../../common/http/validation';
import { DatabaseService } from '../../database/database.service';
import { InjectModel, serialize } from '../../database/model';
import { HealthService } from '../../health/health.service';
import { JobsService } from './jobs.service';
import { MetricsService } from './metrics.service';

/** Database and system health for Super Admin / authorized operators. No secrets or internals. */
@ApiTags('system')
@Controller({ path: 'system', version: '1' })
export class SystemController {
  constructor(
    private readonly health: HealthService,
    private readonly jobs: JobsService,
    private readonly metrics: MetricsService,
    private readonly dbService: DatabaseService,
    @InjectModel('ErrorLog') private readonly errors: Model<any>,
    @InjectModel('Organization') private readonly orgs: Model<any>,
  ) {}

  @Get('overview')
  @Can('system', 'view', 'organization')
  async overview() {
    const [summary, jobs, latency, storageStats] = await Promise.all([
      this.health.summary(),
      this.jobs.summary(),
      this.metrics.recent(60),
      this.dbService.getStorageStats(),
    ]);
    const db = this.orgs.db;
    let database: Record<string, unknown> | null = null;
    try {
      const stats = await db.db!.stats();
      database = {
        collections: stats.collections,
        objects: stats.objects,
        dataSizeMb: Math.round((stats.dataSize / 1048576) * 10) / 10,
        storageSizeMb: Math.round((stats.storageSize / 1048576) * 10) / 10,
        indexes: stats.indexes,
        storagePercentUsed: storageStats.percentUsed,
        storageLimitMb: storageStats.limitMb,
        isAbove90Percent: storageStats.isAbove90Percent,
      };
    } catch {
      database = {
        storagePercentUsed: storageStats.percentUsed,
        storageLimitMb: storageStats.limitMb,
        isAbove90Percent: storageStats.isAbove90Percent,
      };
    }
    return { health: summary, jobs, latency, database, process: { uptimeSeconds: Math.round(process.uptime()), memoryMb: Math.round(process.memoryUsage().rss / 1048576), node: process.version } };
  }

  /** Error log: codes, endpoints and correlation ids; full details only in server logs. */
  @Get('errors')
  @Can('system', 'view', 'organization')
  async errorLog(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(listQuery.extend({ code: z.string().optional() }), q);
    const f: Record<string, unknown> = {};
    if (b.code) f.code = b.code;
    const [items, total] = await Promise.all([this.errors.find(f).sort({ at: -1 }).skip((b.page - 1) * b.limit).limit(b.limit).lean<any[]>(), this.errors.countDocuments(f)]);
    const privileged = ctx.authz.can('system', 'configure', 'organization');
    return { items: serialize(items).map((e: any) => (privileged ? e : { ...e, message: undefined })), page: b.page, limit: b.limit, total, hasMore: b.page * b.limit < total };
  }
}
