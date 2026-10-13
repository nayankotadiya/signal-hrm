import { HttpStatus } from '@nestjs/common';
import { Types } from 'mongoose';
import { z, ZodTypeAny } from 'zod';
import { ApiError } from '../errors/api-error';

/** Validates input with zod. Failures become 422 VALIDATION_FAILED with field details (see AllExceptionsFilter). */
export function parse<S extends ZodTypeAny>(schema: S, data: unknown): z.infer<S> {
  return schema.parse(data ?? {});
}

export const objectId = z.string().refine((v) => Types.ObjectId.isValid(v) && /^[0-9a-f]{24}$/i.test(v), 'Invalid id');
export const optionalId = objectId.optional().nullable();
export const isoDate = z.coerce.date();
/** Calendar day as YYYY-MM-DD (no time zone ambiguity). */
export const dayString = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD');
export const money = z.coerce.number().finite().nonnegative().max(1e12);
export const trimmed = (max = 200) => z.string().trim().min(1).max(max);
export const optionalText = (max = 2000) => z.string().trim().max(max).optional().nullable();

export const listQuery = z.object({
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(100).default(25),
  q: z.string().trim().max(100).optional(),
  sort: z
    .string()
    .regex(/^-?[a-zA-Z_.]+$/)
    .optional(),
  status: z.string().max(40).optional(),
});
export type ListQuery = z.infer<typeof listQuery>;

export interface Paged<T> {
  items: T[];
  page: number;
  limit: number;
  total: number;
  hasMore: boolean;
}

export function oid(id: string | Types.ObjectId): Types.ObjectId {
  if (id instanceof Types.ObjectId) return id;
  if (!Types.ObjectId.isValid(id)) throw new ApiError(HttpStatus.BAD_REQUEST, 'INVALID_ID', 'That id is not valid.');
  return new Types.ObjectId(id);
}

export const sameId = (a: unknown, b: unknown): boolean => a != null && b != null && String(a) === String(b);

/** Escapes user text for use inside a RegExp (search boxes). */
export const escapeRegex = (s: string): string => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function sortSpec(sort: string | undefined, allowed: string[], fallback: Record<string, 1 | -1>): Record<string, 1 | -1> {
  if (!sort) return fallback;
  const desc = sort.startsWith('-');
  const field = desc ? sort.slice(1) : sort;
  if (!allowed.includes(field)) return fallback;
  return { [field]: desc ? -1 : 1, _id: 1 };
}

export const notFound = (what = 'Record'): ApiError => new ApiError(HttpStatus.NOT_FOUND, 'NOT_FOUND', `${what} not found, or you don't have access to it.`);
export const conflict = (code: string, message: string): ApiError => new ApiError(HttpStatus.CONFLICT, code, message);
export const badRequest = (code: string, message: string, field?: string): ApiError =>
  new ApiError(HttpStatus.BAD_REQUEST, code, message, field ? [{ field, message }] : undefined);
export const forbidden = (code: string, message: string): ApiError => new ApiError(HttpStatus.FORBIDDEN, code, message);
