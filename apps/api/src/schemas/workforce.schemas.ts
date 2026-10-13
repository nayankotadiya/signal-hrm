import { Schema } from 'mongoose';
import { baseOptions, orgScoped } from '../database/model';

const { ObjectId, Mixed } = Schema.Types;

export const EMPLOYMENT_STATUSES = ['onboarding', 'active', 'probation', 'notice', 'exited', 'archived'] as const;
export const EMPLOYMENT_TYPES = ['full_time', 'part_time', 'contract', 'intern', 'consultant'] as const;

export const EmployeeSchema = orgScoped(
  new Schema(
    {
      employeeCode: { type: String, required: true, trim: true },
      userId: { type: ObjectId, index: true },
      firstName: { type: String, required: true, trim: true },
      lastName: { type: String, trim: true, default: '' },
      displayName: String,
      photoFileId: ObjectId,
      contactEmail: { type: String, lowercase: true, trim: true },
      contactPhone: String,
      emergencyContact: { name: String, relation: String, phone: String },
      // Employment
      joiningDate: Date,
      employmentType: { type: String, enum: EMPLOYMENT_TYPES, default: 'full_time' },
      designation: String,
      departmentId: { type: ObjectId, index: true },
      teamId: { type: ObjectId, index: true },
      reportingManagerId: { type: ObjectId, index: true },
      locationId: { type: ObjectId, index: true },
      shiftId: ObjectId,
      status: { type: String, enum: EMPLOYMENT_STATUSES, default: 'onboarding', index: true },
      probation: { endsOn: Date, status: { type: String, enum: ['none', 'on_probation', 'confirmed', 'extended'], default: 'none' } },
      exitDate: Date,
      salaryStructureId: ObjectId,
      // Sensitive (separate permission: employees_sensitive). Never returned without it.
      sensitive: {
        dateOfBirth: Date,
        exitReason: String,
        bank: { accountName: String, accountNumberEnc: String, accountLast4: String, ifsc: String, bankName: String },
        tax: { panEnc: String, panLast4: String, uanEnc: String, regime: String },
      },
      archivedAt: Date,
      createdBy: ObjectId,
    },
    baseOptions,
  ),
);
EmployeeSchema.index({ organizationId: 1, employeeCode: 1 }, { unique: true });
EmployeeSchema.index({ organizationId: 1, contactEmail: 1 }, { unique: true, partialFilterExpression: { contactEmail: { $type: 'string' } } });
EmployeeSchema.index({ organizationId: 1, firstName: 1, lastName: 1 });

/** Every change of department, team, manager, designation, location or status. Preserves history for reports. */
export const EmployeeHistorySchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      type: { type: String, enum: ['joined', 'transfer', 'promotion', 'manager_change', 'status_change', 'location_change', 'exit', 'rehire'] },
      from: Mixed,
      to: Mixed,
      effectiveOn: { type: Date, default: Date.now },
      note: String,
      byUserId: ObjectId,
    },
    baseOptions,
  ),
);

export const ChecklistSchema = orgScoped(
  new Schema(
    {
      employeeId: { type: ObjectId, required: true, index: true },
      kind: { type: String, enum: ['onboarding', 'offboarding'], required: true },
      status: { type: String, enum: ['open', 'completed', 'cancelled'], default: 'open' },
      items: [
        {
          key: String,
          title: String,
          day: Number, // onboarding journey day
          ownerRole: String,
          ownerUserId: ObjectId,
          done: { type: Boolean, default: false },
          doneAt: Date,
          doneBy: ObjectId,
          linkedDocumentId: ObjectId,
        },
      ],
      buddyEmployeeId: ObjectId,
      lastWorkingDay: Date,
      approvalId: ObjectId,
      completedAt: Date,
    },
    baseOptions,
  ),
);
ChecklistSchema.index({ organizationId: 1, employeeId: 1, kind: 1, status: 1 });

export const DepartmentSchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true, trim: true },
      description: String,
      headEmployeeId: ObjectId,
      status: { type: String, enum: ['active', 'archived'], default: 'active' },
      createdBy: ObjectId,
    },
    baseOptions,
  ),
);
DepartmentSchema.index({ organizationId: 1, name: 1 }, { unique: true });

export const TeamSchema = orgScoped(
  new Schema(
    {
      name: { type: String, required: true, trim: true },
      departmentId: { type: ObjectId, index: true },
      leadEmployeeId: { type: ObjectId, index: true },
      /** Membership lives on employees.teamId; this mirrors it for quick reads. */
      memberIds: { type: [ObjectId], default: [] },
      status: { type: String, enum: ['active', 'archived'], default: 'active' },
    },
    baseOptions,
  ),
);
TeamSchema.index({ organizationId: 1, departmentId: 1, name: 1 }, { unique: true });
