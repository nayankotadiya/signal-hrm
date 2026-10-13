import { Body, Controller, Delete, Get, HttpCode, Param, Patch, Post, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import { C, Can, Ctx } from '../../common/auth/context';
import { listQuery, objectId, parse } from '../../common/http/validation';
import { employeeInput, EmployeesService, employeeUpdate, sensitiveInput } from './employees.service';

@ApiTags('employees')
@Controller({ path: 'employees', version: '1' })
export class EmployeesController {
  constructor(private readonly svc: EmployeesService) {}

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(
      ctx,
      parse(listQuery.extend({ departmentId: objectId.optional(), teamId: objectId.optional(), locationId: objectId.optional(), managerId: objectId.optional(), archived: z.coerce.boolean().optional() }), q),
    );
  }

  @Post()
  @Can('employees', 'create')
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.create(ctx, parse(employeeInput, body));
  }

  @Get(':id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.get(ctx, id);
  }

  @Patch(':id')
  update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.update(ctx, id, parse(employeeUpdate, body));
  }

  @Patch(':id/sensitive')
  sensitive(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.updateSensitive(ctx, id, parse(sensitiveInput, body));
  }

  @Get(':id/history')
  history(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.historyOf(ctx, id).then((items) => ({ items }));
  }

  @Get(':id/checklists/:kind')
  checklist(@C() ctx: Ctx, @Param('id') id: string, @Param('kind') kind: string) {
    return this.svc.checklist(ctx, id, parse(z.enum(['onboarding', 'offboarding']), kind));
  }

  @Post(':id/checklists/:kind/items/:key')
  @HttpCode(200)
  toggle(@C() ctx: Ctx, @Param('id') id: string, @Param('kind') kind: string, @Param('key') key: string, @Body() body: unknown) {
    return this.svc.toggleChecklistItem(ctx, id, parse(z.enum(['onboarding', 'offboarding']), kind), key, parse(z.object({ done: z.boolean() }), body).done);
  }

  @Post(':id/offboarding')
  offboard(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.startOffboarding(ctx, id, parse(z.object({ lastWorkingDay: z.coerce.date(), reason: z.string().max(500).optional(), note: z.string().max(500).optional() }), body));
  }

  @Post(':id/offboarding/complete')
  @HttpCode(200)
  completeOffboarding(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.completeOffboarding(ctx, id);
  }

  @Delete(':id')
  archive(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.archive(ctx, id);
  }
}
