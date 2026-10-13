import { HttpStatus, Inject, Injectable } from '@nestjs/common';
import { Model } from 'mongoose';
import { hashPassword, hmac, passwordProblem, randomToken } from '../../common/crypto/crypto';
import { ApiError } from '../../common/errors/api-error';
import { APP_CONFIG } from '../../config/config.module';
import { AppEnv, secretOf } from '../../config/env.schema';
import { InjectModel } from '../../database/model';
import { ProvisioningService } from './provisioning.service';

export interface FirstAdminInput {
  organization: string;
  fullName: string;
  email: string;
  password?: string;
}

/**
 * Creates the organization (if none exists) and its first Super Admin, with an employee record
 * and 10 recovery codes returned once (only hashes are stored). Used by the bootstrap script and
 * by the one-time setup screen. Refuses when a Super Admin already exists.
 */
@Injectable()
export class FirstAdminService {
  constructor(
    @Inject(APP_CONFIG) private readonly env: AppEnv,
    private readonly provisioning: ProvisioningService,
    @InjectModel('Organization') private readonly orgs: Model<any>,
    @InjectModel('User') private readonly users: Model<any>,
    @InjectModel('Employee') private readonly employees: Model<any>,
    @InjectModel('RecoveryCode') private readonly recoveryCodes: Model<any>,
    @InjectModel('AuditLog') private readonly auditLogs: Model<any>,
  ) {}

  async needsSetup(): Promise<boolean> {
    return !(await this.users.exists({ role: 'super_admin' }));
  }

  async create(input: FirstAdminInput, via: 'script' | 'setup_screen'): Promise<{ organization: string; email: string; recoveryCodes: string[] }> {
    if (!(await this.needsSetup())) {
      throw new ApiError(HttpStatus.CONFLICT, 'SETUP_DONE', 'This server already has a Super Admin. Sign in instead.');
    }
    const email = input.email.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'VALIDATION_FAILED', 'Enter a valid email address.', [{ field: 'email', message: 'Not a valid email' }]);
    }
    if (input.password !== undefined) {
      const problem = passwordProblem(input.password, via === 'script' ? [] : [email, ...input.fullName.split(' ')]);
      if (problem) throw new ApiError(HttpStatus.UNPROCESSABLE_ENTITY, 'VALIDATION_FAILED', problem, [{ field: 'password', message: problem }]);
    }
    let org = await this.orgs.findOne().lean<any>();
    if (!org) org = (await this.orgs.create({ name: input.organization.trim() })).toObject();
    await this.provisioning.provision(org._id);

    const name = input.fullName.trim();
    const employee = await this.employees.create({
      organizationId: org._id,
      employeeCode: 'EMP-0001',
      firstName: name.split(' ')[0],
      lastName: name.split(' ').slice(1).join(' '),
      contactEmail: email,
      designation: 'Founder',
      status: 'active',
      joiningDate: new Date(),
    });
    const user = await this.users.create({
      organizationId: org._id,
      fullName: name,
      displayName: name.split(' ')[0],
      email,
      emailVerified: via === 'script',
      role: 'super_admin',
      status: 'active',
      employeeId: employee._id,
      timezone: org.timezone ?? 'Asia/Kolkata',
      ...(input.password ? { passwordHash: hashPassword(input.password), passwordSetAt: new Date() } : {}),
    });
    await this.employees.updateOne({ _id: employee._id }, { $set: { userId: user._id } });

    const codes = Array.from({ length: 10 }, () => randomToken(8).replace(/[^A-Za-z0-9]/g, '').slice(0, 10).toUpperCase());
    await this.recoveryCodes.insertMany(codes.map((c) => ({ organizationId: org._id, userId: user._id, codeHash: hmac(secretOf(this.env, 'OTP_PEPPER'), c) })));
    await this.users.updateOne({ _id: user._id }, { $set: { recoveryCodesGeneratedAt: new Date() } });
    await this.auditLogs.create({ organizationId: org._id, action: 'bootstrap.super_admin', resourceType: 'user', resourceId: String(user._id), outcome: 'success', metadata: { via }, at: new Date() });
    return { organization: org.name, email, recoveryCodes: codes };
  }
}
