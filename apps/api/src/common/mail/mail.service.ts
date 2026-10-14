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

/** SMTP email with Gmail direct transport, IPv4 enforcement and reliable sender handling. */
@Injectable()
export class MailService {
  private readonly logger = new Logger('Mail');
  private transport?: Transporter;

  constructor(@Inject(APP_CONFIG) private readonly env: AppEnv) {
    if (env.SMTP_HOST || env.SMTP_USER) {
      const isGmail = env.SMTP_HOST === 'smtp.gmail.com' || (!env.SMTP_HOST && env.SMTP_USER?.endsWith('@gmail.com'));
      if (isGmail && env.SMTP_USER && env.SMTP_PASS) {
        this.logger.log(`Configuring Gmail transport for ${env.SMTP_USER}`);
        this.transport = nodemailer.createTransport({
          service: 'gmail',
          auth: { user: env.SMTP_USER, pass: env.SMTP_PASS },
          family: 4,
          connectionTimeout: 15_000,
          greetingTimeout: 15_000,
          socketTimeout: 20_000,
        } as any);
      } else if (env.SMTP_HOST) {
        this.logger.log(`Configuring SMTP transport host=${env.SMTP_HOST} port=${env.SMTP_PORT}`);
        this.transport = nodemailer.createTransport({
          host: env.SMTP_HOST,
          port: env.SMTP_PORT,
          secure: env.SMTP_SECURE || env.SMTP_PORT === 465,
          auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS } : undefined,
          family: 4,
          connectionTimeout: 15_000,
          greetingTimeout: 15_000,
          socketTimeout: 20_000,
        } as any);
      }
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
      throw new Error('Email is not configured (SMTP_HOST or SMTP_USER).');
    }

    const defaultFrom = this.env.SMTP_USER ? `Signal HRM <${this.env.SMTP_USER}>` : undefined;
    const from = (this.env.MAIL_FROM && !this.env.MAIL_FROM.includes('localhost'))
      ? this.env.MAIL_FROM
      : (defaultFrom || this.env.MAIL_FROM);

    try {
      await this.transport.sendMail({ from, ...msg });
    } catch (err: any) {
      this.logger.error(`SMTP delivery error to ${msg.to}: ${err?.message || err}`);
      throw err;
    }
  }
}
