import { Body, Controller, Delete, Get, Param, Post, Put, Query, Res } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { z } from 'zod';
import { C, Can, Ctx } from '../../common/auth/context';
import { parse } from '../../common/http/validation';
import { reportFilters, ReportsService } from './reports.service';

const savedBody = z.object({
  name: z.string().trim().min(2).max(80),
  reportKey: z.string(),
  filters: reportFilters.default({}),
  chart: z.string().max(20).optional(),
  fields: z.array(z.string()).max(30).optional(),
  pinned: z.boolean().default(false),
  schedule: z.object({ cron: z.string().max(40).optional(), emailTo: z.array(z.string().email()).max(10).optional(), format: z.enum(['csv']).optional() }).optional(),
});

@ApiTags('reports')
@Controller({ path: 'reports', version: '1' })
export class ReportsController {
  constructor(private readonly svc: ReportsService) {}

  @Get()
  @Can('reports', 'view')
  catalog(@C() ctx: Ctx) {
    return { items: this.svc.list(ctx) };
  }

  @Get('saved')
  async saved(@C() ctx: Ctx) {
    return { items: await this.svc.listSaved(ctx) };
  }

  @Post('saved')
  save(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.save(ctx, parse(savedBody, body));
  }

  @Put('saved/:id')
  update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.save(ctx, parse(savedBody, body), id);
  }

  @Delete('saved/:id')
  async remove(@C() ctx: Ctx, @Param('id') id: string) {
    await this.svc.deleteSaved(ctx, id);
    return { deleted: true };
  }

  @Get(':key')
  run(@C() ctx: Ctx, @Param('key') key: string, @Query() q: unknown) {
    return this.svc.run(ctx, key, parse(reportFilters, q));
  }

  @Get(':key/export')
  async export(@C() ctx: Ctx, @Param('key') key: string, @Query() q: unknown, @Res() res: Response) {
    const { csv, filename } = await this.svc.export(ctx, key, parse(reportFilters, q));
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="${filename.replace(/[^\w.-]/g, '_')}"`);
    res.setHeader('Cache-Control', 'no-store');
    res.send('﻿' + csv);
  }
}
