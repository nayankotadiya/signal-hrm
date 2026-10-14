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
        this.logger.log(`Configuring direct Gmail service transport for ${env.SMTP_USER}`);
        this.transport = nodemailer.createTransport({
          host: 'smtp.gmail.com',
          port: 465,
          secure: true,
          auth: { user: env.SMTP_USER, pass: env.SMTP_PASS },
          tls: { rejectUnauthorized: false },
          family: 4,
          connectionTimeout: 4_000,
          greetingTimeout: 4_000,
          socketTimeout: 5_000,
        } as any);
      } else {
        const host = env.SMTP_HOST || 'smtp.gmail.com';
        const port = env.SMTP_PORT || 465;
        const secure = env.SMTP_SECURE || port === 465;

        this.logger.log(`Configuring email transport host=${host} port=${port} secure=${secure} user=${env.SMTP_USER}`);
        this.transport = nodemailer.createTransport({
          host,
          port,
          secure,
          auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS } : undefined,
          tls: { rejectUnauthorized: false },
          family: 4,
          connectionTimeout: 4_000,
          greetingTimeout: 4_000,
          socketTimeout: 5_000,
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
      this.logger.log(`Email successfully delivered to ${msg.to}: ${msg.subject}`);
    } catch (err: any) {
      this.logger.error(`SMTP delivery error to ${msg.to}: ${err?.message || err}`);
      // Fallback: If port 587 failed, try port 465 SSL or service: 'gmail'
      if (this.env.SMTP_USER && this.env.SMTP_PASS) {
        try {
          this.logger.warn(`Attempting fallback email transport on port 465 for ${msg.to}...`);
          const fallback = nodemailer.createTransport({
            service: 'gmail',
            auth: { user: this.env.SMTP_USER, pass: this.env.SMTP_PASS },
            family: 4,
            connectionTimeout: 5_000,
          } as any);
          await fallback.sendMail({ from, ...msg });
          this.logger.log(`Fallback email successfully delivered to ${msg.to}`);
          return;
        } catch (fallbackErr: any) {
          this.logger.error(`Fallback SMTP delivery also failed: ${fallbackErr?.message || fallbackErr}`);
        }
      }
      throw err;
    }
  }
}
