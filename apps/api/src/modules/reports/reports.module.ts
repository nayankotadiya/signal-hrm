import { Module } from '@nestjs/common';
import { SearchController } from '../search/search.controller';
import { SearchService } from '../search/search.service';
import { ReportsController } from './reports.controller';
import { ReportsService } from './reports.service';

@Module({ controllers: [ReportsController, SearchController], providers: [ReportsService, SearchService], exports: [ReportsService] })
export class ReportsModule {}
