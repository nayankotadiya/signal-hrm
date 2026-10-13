import { Module } from '@nestjs/common';
import { AuditController, ModerationController, SecurityController } from './security.controllers';

@Module({ controllers: [ModerationController, AuditController, SecurityController] })
export class SecurityModule {}
