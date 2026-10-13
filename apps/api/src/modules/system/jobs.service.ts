import { Injectable, Logger } from '@nestjs/common';
import { Model } from 'mongoose';
import { DatabaseService } from '../../database/database.service';
import { InjectModel } from '../../database/model';

/**
 * Wraps background jobs: skips when the database is down, prevents overlapping runs in this
 * process, and records every run in job_runs so health can report failing jobs.
 */
@Injectable()
export class JobsService {
  private readonly logger = new Logger('Jobs');
  private running = new Set<string>();

  constructor(
    private readonly db: DatabaseService,
    @InjectModel('JobRun') private readonly runs: Model<any>,
  ) {}

  async run(job: string, fn: () => Promise<string | void>): Promise<void> {
    if (!this.db.ready || this.running.has(job)) return;
    this.running.add(job);
    const started = Date.now();
    let record: any;
    try {
      record = await this.runs.create({ job, status: 'running', startedAt: new Date() });
      const detail = await fn();
      await this.runs.updateOne({ _id: record._id }, { $set: { status: 'succeeded', finishedAt: new Date(), durationMs: Date.now() - started, detail: detail ?? undefined } });
    } catch (e) {
      this.logger.error(`${job} failed: ${(e as Error).message}`);
      if (record) await this.runs.updateOne({ _id: record._id }, { $set: { status: 'failed', finishedAt: new Date(), durationMs: Date.now() - started, error: (e as Error).message.slice(0, 300) } }).catch(() => undefined);
    } finally {
      this.running.delete(job);
    }
  }

  /** Latest run per job and recent failure counts. */
  async summary(): Promise<{ job: string; lastStatus: string; lastRunAt: Date; failures24h: number }[]> {
    const since = new Date(Date.now() - 86400_000);
    const rows = await this.runs.aggregate([
      { $match: { startedAt: { $gt: since } } },
      { $sort: { startedAt: -1 } },
      { $group: { _id: '$job', lastStatus: { $first: '$status' }, lastRunAt: { $first: '$startedAt' }, failures24h: { $sum: { $cond: [{ $eq: ['$status', 'failed'] }, 1, 0] } } } },
      { $sort: { _id: 1 } },
    ]);
    return rows.map((r: any) => ({ job: r._id, lastStatus: r.lastStatus, lastRunAt: r.lastRunAt, failures24h: r.failures24h }));
  }
}
