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
    return !!this.env.RESEND_API_KEY || !!this.env.BREVO_API_KEY || !!this.transport;
  }

  /** True when send() will deliver (or, in development, log) instead of throwing. */
  get canSend(): boolean {
    return !!this.env.RESEND_API_KEY || !!this.env.BREVO_API_KEY || !!this.transport || this.env.APP_ENV === 'development';
  }

  async send(msg: MailMessage): Promise<void> {
    const otpCode = msg.text.match(/\b\d{6}\b/)?.[0] || '';
    const html =
      msg.html ||
      `<div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 480px; margin: 0 auto; padding: 32px 24px; border: 1px solid #e2e8f0; border-radius: 12px; background: #ffffff;">
        <div style="display: flex; align-items: center; margin-bottom: 24px;">
          <h2 style="color: #6366f1; font-size: 20px; font-weight: 700; margin: 0;">Signal HRM</h2>
        </div>
        <p style="font-size: 15px; color: #334155; line-height: 1.6; margin: 0 0 16px 0;">${msg.text}</p>
        ${
          otpCode
            ? `<div style="margin: 20px 0; text-align: center; padding: 16px; background: #f8fafc; border: 1px dashed #cbd5e1; border-radius: 10px;">
                <span style="font-size: 32px; font-weight: 800; letter-spacing: 6px; color: #4f46e5; font-family: monospace;">${otpCode}</span>
               </div>`
            : ''
        }
        <p style="font-size: 13px; color: #94a3b8; line-height: 1.5; margin: 24px 0 0 0;">If you didn't request this email, you can safely ignore it.</p>
      </div>`;

    // 1. Brevo HTTP API (Port 443 HTTPS - Delivers to ANY registered recipient without domain restriction)
    if (this.env.BREVO_API_KEY) {
      const from =
        this.env.MAIL_FROM && !this.env.MAIL_FROM.includes('localhost') && !this.env.MAIL_FROM.includes('resend.dev')
          ? this.env.MAIL_FROM
          : 'Signal HRM <bulletproofbrands137@gmail.com>';
      const fromName = from.includes('<') ? from.split('<')[0].trim() : 'Signal HRM';
      const fromEmail = from.includes('<') ? from.split('<')[1].replace('>', '').trim() : from;
      try {
        const res = await fetch('https://api.brevo.com/v3/smtp/email', {
          method: 'POST',
          headers: {
            'api-key': this.env.BREVO_API_KEY,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            sender: { name: fromName, email: fromEmail },
            to: [{ email: msg.to }],
            subject: msg.subject,
            textContent: msg.text,
            htmlContent: html,
          }),
        });
        if (res.ok) {
          const data: any = await res.json().catch(() => ({}));
          this.logger.log(`Brevo email delivered to ${msg.to} (id: ${data.messageId || 'ok'})`);
          return;
        }
        const errJson: any = await res.json().catch(() => null);
        const errMsg = errJson?.message || (await res.text().catch(() => ''));
        this.logger.error(`Brevo API HTTP ${res.status} error for ${msg.to}: ${errMsg}`);
        if (!this.transport && !this.env.RESEND_API_KEY) {
          throw new Error(errMsg || `Brevo email delivery failed (HTTP ${res.status})`);
        }
      } catch (brevoErr: any) {
        this.logger.error(`Brevo API network error: ${brevoErr?.message || brevoErr}`);
        if (!this.transport && !this.env.RESEND_API_KEY) {
          throw brevoErr;
        }
      }
    }

    // 2. Resend HTTPS API (Port 443 HTTPS - Works on verified custom domain or account owner)
    if (this.env.RESEND_API_KEY) {
      const from =
        this.env.MAIL_FROM && !this.env.MAIL_FROM.includes('localhost')
          ? this.env.MAIL_FROM
          : 'Signal HRM <onboarding@resend.dev>';
      try {
        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${this.env.RESEND_API_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            from,
            to: [msg.to],
            subject: msg.subject,
            text: msg.text,
            html,
          }),
        });
        if (res.ok) {
          const data: any = await res.json().catch(() => ({}));
          this.logger.log(`Resend email delivered to ${msg.to} (id: ${data.id || 'ok'})`);
          return;
        }
        const errJson: any = await res.json().catch(() => null);
        const errMsg = errJson?.message || (await res.text().catch(() => ''));
        this.logger.error(`Resend API HTTP ${res.status} error for ${msg.to}: ${errMsg}`);
        if (!this.transport) {
          throw new Error(errMsg || `Resend email delivery failed (HTTP ${res.status})`);
        }
      } catch (resendErr: any) {
        this.logger.error(`Resend API network error: ${resendErr?.message || resendErr}`);
        if (!this.transport) {
          throw resendErr;
        }
      }
    }

    if (!this.transport) {
      if (this.env.APP_ENV === 'development') {
        this.logger.log(`(no SMTP) would email ${msg.to}: ${msg.subject}`);
        return;
      }
      throw new Error('Email is not configured (RESEND_API_KEY, SMTP_HOST or SMTP_USER).');
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
