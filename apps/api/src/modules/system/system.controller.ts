import { Controller, Get, Post, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Model } from 'mongoose';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import { C, Can, Ctx } from '../../common/auth/context';
import { forbidden, listQuery, parse } from '../../common/http/validation';
import { DatabaseService } from '../../database/database.service';
import { InjectModel, serialize } from '../../database/model';
import { MODELS } from '../../database/models.module';
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
    private readonly audit: AuditService,
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

  /** One-click purge of all demo data (demo orgs, demo employees, demo attendance, demo leaves) for Super Admin. */
  @Post('purge-demo-data')
  @Can('system', 'configure', 'organization')
  async purgeDemoData(@C() ctx: Ctx) {
    if (!ctx.authz.isSuperAdmin) {
      throw forbidden('SUPER_ADMIN_ONLY', 'Only Super Admin can purge demo data.');
    }

    const m = (n: string): Model<any> => this.dbService.connection.model(n);
    let removedOrgs = 0;
    let removedEmployees = 0;
    let removedAttendance = 0;
    let removedLeaves = 0;
    let removedUsers = 0;

    // 1. Clean separate demo organizations (e.g. "Signal HRM Demo")
    const demoOrgs = await m('Organization')
      .find({
        _id: { $ne: ctx.orgOid },
        $or: [{ name: 'Signal HRM Demo' }, { name: { $regex: /demo/i } }],
      })
      .lean<any[]>();

    for (const demoOrg of demoOrgs) {
      for (const name of Object.keys(MODELS)) {
        if (name === 'AuditLog' || name === 'Organization') continue;
        const model = m(name);
        if (model.schema && model.schema.path('organizationId')) {
          await model.deleteMany({ organizationId: demoOrg._id });
        }
      }
      await m('Organization').deleteOne({ _id: demoOrg._id });
      removedOrgs++;
    }

    // 2. Clean demo employees (employeeCode DEMO-*, or email @demo.signal-hrm.test)
    const demoEmps = await m('Employee')
      .find({
        $or: [
          { employeeCode: { $regex: /^DEMO-/i } },
          { contactEmail: { $regex: /demo\.signal-hrm\.test/i } },
        ],
      })
      .lean<any[]>();

    if (demoEmps.length > 0) {
      const empIds = demoEmps.map((e) => e._id);
      const userEmails = demoEmps.map((e) => e.contactEmail).filter(Boolean);

      const attRes = await m('Attendance').deleteMany({ employeeId: { $in: empIds } });
      removedAttendance += attRes.deletedCount || 0;

      const leaveRes = await m('LeaveRequest').deleteMany({ employeeId: { $in: empIds } });
      removedLeaves += leaveRes.deletedCount || 0;
      await m('LeaveBalance').deleteMany({ employeeId: { $in: empIds } });

      const userRes = await m('User').deleteMany({
        _id: { $ne: ctx.userOid },
        $or: [
          { employeeId: { $in: empIds } },
          { email: { $in: userEmails, $regex: /demo\.signal-hrm\.test/i } },
        ],
      });
      removedUsers += userRes.deletedCount || 0;

      const empRes = await m('Employee').deleteMany({ _id: { $in: empIds } });
      removedEmployees += empRes.deletedCount || 0;
    }

    await this.audit.record(ctx, {
      action: 'system.purge_demo_data',
      resourceType: 'system',
      resourceId: 'demo_data',
      outcome: 'success',
    });

    return {
      ok: true,
      message: `Successfully purged ${removedEmployees} demo employee(s), ${removedAttendance} attendance record(s), and ${removedOrgs} demo organization(s).`,
      removed: {
        employees: removedEmployees,
        attendance: removedAttendance,
        leaves: removedLeaves,
        users: removedUsers,
        organizations: removedOrgs,
      },
    };
  }
}
