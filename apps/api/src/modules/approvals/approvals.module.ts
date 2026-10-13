import { Global, Module } from '@nestjs/common';
import { ApprovalEngine } from './approval.engine';
import { ApprovalsController } from './approvals.controller';

@Global()
@Module({ controllers: [ApprovalsController], providers: [ApprovalEngine], exports: [ApprovalEngine] })
export class ApprovalsModule {}
