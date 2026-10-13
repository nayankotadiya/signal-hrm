import { Body, Controller, Get, HttpCode, Param, Patch, Post, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import { C, Ctx, Feature, Idempotent } from '../../common/auth/context';
import { listQuery, objectId, parse } from '../../common/http/validation';
import { documentInput, DocumentsService } from './documents.service';

@ApiTags('documents')
@Feature('documents')
@Controller({ path: 'documents', version: '1' })
export class DocumentsController {
  constructor(private readonly svc: DocumentsService) {}

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(ctx, parse(listQuery.extend({ category: z.string().optional(), policies: z.coerce.boolean().optional(), employeeId: objectId.optional(), mine: z.coerce.boolean().optional(), expiringDays: z.coerce.number().int().min(1).max(365).optional() }), q));
  }

  @Get('acknowledgements/pending')
  async pending(@C() ctx: Ctx) {
    return { items: await this.svc.pendingAcknowledgements(ctx) };
  }

  @Post()
  @Idempotent()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.create(ctx, parse(documentInput, body));
  }

  @Post('letters')
  @Idempotent()
  letter(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.object({ kind: z.enum(['employment', 'salary_certificate']), employeeId: objectId.optional(), purpose: z.string().max(200).optional() }), body);
    return this.svc.generateLetter(ctx, b.kind, b.employeeId, b.purpose);
  }

  @Get(':id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.get(ctx, id);
  }

  @Patch(':id')
  update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.update(ctx, id, parse(documentInput.omit({ fileId: true }).partial().extend({ status: z.enum(['active', 'archived']).optional() }), body));
  }

  @Post(':id/versions')
  @Idempotent()
  version(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(z.object({ fileId: objectId, note: z.string().max(300).optional() }), body);
    return this.svc.addVersion(ctx, id, b.fileId, b.note);
  }

  @Post(':id/acknowledge')
  @HttpCode(200)
  acknowledge(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.acknowledge(ctx, id);
  }

  @Get(':id/access-log')
  async log(@C() ctx: Ctx, @Param('id') id: string) {
    return { items: await this.svc.accessLog(ctx, id) };
  }
}
