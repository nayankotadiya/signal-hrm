import { Injectable } from '@nestjs/common';
import { Model } from 'mongoose';
import type { Ctx } from '../../common/auth/context';
import { ScopeService } from '../../common/authz/scope.service';
import { escapeRegex } from '../../common/http/validation';
import { InjectModel } from '../../database/model';

export const SEARCH_TYPES = ['employees', 'departments', 'teams', 'tasks', 'leads', 'meetings', 'documents', 'policies', 'approvals'] as const;
export type SearchType = (typeof SEARCH_TYPES)[number];

export interface SearchHit {
  type: SearchType;
  id: string;
  title: string;
  subtitle?: string;
  link: string;
  /** [start, end) ranges inside title that matched, for highlighting. */
  highlights: [number, number][];
}

function ranges(text: string, q: string): [number, number][] {
  const out: [number, number][] = [];
  const lower = text.toLowerCase();
  for (const term of q.toLowerCase().split(/\s+/).filter(Boolean)) {
    let i = lower.indexOf(term);
    while (i !== -1 && out.length < 10) {
      out.push([i, i + term.length]);
      i = lower.indexOf(term, i + term.length);
    }
  }
  return out.sort((a, b) => a[0] - b[0]);
}

/**
 * Permission-aware global search. Each entity type applies the same scope filter as its list
 * endpoint, so search never reveals a record the caller couldn't open. Query text is escaped
 * (no regex injection) and results are capped per type.
 */
@Injectable()
export class SearchService {
  constructor(
    private readonly scope: ScopeService,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('Team') private readonly teams: Model<any>,
    @InjectModel('Task') private readonly tasks: Model<any>,
    @InjectModel('Lead') private readonly leads: Model<any>,
    @InjectModel('Meeting') private readonly meetings: Model<any>,
    @InjectModel('Document') private readonly documents: Model<any>,
    @InjectModel('Approval') private readonly approvals: Model<any>,
  ) {}

  async search(ctx: Ctx, q: string, types: SearchType[], limit: number): Promise<{ query: string; groups: { type: SearchType; items: SearchHit[] }[] }> {
    const query = q.trim().slice(0, 80);
    if (query.length < 2) return { query, groups: [] };
    const rx = new RegExp(query.split(/\s+/).map(escapeRegex).join('.*'), 'i');
    const want = new Set(types.length ? types : SEARCH_TYPES);
    const groups: { type: SearchType; items: SearchHit[] }[] = [];
    const hit = (type: SearchType, id: unknown, title: string, link: string, subtitle?: string): SearchHit => ({ type, id: String(id), title, subtitle, link, highlights: ranges(title, query) });

    if (want.has('employees') && ctx.authz.can('employees', 'view')) {
      const f = await this.scope.filter(ctx, 'employees', 'view', '_id');
      const rows = await this.employees.find({ ...f, status: { $nin: ['archived'] }, $or: [{ firstName: rx }, { lastName: rx }, { displayName: rx }, { employeeCode: rx }, { designation: rx }] }, { firstName: 1, lastName: 1, designation: 1, employeeCode: 1 }).limit(limit).lean<any[]>();
      groups.push({ type: 'employees', items: rows.map((e) => hit('employees', e._id, `${e.firstName} ${e.lastName ?? ''}`.trim(), `/people/${e._id}`, [e.designation, e.employeeCode].filter(Boolean).join(' · '))) });
    }
    if (want.has('departments')) {
      const rows = await this.departments.find({ organizationId: ctx.orgOid, status: 'active', name: rx }, { name: 1 }).limit(limit).lean<any[]>();
      groups.push({ type: 'departments', items: rows.map((d) => hit('departments', d._id, d.name, `/people/departments/${d._id}`)) });
    }
    if (want.has('teams') && ctx.authz.can('teams', 'view')) {
      const rows = await this.teams.find({ organizationId: ctx.orgOid, status: 'active', name: rx }, { name: 1 }).limit(limit).lean<any[]>();
      groups.push({ type: 'teams', items: rows.map((t) => hit('teams', t._id, t.name, `/people/teams/${t._id}`)) });
    }
    if (want.has('tasks') && ctx.authz.can('tasks', 'view')) {
      const s = ctx.authz.scope('tasks', 'view')!;
      const ids = await this.scope.employeeIds(ctx, s, 'tasks', 'view');
      const vis = ids === null ? {} : { $or: [{ assigneeIds: { $in: ids } }, { createdBy: ctx.userOid }] };
      const rows = await this.tasks.find({ organizationId: ctx.orgOid, title: rx, ...vis }, { title: 1, status: 1, dueDate: 1 }).limit(limit).lean<any[]>();
      groups.push({ type: 'tasks', items: rows.map((t) => hit('tasks', t._id, t.title, `/work/tasks/${t._id}`, [t.status.replace('_', ' '), t.dueDate ? `due ${t.dueDate}` : ''].filter(Boolean).join(' · '))) });
    }
    if (want.has('leads') && ctx.authz.can('crm', 'view')) {
      const f = await this.scope.filter(ctx, 'crm', 'view', 'ownerEmployeeId');
      const rows = await this.leads.find({ ...f, $or: [{ name: rx }, { company: rx }, { email: rx }] }, { name: 1, company: 1, status: 1 }).limit(limit).lean<any[]>();
      groups.push({ type: 'leads', items: rows.map((l) => hit('leads', l._id, l.name, `/work/crm/${l._id}`, [l.company, l.status].filter(Boolean).join(' · '))) });
    }
    if (want.has('meetings')) {
      const rows = await this.meetings.find({ organizationId: ctx.orgOid, title: rx, $or: [{ organizerId: ctx.userOid }, { participantUserIds: ctx.userOid }] }, { title: 1, startAt: 1 }).sort({ startAt: -1 }).limit(limit).lean<any[]>();
      groups.push({ type: 'meetings', items: rows.map((m) => hit('meetings', m._id, m.title, `/work/meetings/${m._id}`, new Date(m.startAt).toISOString().slice(0, 16).replace('T', ' '))) });
    }
    if (want.has('documents') || want.has('policies')) {
      const me = ctx.employeeOid ? await this.employees.findById(ctx.employeeOid, { departmentId: 1 }).lean<any>() : null;
      const vis: Record<string, unknown>[] = [
        { uploadedBy: ctx.userOid },
        { relatedEmployeeId: ctx.employeeOid ?? null },
        { 'access.scope': 'organization' },
        { 'access.scope': 'employees', 'access.employeeIds': ctx.employeeOid ?? null },
        { 'access.scope': 'departments', 'access.departmentIds': me?.departmentId ?? null },
      ];
      if (ctx.authz.can('documents', 'manage', 'organization')) vis.push({});
      const rows = await this.documents.find({ organizationId: ctx.orgOid, status: 'active', title: rx, $or: vis }, { title: 1, category: 1, isPolicy: 1 }).limit(limit * 2).lean<any[]>();
      if (want.has('documents')) groups.push({ type: 'documents', items: rows.filter((d) => !d.isPolicy).slice(0, limit).map((d) => hit('documents', d._id, d.title, `/documents/${d._id}`, d.category)) });
      if (want.has('policies')) groups.push({ type: 'policies', items: rows.filter((d) => d.isPolicy).slice(0, limit).map((d) => hit('policies', d._id, d.title, `/documents/${d._id}`, 'Policy')) });
    }
    if (want.has('approvals')) {
      const or: Record<string, unknown>[] = [{ requestedBy: ctx.userOid }, { currentApproverIds: ctx.userOid }];
      if (ctx.authz.can('approvals', 'view', 'organization')) or.push({});
      const rows = await this.approvals.find({ organizationId: ctx.orgOid, title: rx, $or: or }, { title: 1, status: 1, requestType: 1 }).sort({ createdAt: -1 }).limit(limit).lean<any[]>();
      groups.push({ type: 'approvals', items: rows.map((a) => hit('approvals', a._id, a.title, `/approvals/${a._id}`, `${a.requestType.replace('_', ' ')} · ${a.status}`)) });
    }
    return { query, groups: groups.filter((g) => g.items.length) };
  }
}
