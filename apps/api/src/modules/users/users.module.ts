import { Global, Module } from '@nestjs/common';
import { MeController, UsersController } from './users.controller';
import { UsersService } from './users.service';

@Global()
@Module({ controllers: [UsersController, MeController], providers: [UsersService], exports: [UsersService] })
export class UsersModule {}
