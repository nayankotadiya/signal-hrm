import { Module } from '@nestjs/common';
import { AppConfigModule } from '../config/config.module';
import { DatabaseModule } from '../database/database.module';
import { ModelsModule } from '../database/models.module';
import { SetupModule } from '../modules/setup/setup.module';

/** Minimal context for command-line scripts (no HTTP server, no schedulers). */
@Module({ imports: [AppConfigModule, DatabaseModule, ModelsModule, SetupModule] })
export class ScriptsModule {}
