import { Injectable, NestMiddleware, OnApplicationShutdown } from '@nestjs/common';
import type { NextFunction, Request, Response } from 'express';
import { Model } from 'mongoose';
import { DatabaseService } from '../../database/database.service';
import { InjectModel } from '../../database/model';

/**
 * Per-minute request counts, server errors and latency (avg, max, p95), flushed to request_metrics.
 * Feeds the API latency sparkline and the uptime report. No request content is stored.
 */
@Injectable()
export class MetricsService implements OnApplicationShutdown {
  private minute = 0;
  private durations: number[] = [];
  private errors = 0;
  private timer: NodeJS.Timeout;

  constructor(
    private readonly db: DatabaseService,
    @InjectModel('RequestMetric') private readonly metrics: Model<any>,
  ) {
    this.timer = setInterval(() => void this.flush(), 15_000);
    this.timer.unref();
  }

  record(ms: number, status: number): void {
    const m = Math.floor(Date.now() / 60_000);
    if (m !== this.minute) void this.flush(m);
    this.durations.push(ms);
    if (status >= 500) this.errors++;
  }

  private async flush(next?: number): Promise<void> {
    const minute = this.minute;
    const d = this.durations;
    const errors = this.errors;
    if (next !== undefined) this.minute = next;
    else if (Math.floor(Date.now() / 60_000) === minute) return; // still accumulating
    else this.minute = Math.floor(Date.now() / 60_000);
    this.durations = [];
    this.errors = 0;
    if (!d.length || !minute || !this.db.ready) return;
    const sorted = d.slice().sort((a, b) => a - b);
    const p95 = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.95))];
    await this.metrics
      .updateOne({ minute: new Date(minute * 60_000) }, { $inc: { count: d.length, errors, totalMs: d.reduce((a, b) => a + b, 0) }, $max: { maxMs: sorted[sorted.length - 1], p95Ms: p95 } }, { upsert: true })
      .catch(() => undefined);
  }

  async recent(minutes = 60): Promise<{ minute: Date; count: number; avgMs: number; p95Ms: number; errors: number }[]> {
    const rows = await this.metrics.find({ minute: { $gte: new Date(Date.now() - minutes * 60_000) } }).sort({ minute: 1 }).lean<any[]>();
    return rows.map((r) => ({ minute: r.minute, count: r.count, avgMs: r.count ? Math.round(r.totalMs / r.count) : 0, p95Ms: Math.round(r.p95Ms ?? 0), errors: r.errors ?? 0 }));
  }

  onApplicationShutdown(): void {
    clearInterval(this.timer);
  }
}

@Injectable()
export class MetricsMiddleware implements NestMiddleware {
  constructor(private readonly metrics: MetricsService) {}

  use(req: Request, res: Response, next: NextFunction): void {
    const start = process.hrtime.bigint();
    res.on('finish', () => {
      if (req.path.includes('/health')) return; // probes would skew latency
      this.metrics.record(Number(process.hrtime.bigint() - start) / 1e6, res.statusCode);
    });
    next();
  }
}
