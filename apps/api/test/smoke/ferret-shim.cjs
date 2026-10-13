/**
 * TEST-ONLY shim for running the API against FerretDB 1.x (SQLite) when a real MongoDB is not
 * available. Never loaded in production (`node -r ./test/smoke/ferret-shim.cjs dist/main.js`).
 *
 * FerretDB 1.x lacks some aggregation operators ($lookup, $cond, $ifNull, $first, $dateToString…)
 * and `findAndModify` projections. When the server answers "not implemented", this shim loads the
 * documents and evaluates the same pipeline with mingo (a MongoDB-compatible engine in JS), so
 * the application code under test is exactly the code that runs against MongoDB Atlas.
 */
const mongoose = require('mongoose');
const { Aggregator } = require('mingo');

const { Collection } = mongoose.mongo;
const origAggregate = Collection.prototype.aggregate;
const origFindOneAndUpdate = Collection.prototype.findOneAndUpdate;

const notImplemented = (e) => /not implemented|is not supported|Unrecognized expression|unknown operator/i.test(String(e && e.message));

function lookups(stage, out = new Set()) {
  if (Array.isArray(stage)) stage.forEach((s) => lookups(s, out));
  else if (stage && typeof stage === 'object') {
    if (stage.$lookup && stage.$lookup.from) out.add(stage.$lookup.from);
    Object.values(stage).forEach((v) => lookups(v, out));
  }
  return out;
}

function fakeCursor(run) {
  let buf = null;
  const load = async () => (buf ??= await run());
  return {
    toArray: async () => [...(await load())],
    next: async () => ((await load()).shift() ?? null),
    hasNext: async () => (await load()).length > 0,
    close: async () => undefined,
    [Symbol.asyncIterator]: async function* () {
      for (const d of await load()) yield d;
    },
  };
}

Collection.prototype.aggregate = function (pipeline = [], options = {}) {
  const coll = this;
  return fakeCursor(async () => {
    try {
      return await origAggregate.call(coll, pipeline, options).toArray();
    } catch (e) {
      if (!notImplemented(e)) throw e;
    }
    let base;
    let rest = pipeline;
    if (pipeline[0] && pipeline[0].$match) {
      try {
        base = await coll.find(pipeline[0].$match).toArray();
        rest = pipeline.slice(1);
      } catch {
        base = await coll.find({}).toArray();
      }
    } else {
      base = await coll.find({}).toArray();
    }
    const db = coll.s.db;
    const loaded = {};
    for (const name of lookups(pipeline)) loaded[name] = await db.collection(name).find({}).toArray();
    return new Aggregator(rest, { collectionResolver: (n) => loaded[n] || [] }).run(base);
  });
};

Collection.prototype.findOneAndUpdate = async function (filter, update, options = {}) {
  try {
    return await origFindOneAndUpdate.call(this, filter, update, options);
  } catch (e) {
    if (!notImplemented(e) || !options.projection) throw e;
    const { projection, ...rest } = options;
    const res = await origFindOneAndUpdate.call(this, filter, update, rest);
    const doc = res && res.value !== undefined && rest.includeResultMetadata ? res.value : res;
    if (doc && typeof doc === 'object') {
      const inclusive = Object.values(projection).some((v) => v === 1 || v === true);
      for (const k of Object.keys(doc)) {
        if (k === '_id') continue;
        if (inclusive ? !(k in projection) : projection[k] === 0 || projection[k] === false) delete doc[k];
      }
    }
    return res;
  }
};

// eslint-disable-next-line no-console
console.warn('[ferret-shim] TEST ONLY: aggregation fallbacks enabled');
