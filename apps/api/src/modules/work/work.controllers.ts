import { Body, Controller, Delete, Get, HttpCode, Param, Patch, Post, Put, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { z } from 'zod';
import { C, Ctx, Feature, Idempotent } from '../../common/auth/context';
import { dayString, listQuery, objectId, parse } from '../../common/http/validation';
import { TASK_STATUSES } from '../../schemas/work.schemas';
import { activityInput, CrmService, leadInput } from './crm.service';
import { taskInput, TasksService } from './tasks.service';
import { meetingInput, MeetingsService, TravelService, travelInput } from './travel-meetings.service';

@ApiTags('tasks')
@Feature('tasks')
@Controller({ path: 'tasks', version: '1' })
export class TasksController {
  constructor(private readonly svc: TasksService) {}

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(
      ctx,
      parse(
        listQuery.extend({
          view: z.enum(['mine', 'team', 'all']).default('mine'),
          priority: z.string().optional(),
          assigneeId: objectId.optional(),
          dueFrom: dayString.optional(),
          dueTo: dayString.optional(),
          overdue: z.coerce.boolean().optional(),
          tag: z.string().max(30).optional(),
          limit: z.coerce.number().int().min(1).max(500).default(100),
        }),
        q,
      ),
    );
  }

  @Post()
  @Idempotent()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.create(ctx, parse(taskInput, body));
  }

  @Get(':id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.get(ctx, id);
  }

  @Patch(':id')
  update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.update(ctx, id, parse(taskInput.partial(), body));
  }

  @Post(':id/move')
  @HttpCode(200)
  move(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    const b = parse(z.object({ status: z.enum(TASK_STATUSES), beforeId: objectId.optional(), afterId: objectId.optional() }), body);
    return this.svc.move(ctx, id, b.status, b.beforeId, b.afterId);
  }

  @Post(':id/comments')
  comment(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.comment(ctx, id, parse(z.object({ body: z.string().trim().min(1).max(5000) }), body).body);
  }

  @Post(':id/attachments')
  attach(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.attach(ctx, id, parse(z.object({ fileId: objectId }), body).fileId);
  }

  @Delete(':id')
  async remove(@C() ctx: Ctx, @Param('id') id: string) {
    await this.svc.remove(ctx, id);
    return { cancelled: true };
  }
}

@ApiTags('crm')
@Feature('crm')
@Controller({ path: 'crm', version: '1' })
export class CrmController {
  constructor(private readonly svc: CrmService) {}

  @Get('leads')
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(ctx, parse(listQuery.extend({ ownerId: objectId.optional(), source: z.string().optional(), followUpDue: z.coerce.boolean().optional() }), q));
  }

  @Get('pipeline')
  pipeline(@C() ctx: Ctx) {
    return this.svc.pipeline(ctx);
  }

  @Get('follow-ups')
  async followUps(@C() ctx: Ctx) {
    return { items: await this.svc.followUpsDue(ctx) };
  }

  @Post('leads')
  @Idempotent()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    const b = parse(leadInput.extend({ allowDuplicate: z.boolean().default(false) }), body);
    const { allowDuplicate, ...rest } = b;
    return this.svc.create(ctx, rest, { allowDuplicate });
  }

  @Get('leads/:id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.get(ctx, id);
  }

  @Patch('leads/:id')
  update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.update(ctx, id, parse(leadInput.partial().extend({ lostReason: z.string().max(300).optional() }), body));
  }

  @Post('leads/:id/activities')
  activity(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.addActivity(ctx, id, parse(activityInput, body));
  }

  @Post('leads/:id/follow-ups/:activityId/done')
  @HttpCode(200)
  done(@C() ctx: Ctx, @Param('id') id: string, @Param('activityId') activityId: string) {
    return this.svc.completeFollowUp(ctx, id, activityId);
  }

  @Get('sources')
  async sources(@C() ctx: Ctx) {
    return { items: await this.svc.listSources(ctx) };
  }

  @Put('sources/:key')
  source(@C() ctx: Ctx, @Param('key') key: string, @Body() body: unknown) {
    const b = parse(z.object({ name: z.string().trim().min(2).max(60), active: z.boolean().default(true) }), body);
    return this.svc.saveSource(ctx, key.toLowerCase().replace(/[^a-z0-9_]/g, '_'), b.name, b.active);
  }
}

@ApiTags('travel')
@Feature('travel')
@Controller({ path: 'travel', version: '1' })
export class TravelController {
  constructor(private readonly svc: TravelService) {}

  @Get()
  list(@C() ctx: Ctx, @Query() q: unknown) {
    return this.svc.list(ctx, parse(listQuery.extend({ mine: z.coerce.boolean().optional(), from: dayString.optional(), to: dayString.optional() }), q));
  }

  @Post()
  @Idempotent()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.create(ctx, parse(travelInput, body));
  }

  @Get(':id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.get(ctx, id);
  }

  @Post(':id/book')
  @HttpCode(200)
  book(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.book(ctx, id, parse(z.object({ reference: z.string().trim().min(2).max(80), details: z.string().max(1000).optional() }), body));
  }

  @Post(':id/complete')
  @HttpCode(200)
  complete(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.complete(ctx, id);
  }

  @Post(':id/settle')
  @Idempotent()
  @HttpCode(200)
  settle(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.settle(ctx, id, parse(z.object({ note: z.string().max(500).optional() }), body).note);
  }

  @Post(':id/cancel')
  @HttpCode(200)
  cancel(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.cancel(ctx, id);
  }
}

@ApiTags('meetings')
@Feature('meetings')
@Controller({ path: 'meetings', version: '1' })
export class MeetingsController {
  constructor(private readonly svc: MeetingsService) {}

  @Get()
  async list(@C() ctx: Ctx, @Query() q: unknown) {
    const b = parse(z.object({ from: z.coerce.date().optional(), to: z.coerce.date().optional() }), q);
    return { items: await this.svc.list(ctx, b.from ?? new Date(Date.now() - 7 * 86400_000), b.to ?? new Date(Date.now() + 60 * 86400_000)) };
  }

  @Post()
  @Idempotent()
  create(@C() ctx: Ctx, @Body() body: unknown) {
    return this.svc.create(ctx, parse(meetingInput, body));
  }

  @Get(':id')
  get(@C() ctx: Ctx, @Param('id') id: string) {
    return this.svc.get(ctx, id);
  }

  @Patch(':id')
  update(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.update(ctx, id, parse(meetingInput.partial().extend({ status: z.enum(['cancelled', 'ended']).optional() }), body));
  }

  @Post(':id/calls')
  @HttpCode(200)
  call(@C() ctx: Ctx, @Param('id') id: string, @Body() body: unknown) {
    return this.svc.logCall(ctx, id, parse(z.object({ event: z.enum(['joined', 'left']), outcome: z.enum(['completed', 'failed', 'permission_denied', 'network_lost']).optional() }), body));
  }
}
