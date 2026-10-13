import { Global, Module } from '@nestjs/common';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { SessionService } from './session.service';

@Global()
@Module({ controllers: [AuthController], providers: [AuthService, SessionService], exports: [SessionService, AuthService] })
export class AuthModule {}
