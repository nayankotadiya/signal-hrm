import { Inject, Injectable, Logger } from '@nestjs/common';
import { APP_CONFIG } from '../../config/config.module';
import type { AppEnv } from '../../config/env.schema';

export interface SmsMessage {
  to: string; // E.164 phone number, e.g. +919876543210
  message: string;
}

/**
 * Multi-provider SMS service supporting:
 * 1. Twilio (Global SMS)
 * 2. Fast2SMS (India OTP route)
 * 3. Generic HTTP SMS Gateway / Webhook
 * 4. Development echo (logs to console)
 */
@Injectable()
export class SmsService {
  private readonly logger = new Logger('Sms');

  constructor(@Inject(APP_CONFIG) private readonly env: AppEnv) {}

  get isTwilioConfigured(): boolean {
    return !!(this.env.TWILIO_ACCOUNT_SID && this.env.TWILIO_AUTH_TOKEN && this.env.TWILIO_FROM_PHONE);
  }

  get isFast2SmsConfigured(): boolean {
    return !!this.env.FAST2SMS_API_KEY;
  }

  get isGatewayConfigured(): boolean {
    return !!this.env.SMS_GATEWAY_URL;
  }

  get configured(): boolean {
    return this.isTwilioConfigured || this.isFast2SmsConfigured || this.isGatewayConfigured;
  }

  get canSend(): boolean {
    return this.configured || this.env.APP_ENV === 'development' || this.env.OTP_DEV_ECHO;
  }

  async send(msg: SmsMessage): Promise<void> {
    const to = msg.to.trim();
    const message = msg.message.trim();

    if (this.isTwilioConfigured) {
      await this.sendTwilio(to, message);
      return;
    }

    if (this.isFast2SmsConfigured) {
      await this.sendFast2Sms(to, message);
      return;
    }

    if (this.isGatewayConfigured) {
      await this.sendCustomGateway(to, message);
      return;
    }

    if (this.env.APP_ENV === 'development' || this.env.OTP_DEV_ECHO) {
      this.logger.warn(`[dev echo] SMS to ${to}: ${message}`);
      return;
    }

    throw new Error('SMS service is not configured (set TWILIO_ACCOUNT_SID or FAST2SMS_API_KEY or SMS_GATEWAY_URL).');
  }

  private async sendTwilio(to: string, body: string): Promise<void> {
    const sid = this.env.TWILIO_ACCOUNT_SID!;
    const token = this.env.TWILIO_AUTH_TOKEN!;
    const from = this.env.TWILIO_FROM_PHONE!;

    const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}/Messages.json`;
    const params = new URLSearchParams({ To: to, From: from, Body: body });

    const auth = Buffer.from(`${sid}:${token}`).toString('base64');
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${auth}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: params.toString(),
      signal: AbortSignal.timeout(10000),
    });

    if (!res.ok) {
      const errText = await res.text().catch(() => '');
      this.logger.error(`Twilio SMS failed (HTTP ${res.status}): ${errText}`);
      throw new Error(`Failed to send SMS via Twilio: HTTP ${res.status}`);
    }
  }

  private async sendFast2Sms(to: string, message: string): Promise<void> {
    // Fast2SMS accepts 10-digit Indian numbers without +91 or with 91
    const cleanedNumber = to.replace(/\D/g, '').slice(-10);
    const apiKey = this.env.FAST2SMS_API_KEY!;

    const res = await fetch('https://www.fast2sms.com/dev/bulkV2', {
      method: 'POST',
      headers: {
        authorization: apiKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        route: 'q',
        message,
        language: 'english',
        flash: 0,
        numbers: cleanedNumber,
      }),
      signal: AbortSignal.timeout(10000),
    });

    if (!res.ok) {
      const errText = await res.text().catch(() => '');
      this.logger.error(`Fast2SMS failed (HTTP ${res.status}): ${errText}`);
      throw new Error(`Failed to send SMS via Fast2SMS: HTTP ${res.status}`);
    }
  }

  private async sendCustomGateway(to: string, message: string): Promise<void> {
    const url = this.env.SMS_GATEWAY_URL!;
    const apiKey = this.env.SMS_API_KEY;

    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (apiKey) headers['Authorization'] = `Bearer ${apiKey}`;

    const res = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify({ to, message }),
      signal: AbortSignal.timeout(10000),
    });

    if (!res.ok) {
      this.logger.error(`Custom SMS gateway failed (HTTP ${res.status})`);
      throw new Error(`Failed to send SMS via custom gateway: HTTP ${res.status}`);
    }
  }
}
