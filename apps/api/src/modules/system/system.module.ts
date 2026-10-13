import { MiddlewareConsumer, Module, NestModule } from '@nestjs/common';
import { HealthModule } from '../../health/health.module';
import { MetricsMiddleware, MetricsService } from './metrics.service';
import { SystemController } from './system.controller';

@Module({ imports: [HealthModule], controllers: [SystemController], providers: [MetricsService], exports: [MetricsService] })
export class SystemModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(MetricsMiddleware).forRoutes('{*path}');
  }
}
