import { Body, Controller, Delete, Get, HttpCode, Param, Post, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { z } from 'zod';
import { C, Ctx, Idempotent, RequireReauth } from '../../common/auth/context';
import { parse } from '../../common/http/validation';
import { BackupsService } from './backups.service';

@ApiTags('backups')
@Controller({ path: 'backups', version: '1' })
export class BackupsController {
  constructor(private readonly svc: BackupsService) {}

  @Get()
  list(@C() ctx: Ctx) {
    return this.svc.list(ctx);
  }

  @Get(':id/download')
  @RequireReauth()
  async download(@C() ctx: Ctx, @Param('id') id: string, @Res() res: Response) {
    const { stream, fileName, sizeBytes } = await this.svc.download(ctx, id);
    res.setHeader('Content-Type', 'application/gzip');
    res.setHeader('Content-Disposition', `attachment; filename="${fileName}"`);
    if (sizeBytes) {
      res.setHeader('Content-Length', sizeBytes);
    }
    stream.pipe(res);
  }

  @Post()
  @Idempotent()
  @RequireReauth()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.createManual(ctx, parse(z.object({ kind: z.enum(['manual', 'pre_deployment']).default('manual') }), body).kind);
  }

  @Post(':id/verify')
  @HttpCode(200)
  verify(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.reverify(ctx, id);
  }

  @Post('restore-test')
  @HttpCode(200)
  test(@C() ctx: Ctx) {
    return this.svc.runRestoreTest(ctx);
  }

  /** Restore: Super Admin + re-authentication + typed confirmation + verified safety backup first. */
  @Post(':id/restore')
  @Idempotent()
  @RequireReauth()
  @HttpCode(200)
  restore(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.restore(ctx, id, parse(z.object({ confirmation: z.string() }), body).confirmation);
  }

  @Delete(':id')
  @RequireReauth()
  remove(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.deleteBackup(ctx, id);
  }
}
