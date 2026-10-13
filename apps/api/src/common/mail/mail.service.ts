import { Inject, Injectable, Logger } from '@nestjs/common';
import nodemailer, { Transporter } from 'nodemailer';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
  html?: string;
}

/** SMTP email. Without SMTP configured, development logs a one-line notice (never the content in production). */
@Injectable()
export class MailService {
  private readonly logger = new Logger('Mail');
  private transport?: Transporter;

  constructor(@Inject(APP_CONFIG) private readonly env: AppEnv) {
    if (env.SMTP_HOST) {
      this.transport = nodemailer.createTransport({
        host: env.SMTP_HOST,
        port: env.SMTP_PORT,
        secure: env.SMTP_SECURE,
        auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS } : undefined,
      });
    }
  }

  get configured(): boolean {
    return !!this.transport;
  }

  /** True when send() will deliver (or, in development, log) instead of throwing. */
  get canSend(): boolean {
    return !!this.transport || this.env.APP_ENV === 'development';
  }

  async send(msg: MailMessage): Promise<void> {
    if (!this.transport) {
      if (this.env.APP_ENV === 'development') {
        this.logger.log(`(no SMTP) would email ${msg.to}: ${msg.subject}`);
        return;
      }
      throw new Error('Email is not configured (SMTP_HOST).');
    }
    await this.transport.sendMail({ from: this.env.MAIL_FROM, ...msg });
  }
}
