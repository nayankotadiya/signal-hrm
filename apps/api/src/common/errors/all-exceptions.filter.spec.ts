import { HttpStatus, NotFoundException } from '@nestjs/common';
import { z } from 'zod';
import { ApiError } from './api-error';
import { AllExceptionsFilter } from './all-exceptions.filter';

describe('AllExceptionsFilter.toBody', () => {
  const filter = new AllExceptionsFilter();

  it('keeps business error codes and field details', () => {
    const body = filter.toBody(
      new ApiError(HttpStatus.CONFLICT, 'LEAVE_OVERLAP', 'These dates overlap an existing request.', [
        { field: 'startDate', message: 'Overlaps request LR-12' },
      ]),
      'corr-12345678',
    );
    expect(body.error).toEqual({
      status: 409,
      code: 'LEAVE_OVERLAP',
      message: 'These dates overlap an existing request.',
      details: [{ field: 'startDate', message: 'Overlaps request LR-12' }],
      correlationId: 'corr-12345678',
    });
  });

  it('maps zod validation errors to 422 with dot-path fields', () => {
    const result = z.object({ dates: z.object({ end: z.string() }) }).safeParse({ dates: {} });
    const body = filter.toBody(!result.success ? result.error : null, 'c-00000001');
    expect(body.error.status).toBe(422);
    expect(body.error.details?.[0].field).toBe('dates.end');
  });

  it('maps Nest HTTP exceptions to stable codes', () => {
    const body = filter.toBody(new NotFoundException('No such route'), 'c-00000002');
    expect(body.error.code).toBe('NOT_FOUND');
    expect(body.error.status).toBe(404);
  });

  it('never leaks internal error text', () => {
    const body = filter.toBody(new Error('MongoServerError: auth failed for mongodb+srv://admin:pw@x'), 'c-00000003');
    expect(body.error.status).toBe(500);
    expect(JSON.stringify(body)).not.toMatch(/mongodb|admin|pw@/);
    expect(body.error.correlationId).toBe('c-00000003');
  });
});
