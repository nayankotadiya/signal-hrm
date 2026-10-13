import { Injectable, OnModuleInit } from '@nestjs/common';
import { Cron } from '@nestjs/schedule';
import { Model, Types } from 'mongoose';
import PDFDocument from 'pdfkit';
import { z } from 'zod';
import { AuditService } from '../../common/audit/audit.service';
import type { Ctx } from '../../common/auth/context';
import { PermissionsService } from '../../common/authz/permissions.service';
import { ScopeService } from '../../common/authz/scope.service';
import { badRequest, conflict, dayString, escapeRegex, forbidden, notFound, objectId, oid, Paged } from '../../common/http/validation';
import { addDays, localParts, OrgSettingsService } from '../../common/org/org-settings.service';
import { InjectModel, serialize } from '../../database/model';
import { FilesService } from '../files/files.service';
import { NotificationsService } from '../notifications/notifications.service';
import { JobsService } from '../system/jobs.service';

export const documentInput = z.object({
  title: z.string().trim().min(2).max(160),
  category: z.enum(['policy', 'contract', 'id_proof', 'address_proof', 'letter', 'certificate', 'tax', 'general']).default('general'),
  isPolicy: z.boolean().default(false),
  relatedEmployeeId: objectId.optional().nullable(),
  fileId: objectId,
  access: z.object({ scope: z.enum(['organization', 'departments', 'employees', 'private']).default('private'), departmentIds: z.array(objectId).default([]), employeeIds: z.array(objectId).default([]) }).default({ scope: 'private', departmentIds: [], employeeIds: [] }),
  expiryDate: dayString.optional().nullable(),
  requiresAcknowledgement: z.boolean().default(false),
  retention: z.enum(['standard', 'legal_hold', 'delete_after_exit', 'permanent']).default('standard'),
  tags: z.array(z.string().max(30)).max(10).default([]),
});

@Injectable()
export class DocumentsService implements OnModuleInit {
  constructor(
    private readonly audit: AuditService,
    private readonly scope: ScopeService,
    private readonly files: FilesService,
    private readonly notifications: NotificationsService,
    private readonly orgSettings: OrgSettingsService,
    private readonly jobs: JobsService,
    @InjectModel('Document') private readonly docs: Model<any>,
    @InjectModel('DocumentVersion') private readonly versions: Model<any>,
    @InjectModel('DocumentAck') private readonly acks: Model<any>,
    @InjectModel('DocumentAccessLog') private readonly accessLogs: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Organization') private readonly orgs: Model<any>,
    @InjectModel('Department') private readonly departments: Model<any>,
    @InjectModel('SalaryStructure') private readonly salaries: Model<any>,
  ) {}

  onModuleInit(): void {
    // Document files are downloadable only through the document's access rules (never a Drive link).
    this.files.registerAuthorizer('document', async (ctx, f) => {
      const d = await this.docs.findOne({ organizationId: ctx.orgOid, $or: [{ currentFileId: f._id }, { _id: f.linked?.id }] }).lean<any>();
      return !!d && this.canView(ctx, d);
    });
    this.files.registerAuthorizer('letter', async (ctx, f) => String(f.ownerEmployeeId) === ctx.user.employeeId || this.scope.covers(ctx, 'documents', 'view', f.ownerEmployeeId));
  }

  /** Access: org-wide / departments / named employees / private (owner, related employee, document managers). */
  async canView(ctx: Ctx, d: any): Promise<boolean> {
    if (String(d.uploadedBy) === ctx.user.userId) return true;
    if (d.relatedEmployeeId && String(d.relatedEmployeeId) === ctx.user.employeeId) return true;
    if (ctx.authz.can('documents', 'manage', 'organization')) return true;
    if (d.relatedEmployeeId && (await this.scope.covers(ctx, 'documents', 'view', d.relatedEmployeeId)) && ctx.authz.scope('documents', 'view') !== 'own') return true;
    if (d.status !== 'active') return false;
    switch (d.access?.scope) {
      case 'organization':
        return true;
      case 'employees':
        return !!ctx.employeeOid && (d.access.employeeIds ?? []).some((e: any) => String(e) === ctx.user.employeeId);
      case 'departments': {
        if (!ctx.employeeOid) return false;
        const me = await this.employees.findById(ctx.employeeOid, { departmentId: 1 }).lean<any>();
        return (d.access.departmentIds ?? []).some((x: any) => String(x) === String(me?.departmentId));
      }
      default:
        return false;
    }
  }

  private async log(ctx: Ctx, documentId: Types.ObjectId, action: 'view' | 'download' | 'denied'): Promise<void> {
    await this.accessLogs.create({ organizationId: ctx.orgOid, documentId, userId: ctx.userOid, action, ip: ctx.ip, at: new Date() });
  }

  async list(ctx: Ctx, q: { q?: string; category?: string; policies?: boolean; employeeId?: string; mine?: boolean; expiringDays?: number; page: number; limit: number }): Promise<Paged<any>> {
    const me = ctx.employeeOid ? await this.employees.findById(ctx.employeeOid, { departmentId: 1 }).lean<any>() : null;
    const visibility: Record<string, unknown>[] = [
      { uploadedBy: ctx.userOid },
      { relatedEmployeeId: ctx.employeeOid ?? null },
      { 'access.scope': 'organization' },
      { 'access.scope': 'employees', 'access.employeeIds': ctx.employeeOid ?? null },
      { 'access.scope': 'departments', 'access.departmentIds': me?.departmentId ?? null },
    ];
    const scope = ctx.authz.scope('documents', 'view');
    if (ctx.authz.can('documents', 'manage', 'organization') || scope === 'organization') visibility.push({});
    else if (scope && scope !== 'own') {
      const ids = await this.scope.employeeIds(ctx, scope, 'documents', 'view');
      if (ids) visibility.push({ relatedEmployeeId: { $in: ids } });
    }
    const filter: Record<string, any> = { organizationId: ctx.orgOid, status: 'active', $or: visibility };
    if (q.mine) filter.$or = [{ relatedEmployeeId: ctx.employeeOid ?? null }, { uploadedBy: ctx.userOid }];
    if (q.policies) filter.isPolicy = true;
    if (q.category) filter.category = q.category;
    if (q.employeeId) filter.relatedEmployeeId = oid(q.employeeId);
    if (q.q) filter.title = new RegExp(escapeRegex(q.q), 'i');
    if (q.expiringDays) {
      const org = await this.orgSettings.get(ctx.orgOid);
      const today = localParts(new Date(), org.timezone).day;
      filter.expiryDate = { $gte: today, $lte: addDays(today, q.expiringDays) };
    }
    const [rows, total] = await Promise.all([this.docs.find(filter).sort({ updatedAt: -1 }).skip((q.page - 1) * q.limit).limit(q.limit).lean<any[]>(), this.docs.countDocuments(filter)]);
    const ackd = ctx.employeeOid ? await this.acks.find({ organizationId: ctx.orgOid, employeeId: ctx.employeeOid, documentId: { $in: rows.map((r) => r._id) } }).lean<any[]>() : [];
    const ackOf = new Map(ackd.map((a) => [`${a.documentId}:${a.version}`, a]));
    return {
      items: serialize(rows).map((d: any) => {
        const a = ackOf.get(`${d.id}:${d.currentVersion}`);
        return { ...d, myAcknowledgement: d.requiresAcknowledgement ? (a?.acknowledgedAt ? { acknowledgedAt: a.acknowledgedAt } : a ? { pending: true } : null) : null };
      }),
      page: q.page,
      limit: q.limit,
      total,
      hasMore: q.page * q.limit < total,
    };
  }

  async get(ctx: Ctx, id: string): Promise<any> {
    const d = await this.docs.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!d) throw notFound('Document');
    if (!(await this.canView(ctx, d))) {
      await this.log(ctx, d._id, 'denied');
      throw notFound('Document');
    }
    await this.log(ctx, d._id, 'view');
    const vers = await this.versions.find({ documentId: d._id }).sort({ version: -1 }).lean();
    const manage = ctx.authz.can('documents', 'manage') || String(d.uploadedBy) === ctx.user.userId;
    const ackStats = d.requiresAcknowledgement && manage ? await this.ackStats(d) : null;
    return { ...serialize(d), versions: serialize(vers), acknowledgements: ackStats, can: { manage } };
  }

  private async ackStats(d: any): Promise<any> {
    const rows = await this.acks.find({ documentId: d._id, version: d.currentVersion }).lean<any[]>();
    return { assigned: rows.length, acknowledged: rows.filter((r) => r.acknowledgedAt).length, pending: rows.filter((r) => !r.acknowledgedAt).map((r) => String(r.employeeId)) };
  }

  async create(ctx: Ctx, b: z.infer<typeof documentInput>): Promise<any> {
    const ownDoc = b.relatedEmployeeId && b.relatedEmployeeId === ctx.user.employeeId && !b.isPolicy;
    if (!ownDoc) PermissionsService.require(ctx, 'documents', 'create');
    if (b.relatedEmployeeId && !ownDoc && !(await this.scope.covers(ctx, 'documents', 'create', b.relatedEmployeeId))) throw forbidden('FORBIDDEN', "You can't add documents for this employee.");
    if (b.isPolicy || b.access.scope === 'organization') PermissionsService.require(ctx, 'documents', 'manage', 'organization');
    const f = await this.files.requireOwnUpload(ctx, b.fileId, 'document');
    const d = await this.docs.create({
      organizationId: ctx.orgOid,
      title: b.title,
      category: b.isPolicy ? 'policy' : b.category,
      isPolicy: b.isPolicy,
      relatedEmployeeId: b.relatedEmployeeId ? oid(b.relatedEmployeeId) : undefined,
      ownerUserId: ctx.userOid,
      currentVersion: 1,
      currentFileId: f._id,
      mimeType: f.mimeType,
      sizeBytes: f.sizeBytes,
      checksum: f.checksum,
      access: { scope: b.isPolicy ? 'organization' : b.access.scope, departmentIds: b.access.departmentIds.map(oid), employeeIds: b.access.employeeIds.map(oid) },
      expiryDate: b.expiryDate ?? undefined,
      requiresAcknowledgement: b.requiresAcknowledgement,
      retention: b.retention,
      uploadedBy: ctx.userOid,
      tags: b.tags,
    });
    await this.files.link(f._id, { type: 'document', id: d._id });
    await this.versions.create({ organizationId: ctx.orgOid, documentId: d._id, version: 1, fileId: f._id, mimeType: f.mimeType, sizeBytes: f.sizeBytes, checksum: f.checksum, uploadedBy: ctx.userOid });
    if (b.requiresAcknowledgement) await this.assignAcknowledgements(ctx, d.toObject());
    await this.audit.record(ctx, { action: 'document.create', resourceType: 'document', resourceId: d._id });
    return this.get(ctx, String(d._id));
  }

  /** New version: acknowledgements reset for the new version. */
  async addVersion(ctx: Ctx, id: string, fileId: string, note?: string): Promise<any> {
    const d = await this.docs.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!d) throw notFound('Document');
    if (String(d.uploadedBy) !== ctx.user.userId) PermissionsService.require(ctx, 'documents', 'edit');
    const f = await this.files.requireOwnUpload(ctx, fileId, 'document');
    const version = d.currentVersion + 1;
    await this.versions.create({ organizationId: ctx.orgOid, documentId: d._id, version, fileId: f._id, mimeType: f.mimeType, sizeBytes: f.sizeBytes, checksum: f.checksum, note, uploadedBy: ctx.userOid });
    await this.files.link(f._id, { type: 'document', id: d._id });
    await this.docs.updateOne({ _id: d._id }, { $set: { currentVersion: version, currentFileId: f._id, mimeType: f.mimeType, sizeBytes: f.sizeBytes, checksum: f.checksum } });
    if (d.requiresAcknowledgement) await this.assignAcknowledgements(ctx, { ...d, currentVersion: version });
    await this.audit.record(ctx, { action: 'document.version', resourceType: 'document', resourceId: id, changes: { version: { from: d.currentVersion, to: version } } });
    return this.get(ctx, id);
  }

  async update(ctx: Ctx, id: string, b: Partial<Omit<z.infer<typeof documentInput>, 'fileId'>> & { status?: 'active' | 'archived' }): Promise<any> {
    const d = await this.docs.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!d) throw notFound('Document');
    if (String(d.uploadedBy) !== ctx.user.userId) PermissionsService.require(ctx, 'documents', 'edit');
    if (b.status === 'archived' && d.retention === 'legal_hold') throw conflict('LEGAL_HOLD', 'This document is on legal hold.');
    const set: Record<string, unknown> = { ...b };
    if (b.access) set.access = { scope: b.access.scope, departmentIds: b.access.departmentIds.map(oid), employeeIds: b.access.employeeIds.map(oid) };
    if (b.relatedEmployeeId !== undefined) set.relatedEmployeeId = b.relatedEmployeeId ? oid(b.relatedEmployeeId) : null;
    await this.docs.updateOne({ _id: d._id }, { $set: set });
    if (b.requiresAcknowledgement && !d.requiresAcknowledgement) await this.assignAcknowledgements(ctx, { ...d, ...set });
    await this.audit.record(ctx, { action: 'document.update', resourceType: 'document', resourceId: id });
    return this.get(ctx, id);
  }

  /** Assigns acknowledgements to everyone the document is visible to (by access scope). */
  private async assignAcknowledgements(ctx: Ctx, d: any): Promise<void> {
    const filter: Record<string, unknown> = { organizationId: ctx.orgOid, status: { $in: ['active', 'probation', 'notice', 'onboarding'] } };
    if (d.access?.scope === 'departments') filter.departmentId = { $in: d.access.departmentIds };
    else if (d.access?.scope === 'employees') filter._id = { $in: d.access.employeeIds };
    else if (d.access?.scope === 'private') filter._id = d.relatedEmployeeId ?? null;
    const emps = await this.employees.find(filter, { _id: 1 }).lean<any[]>();
    for (const e of emps) {
      await this.acks.updateOne({ organizationId: ctx.orgOid, documentId: d._id, employeeId: e._id, version: d.currentVersion }, { $setOnInsert: { assignedAt: new Date() } }, { upsert: true });
    }
    const users = await this.users.find({ organizationId: ctx.orgOid, employeeId: { $in: emps.map((e) => e._id) }, status: 'active' }, { _id: 1 }).lean<any[]>();
    await this.notifications.notify(ctx.orgOid, users.map((u) => u._id), { event: 'document_ack_required', title: `Please read and acknowledge: ${d.title}`, link: `/documents/${d._id}` });
  }

  async acknowledge(ctx: Ctx, id: string): Promise<any> {
    const d = await this.docs.findOne({ _id: oid(id), organizationId: ctx.orgOid, status: 'active' }).lean<any>();
    if (!d || !(await this.canView(ctx, d))) throw notFound('Document');
    if (!d.requiresAcknowledgement) throw badRequest('NO_ACK_NEEDED', "This document doesn't need acknowledgement.");
    if (!ctx.employeeOid) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    await this.acks.updateOne({ organizationId: ctx.orgOid, documentId: d._id, employeeId: ctx.employeeOid, version: d.currentVersion }, { $set: { acknowledgedAt: new Date() }, $setOnInsert: { assignedAt: new Date() } }, { upsert: true });
    await this.audit.record(ctx, { action: 'document.acknowledge', resourceType: 'document', resourceId: id, changes: { version: { from: null, to: d.currentVersion } } });
    return { acknowledged: true, version: d.currentVersion };
  }

  /** My outstanding acknowledgements (dark action card). */
  async pendingAcknowledgements(ctx: Ctx): Promise<any[]> {
    if (!ctx.employeeOid) return [];
    const rows = await this.acks.find({ organizationId: ctx.orgOid, employeeId: ctx.employeeOid, acknowledgedAt: null }).lean<any[]>();
    const docs = await this.docs.find({ _id: { $in: rows.map((r) => r.documentId) }, status: 'active' }, { title: 1, currentVersion: 1 }).lean<any[]>();
    const cur = new Map(docs.map((d) => [String(d._id), d]));
    return rows.filter((r) => cur.get(String(r.documentId))?.currentVersion === r.version).map((r) => ({ documentId: String(r.documentId), title: cur.get(String(r.documentId)).title, assignedAt: r.assignedAt }));
  }

  async accessLog(ctx: Ctx, id: string): Promise<any[]> {
    PermissionsService.require(ctx, 'documents', 'manage');
    const rows = await this.accessLogs.find({ organizationId: ctx.orgOid, documentId: oid(id) }).sort({ at: -1 }).limit(500).lean<any[]>();
    const users = await this.users.find({ _id: { $in: rows.map((r) => r.userId) } }, { fullName: 1 }).lean<any[]>();
    const n = new Map(users.map((u) => [String(u._id), u.fullName]));
    return serialize(rows).map((r: any) => ({ ...r, userName: n.get(r.userId) }));
  }

  async logDownload(ctx: Ctx, fileId: string): Promise<void> {
    const d = await this.docs.findOne({ organizationId: ctx.orgOid, currentFileId: oid(fileId) }, { _id: 1 }).lean<any>();
    if (d) await this.log(ctx, d._id, 'download');
  }

  /** Daily: expiring documents within 30 days notify the related employee and document managers once a week. */
  @Cron('0 8 * * *')
  async expiryAlerts(): Promise<void> {
    await this.jobs.run('documents.expiry', async () => {
      const today = new Date().toISOString().slice(0, 10);
      const soon = addDays(today, 30);
      const rows = await this.docs.find({ status: 'active', expiryDate: { $gte: today, $lte: soon } }).lean<any[]>();
      let n = 0;
      for (const d of rows) {
        const daysLeft = Math.round((Date.parse(d.expiryDate) - Date.parse(today)) / 86400_000);
        if (![30, 14, 7, 1].includes(daysLeft)) continue;
        const targets = await this.users.find({ organizationId: d.organizationId, status: 'active', $or: [{ _id: d.uploadedBy }, ...(d.relatedEmployeeId ? [{ employeeId: d.relatedEmployeeId }] : []), { role: 'hr' }] }, { _id: 1 }).lean<any[]>();
        await this.notifications.notify(d.organizationId, targets.map((t) => t._id), { event: 'document_ack_required', title: `${d.title} expires in ${daysLeft} day${daysLeft === 1 ? '' : 's'}`, link: `/documents/${d._id}` });
        n++;
      }
      return `${n} expiry alerts`;
    });
  }

  // ------------------------------------------------------------------ self-service letters

  /** Employment letter or salary certificate as a PDF, generated from the record, access-logged. */
  async generateLetter(ctx: Ctx, kind: 'employment' | 'salary_certificate', employeeId?: string, purpose?: string): Promise<any> {
    const id = employeeId ?? ctx.user.employeeId;
    if (!id) throw badRequest('NO_EMPLOYEE', 'Your account is not linked to an employee record.');
    if (id !== ctx.user.employeeId && !(await this.scope.covers(ctx, 'documents', 'create', id))) throw notFound('Employee');
    const e = await this.employees.findOne({ _id: oid(id), organizationId: ctx.orgOid }).lean<any>();
    if (!e) throw notFound('Employee');
    if (kind === 'salary_certificate' && !e.salaryStructureId) throw badRequest('NO_SALARY', 'There is no approved salary on record yet.');
    const org = await this.orgs.findById(ctx.orgOid).lean<any>();
    const dept = e.departmentId ? await this.departments.findById(e.departmentId, { name: 1 }).lean<any>() : null;
    let gross: number | undefined;
    if (kind === 'salary_certificate') {
      const s = await this.salaries.findById(e.salaryStructureId).lean<any>();
      gross = s?.monthlyGross;
    }
    const name = `${e.firstName} ${e.lastName ?? ''}`.trim();
    const pdf = await new Promise<Buffer>((resolve, reject) => {
      const doc = new PDFDocument({ size: 'A4', margin: 64 });
      const chunks: Buffer[] = [];
      doc.on('data', (c: Buffer) => chunks.push(c)).on('end', () => resolve(Buffer.concat(chunks))).on('error', reject);
      doc.font('Helvetica-Bold').fontSize(16).text(org.legalName || org.name);
      if (org.offices?.[0]?.address) doc.font('Helvetica').fontSize(9).fillColor('#5F6570').text(org.offices[0].address);
      doc.moveDown(2).fillColor('#0F1115').font('Helvetica').fontSize(10).text(new Date().toLocaleDateString('en-IN', { day: 'numeric', month: 'long', year: 'numeric' }));
      doc.moveDown(1.5).font('Helvetica-Bold').fontSize(13).text(kind === 'employment' ? 'To whom it may concern' : 'Salary certificate');
      doc.moveDown(1).font('Helvetica').fontSize(11);
      const since = e.joiningDate ? new Date(e.joiningDate).toLocaleDateString('en-IN', { day: 'numeric', month: 'long', year: 'numeric' }) : 'their joining date';
      doc.text(`This is to certify that ${name} (Employee ID ${e.employeeCode}) has been employed with ${org.legalName || org.name} since ${since}${e.designation ? ` and currently works as ${e.designation}` : ''}${dept ? ` in the ${dept.name} department` : ''}.`, { lineGap: 4 });
      if (kind === 'salary_certificate' && gross != null) {
        doc.moveDown(0.8).text(`Their current gross monthly salary is ${org.currency ?? 'INR'} ${gross.toLocaleString('en-IN', { minimumFractionDigits: 2 })}.`, { lineGap: 4 });
      }
      if (purpose) doc.moveDown(0.8).text(`This letter is issued at the employee's request for: ${purpose}.`, { lineGap: 4 });
      doc.moveDown(3).text('For ' + (org.legalName || org.name));
      doc.moveDown(2).fontSize(8).fillColor('#5F6570').text('System-generated by Signal HRM. Verify with HR using the reference below.');
      doc.text(`Reference ${String(e._id).slice(-8).toUpperCase()}-${Date.now().toString(36).toUpperCase()}`);
      doc.end();
    });
    const file = await this.files.storeGenerated(ctx.orgOid, { buffer: pdf, name: `${kind === 'employment' ? 'Employment-letter' : 'Salary-certificate'}-${e.employeeCode}.pdf`, mimeType: 'application/pdf', purpose: 'letter', ownerEmployeeId: e._id, linked: { type: 'letter', id: e._id }, uploadedBy: ctx.userOid, deleteAfter: new Date(Date.now() + 30 * 86400_000) });
    await this.audit.record(ctx, { action: `letter.${kind}`, resourceType: 'employee', resourceId: id });
    return { fileId: String(file._id), name: file.name };
  }
}
