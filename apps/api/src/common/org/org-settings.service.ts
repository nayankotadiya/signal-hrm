import { Injectable } from '@nestjs/common';
import { Model, Types } from 'mongoose';
import { InjectModel } from '../../database/model';

/** Cached organization settings (time zone, attendance rules, features). Short TTL, cleared on update. */
@Injectable()
export class OrgSettingsService {
  private cache = new Map<string, { at: number; org: any }>();

  constructor(@InjectModel('Organization') private readonly orgs: Model<any>) {}

  async get(orgId: Types.ObjectId | string): Promise<any> {
    const k = String(orgId);
    const hit = this.cache.get(k);
    if (hit && Date.now() - hit.at < 15_000) return hit.org;
    const org = await this.orgs.findById(k).lean();
    if (org) this.cache.set(k, { at: Date.now(), org });
    return org;
  }

  clear(orgId: Types.ObjectId | string): void {
    this.cache.delete(String(orgId));
  }

  features(org: any): Record<string, boolean> {
    const f = org?.features;
    return f instanceof Map ? Object.fromEntries(f) : (f ?? {});
  }
}

/** Local calendar date (YYYY-MM-DD) and minutes-since-midnight for an instant in a time zone. */
export function localParts(at: Date, timeZone: string): { day: string; minutes: number; weekday: number } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
    weekday: 'short',
  }).formatToParts(at);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  const weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  return {
    day: `${get('year')}-${get('month')}-${get('day')}`,
    minutes: Number(get('hour')) * 60 + Number(get('minute')),
    weekday: weekdays.indexOf(get('weekday')),
  };
}

/** Converts a local date + HH:mm in a time zone to a UTC instant (handles DST by iterating offset). */
export function zonedTimeToUtc(day: string, hhmm: string, timeZone: string): Date {
  const [y, m, d] = day.split('-').map(Number);
  const [hh, mm] = hhmm.split(':').map(Number);
  let guess = Date.UTC(y, m - 1, d, hh, mm);
  for (let i = 0; i < 2; i++) {
    const p = localParts(new Date(guess), timeZone);
    const [py, pm, pd] = p.day.split('-').map(Number);
    const shown = Date.UTC(py, pm - 1, pd, Math.floor(p.minutes / 60), p.minutes % 60);
    guess += Date.UTC(y, m - 1, d, hh, mm) - shown;
  }
  return new Date(guess);
}

export function addDays(day: string, n: number): string {
  const [y, m, d] = day.split('-').map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return t.toISOString().slice(0, 10);
}

export function daysBetween(start: string, end: string): string[] {
  const out: string[] = [];
  for (let d = start; d <= end && out.length < 400; d = addDays(d, 1)) out.push(d);
  return out;
}

export function weekdayOf(day: string): number {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}
