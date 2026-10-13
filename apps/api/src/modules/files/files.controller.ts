import { Body, Controller, Get, Param, Post, Query, Res, UploadedFile, UseInterceptors } from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { ApiTags } from '@nestjs/swagger';
import type { Response } from 'express';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import { C, Can, Ctx } from '../../common/auth/context';
import { badRequest, listQuery, objectId, parse } from '../../common/http/validation';
import { FilePurpose, FilesService } from './files.service';

const PURPOSES = ['document', 'receipt', 'selfie', 'avatar', 'attachment', 'logo'] as const;

@ApiTags('files')
@Controller({ path: 'files', version: '1' })
export class FilesController {
  constructor(
    private readonly files: FilesService,
    private readonly audit: AuditService,
  ) {}

  /** Multipart upload (field "file"). The file must then be linked by the record that uses it. */
  @Post()
  @UseInterceptors(FileInterceptor('file', { limits: { fileSize: 26 * 1024 * 1024, files: 1 } }))
  async upload(@C() ctx: Ctx, @UploadedFile() file: Express.Multer.File | undefined, @Body() body: unknown) {
    if (!file) throw badRequest('FILE_REQUIRED', 'Choose a file to upload.', 'file');
    const b = parse(z.object({ purpose: z.enum(PURPOSES), folderId: objectId.optional() }), body);
    if (b.purpose === 'logo' && !ctx.authz.can('organization', 'configure')) throw badRequest('PURPOSE_INVALID', 'Only administrators can upload the logo.');
    return this.files.upload(ctx, { buffer: file.buffer, originalName: file.originalname, mimeType: file.mimetype, purpose: b.purpose as FilePurpose, folderId: b.folderId });
  }

  /** Streams the file after checking access. Files are never exposed as provider links. */
  @Get(':id/content')
  async content(@C() ctx: Ctx, @Param('id') id: string, @Query('download') download: string | undefined, @Res() res: Response) {
    const { stream, file } = await this.files.open(ctx, id);
    if (!['avatar', 'logo'].includes(file.purpose)) await this.audit.record(ctx, { action: 'file.download', resourceType: 'file', resourceId: id });
    res.setHeader('Content-Type', file.mimeType);
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Cache-Control', file.purpose === 'avatar' || file.purpose === 'logo' ? 'private, max-age=3600' : 'private, no-store');
    res.setHeader('Content-Disposition', `${download ? 'attachment' : 'inline'}; filename="${encodeURIComponent(file.name)}"`);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  }

  @Get()
  @Can('storage', 'view', 'organization')
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.files.list(ctx, parse(listQuery.extend({ purpose: z.string().optional(), folderId: objectId.optional() }), q));
  }

  @Get('usage/summary')
  @Can('storage', 'view', 'organization')
  usage(@C() ctx: Ctx) {
    return this.files.usage(ctx.orgOid);
  }

  @Get('folders/all')
  @Can('storage', 'view', 'organization')
  async folders(@C() ctx: Ctx) {
    return { items: await this.files.listFolders(ctx) };
  }

  @Post('folders')
  @Can('storage', 'manage', 'organization')
  folder(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(z.object({ name: z.string().trim().min(1).max(60).regex(/^[\w -]+$/), parentId: objectId.optional() }), body);
    return this.files.createFolder(ctx, b.name, b.parentId);
  }
}
