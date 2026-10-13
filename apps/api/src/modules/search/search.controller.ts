import { Controller, Get, Query } from '@nestjs/common';
import { ApiTags } from '@nestjs/swagger';
import { Throttle } from '@nestjs/throttler';
import { z } from 'zod';
import { C, Ctx } from '../../common/auth/context';
import { parse } from '../../common/http/validation';
import { SEARCH_TYPES, SearchService } from './search.service';

@ApiTags('search')
@Controller({ path: 'search', version: '1' })
export class SearchController {
  constructor(private readonly svc: SearchService) {}

  @Get()
  @Throttle({ default: { limit: 60, ttl: 60_000 } })
  search(@C() ctx: Ctx, @Query() query: unknown) {
    const q = parse(
      z.object({
        q: z.string().max(80).default(''),
        types: z.string().optional().transform((v) => (v ? v.split(',').filter((t): t is (typeof SEARCH_TYPES)[number] => (SEARCH_TYPES as readonly string[]).includes(t)) : [])),
        limit: z.coerce.number().int().min(1).max(20).default(5),
      }),
      query,
    );
    return this.svc.search(ctx, q.q, q.types, q.limit);
  }
}
