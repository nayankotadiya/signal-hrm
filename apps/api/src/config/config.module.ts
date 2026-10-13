import { Global, Module } from '@nestjs/common';
import { AppEnv, loadEnv } from './env.schema';

export const APP_CONFIG = Symbol('APP_CONFIG');

@Global()
@Module({
  providers: [{ provide: APP_CONFIG, useFactory: (): AppEnv => loadEnv() }],
  exports: [APP_CONFIG],
})
export class AppConfigModule {}
