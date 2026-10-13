import { Inject, Provider } from '@nestjs/common';
import { Schema } from 'mongoose';
import { DatabaseService } from './database.service';

const PREFIX = 'MODEL_';

/** Inject a Mongoose model registered with [modelProvider]. */
export const InjectModel = (name: string): ParameterDecorator => Inject(PREFIX + name);

/** Registers `schema` as model `name` on the shared connection (collection name is explicit). */
export function modelProvider(name: string, schema: Schema, collection: string): Provider {
  return {
    provide: PREFIX + name,
    inject: [DatabaseService],
    useFactory: (db: DatabaseService) => db.connection.models[name] ?? db.connection.model(name, schema, collection),
  };
}

/**
 * Standard options for organization-owned collections: timestamps, `organizationId` on every
 * document, string `id` in JSON, no `__v`. Histories never embed unbounded arrays.
 */
export const baseOptions = { timestamps: true, versionKey: false as const };

export function orgScoped(schema: Schema): Schema {
  schema.add({ organizationId: { type: Schema.Types.ObjectId, required: true, index: true } });
  schema.set('toJSON', {
    virtuals: false,
    transform: (_doc: unknown, ret: Record<string, unknown>) => {
      ret.id = String(ret._id);
      delete ret._id;
      return ret;
    },
  });
  return schema;
}

/** Converts lean documents to API JSON: `_id` -> `id`, ObjectIds -> strings, Dates -> ISO, no `__v`. */
export function serialize(doc: unknown): any {
  if (doc == null) return doc;
  if (Array.isArray(doc)) return doc.map(serialize);
  if (doc instanceof Date) return doc.toISOString();
  if (typeof doc === 'object') {
    const o = doc as Record<string, any>;
    if (o._bsontype === 'ObjectId' || o._bsontype === 'ObjectID') return String(o);
    if (typeof o.toObject === 'function') return serialize(o.toObject());
    if (Buffer.isBuffer(o)) return undefined;
    const out: Record<string, any> = {};
    for (const [k, v] of Object.entries(o)) {
      if (k === '_id') out.id = serialize(v);
      else if (k === '__v') continue;
      else out[k] = serialize(v);
    }
    return out;
  }
  return doc;
}
