import { Schema } from 'mongoose';
import { baseOptions, orgScoped } from '../database/model';

const { ObjectId, Mixed } = Schema.Types;

// ---------------------------------------------------------------- tasks
export const TASK_STATUSES = ['todo', 'in_progress', 'blocked', 'in_review', 'completed', 'cancelled'] as const;

export const TaskSchema = orgScoped(
  new Schema(
    {
      title: { type: String, required: true, trim: true },
      description: String,
      createdBy: { type: ObjectId, required: true },
      assigneeIds: { type: [ObjectId], index: true }, // employee ids
      departmentId: ObjectId,
      teamId: ObjectId,
      priority: { type: String, enum: ['low', 'medium', 'high', 'urgent'], default: 'medium' },
      status: { type: String, enum: TASK_STATUSES, default: 'todo', index: true },
      startDate: String,
      dueDate: { type: String, index: true },
      tags: [String],
      checklist: [{ _id: false, id: String, text: String, done: Boolean }],
      completion: { type: Number, default: 0, min: 0, max: 100 },
      requiresReview: { type: Boolean, default: false },
      reviewerId: ObjectId,
      relatedLeadId: ObjectId,
      relatedMeetingId: ObjectId,
      order: { type: Number, default: 0 }, // Kanban position within a status column
      completedAt: Date,
    },
    baseOptions,
  ),
);

export const TaskCommentSchema = orgScoped(
  new Schema({ taskId: { type: ObjectId, required: true, index: true }, authorId: ObjectId, body: { type: String, required: true }, editedAt: Date }, { ...baseOptions, collection: 'task_comments' }),
);
export const TaskActivitySchema = orgScoped(
  new Schema({ taskId: { type: ObjectId, required: true, index: true }, actorId: ObjectId, type: String, data: Mixed }, { ...baseOptions, collection: 'task_activities' }),
);
export const TaskAttachmentSchema = orgScoped(
  new Schema({ taskId: { type: ObjectId, required: true, index: true }, fileId: ObjectId, uploadedBy: ObjectId, name: String }, { ...baseOptions, collection: 'task_attachments' }),
);

// ---------------------------------------------------------------- CRM
export const LEAD_STATUSES = ['new', 'contacted', 'interested', 'qualified', 'meeting_scheduled', 'proposal', 'won', 'lost', 'unreachable'] as const;

export const LeadSchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true, trim: true },
      company: String,
      phone: String,
      phoneNormalized: { type: String, index: true },
      email: { type: String, lowercase: true, trim: true },
      source: { type: String, default: 'manual' }, // manual, meta, website, referral, import ...
      campaignRef: String,
      externalId: String, // e.g. Meta leadgen id (deduplication)
      ownerEmployeeId: { type: ObjectId, index: true },
      status: { type: String, enum: LEAD_STATUSES, default: 'new', index: true },
      priority: { type: String, enum: ['low', 'medium', 'high'], default: 'medium' },
      interest: { type: String, enum: ['cold', 'warm', 'hot'], default: 'warm' },
      estimatedValue: Number,
      nextFollowUpAt: Date,
      lastContactedAt: Date,
      firstResponseAt: Date,
      notes: String,
      consent: { marketing: Boolean, whatsapp: Boolean, call: Boolean, recordedAt: Date },
      lostReason: String,
      wonAt: Date,
      customFields: Mixed,
      createdBy: ObjectId,
    },
    baseOptions,
  ),
);
LeadSchema.index({ organizationId: 1, email: 1 });
LeadSchema.index({ organizationId: 1, source: 1, externalId: 1 }, { unique: true, partialFilterExpression: { externalId: { $type: 'string' } } });

export const LeadActivitySchema = orgScoped(
  new Schema(
    {
      leadId: { type: ObjectId, required: true, index: true },
      type: { type: String, enum: ['call', 'email', 'whatsapp', 'meeting', 'note', 'status_change', 'assignment', 'follow_up'], required: true },
      outcome: String,
      note: String,
      at: { type: Date, default: Date.now },
      dueAt: Date, // follow-ups
      done: Boolean,
      actorId: ObjectId,
      data: Mixed,
    },
    { ...baseOptions, collection: 'lead_activities' },
  ),
);

export const LeadAssignmentSchema = orgScoped(
  new Schema({ leadId: { type: ObjectId, required: true, index: true }, fromEmployeeId: ObjectId, toEmployeeId: ObjectId, byUserId: ObjectId, reason: String }, { ...baseOptions, collection: 'lead_assignments' }),
);

export const LeadSourceSchema = orgScoped(
  new Schema({ key: { type: String, required: true }, name: { type: String, required: true }, active: { type: Boolean, default: true } }, { ...baseOptions, collection: 'lead_sources' }),
);
LeadSourceSchema.index({ organizationId: 1, key: 1 }, { unique: true });

// ---------------------------------------------------------------- meetings (shared by CRM and Calls)
export const MeetingSchema = orgScoped(
  new Schema(
    {
      title: { type: String, required: true },
      organizerId: { type: ObjectId, required: true }, // user id
      participantUserIds: { type: [ObjectId], index: true },
      externalParticipants: [{ name: String, email: String }],
      startAt: { type: Date, required: true, index: true },
      endAt: { type: Date, required: true },
      timezone: String,
      meetingType: { type: String, enum: ['video', 'audio', 'in_person', 'external_link'], default: 'video' },
      meetingUrl: String,
      roomId: String, // internal WebRTC room
      relatedTaskId: ObjectId,
      relatedLeadId: ObjectId,
      status: { type: String, enum: ['scheduled', 'live', 'ended', 'cancelled'], default: 'scheduled' },
      notes: String,
      /** Recording only when the organization enables it and participants are told. */
      recording: { enabled: Boolean, disclosedAt: Date, fileId: ObjectId },
      startedAt: Date,
      endedAt: Date,
    },
    baseOptions,
  ),
);

export const CallLogSchema = orgScoped(
  new Schema(
    {
      meetingId: ObjectId,
      roomId: String,
      userId: ObjectId,
      joinedAt: Date,
      leftAt: Date,
      outcome: { type: String, enum: ['completed', 'failed', 'permission_denied', 'network_lost'] },
    },
    { ...baseOptions, collection: 'call_logs' },
  ),
);
