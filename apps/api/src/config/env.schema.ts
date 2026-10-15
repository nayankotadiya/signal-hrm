import { z } from 'zod';

const bool = z
  .union([z.boolean(), z.string()])
  .transform((v) => (typeof v === 'boolean' ? v : ['1', 'true', 'yes', 'on'].includes(v.toLowerCase())));

const optionalString = z
  .string()
  .optional()
  .transform((v) => {
    if (!v) return undefined;
    let s = v.trim();
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
      s = s.slice(1, -1).trim();
    }
    return s.length > 0 ? s : undefined;
  });

export const envSchema = z
  .object({
    APP_ENV: z.enum(['development', 'staging', 'production']).default('development'),
    PORT: z.coerce.number().int().min(1).max(65535).default(3000),
    API_PREFIX: z.string().default('api'),
    CORS_ORIGINS: z
      .string()
      .default('')
      .transform((v) =>
        v
          .split(',')
          .map((s) => s.trim())
          .filter(Boolean),
      ),
    MONGODB_URI: optionalString,
    MONGODB_DB_NAME: z.string().default('signal_hrm_dev'),
    MONGODB_STORAGE_LIMIT_MB: z.coerce.number().positive().default(512),
    REDIS_URL: optionalString,
    RATE_LIMIT_TTL_MS: z.coerce.number().int().positive().default(60_000),
    RATE_LIMIT_MAX: z.coerce.number().int().positive().default(120),
    // Files: none | local (disk, dev and small installs) | google_drive (service account) | mongodb (Atlas GridFS)
    STORAGE_PROVIDER: z.enum(['none', 'local', 'google_drive', 'mongodb']).default('none'),
    LOCAL_STORAGE_DIR: z.string().default('./var/storage'),
    GOOGLE_DRIVE_CREDENTIALS_JSON: optionalString, // service-account JSON (server only)
    GOOGLE_DRIVE_ROOT_FOLDER_ID: optionalString,
    GOOGLE_DRIVE_REFRESH_TOKEN: optionalString,
    GOOGLE_DRIVE_CLIENT_ID: optionalString,
    GOOGLE_DRIVE_CLIENT_SECRET: optionalString,
    GOOGLE_CLIENT_SECRET: optionalString,
    MAX_UPLOAD_MB: z.coerce.number().int().positive().default(15),

    // Auth and sessions
    PUBLIC_WEB_URL: z.string().default('http://localhost:8080'),
    JWT_SECRET: optionalString, // >= 32 chars; required outside development
    ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
    REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(30),
    OTP_PEPPER: optionalString, // secret mixed into OTP hashes
    OTP_TTL_SECONDS: z.coerce.number().int().positive().default(600),
    OTP_MAX_ATTEMPTS: z.coerce.number().int().positive().default(5),
    OTP_RESEND_SECONDS: z.coerce.number().int().positive().default(60),
    OTP_DEV_ECHO: bool.default(false), // development only: also logs codes to the server console
    PASSWORD_LOGIN: bool.default(true),
    /** One-time first-admin setup from the sign-in screen (hosts without a shell). 24+ characters; remove after setup. */
    SETUP_TOKEN: optionalString,
    GOOGLE_CLIENT_IDS: z.string().default('').transform((v) => v.split(',').map((s) => s.trim()).filter(Boolean)),
    APPLE_CLIENT_IDS: z.string().default('').transform((v) => v.split(',').map((s) => s.trim()).filter(Boolean)),
    COOKIE_SECURE: bool.default(false),
    COOKIE_SAME_SITE: z.enum(['strict', 'lax', 'none']).default('lax'),

    // Encryption at rest for integration tokens and other secrets (32-byte base64 key)
    ENCRYPTION_KEY: optionalString,

    // Email (Resend HTTP API or nodemailer SMTP)
    RESEND_API_KEY: optionalString,
    SMTP_HOST: optionalString,
    SMTP_PORT: z.coerce.number().int().positive().default(587),
    SMTP_USER: optionalString,
    SMTP_PASS: optionalString,
    SMTP_SECURE: bool.default(false),
    MAIL_FROM: z.string().default('Signal HRM <onboarding@resend.dev>'),

    // SMS (Twilio / Fast2SMS / Custom HTTP Gateway). Without configuration, development logs OTP to console.
    TWILIO_ACCOUNT_SID: optionalString,
    TWILIO_AUTH_TOKEN: optionalString,
    TWILIO_FROM_PHONE: optionalString,
    FAST2SMS_API_KEY: optionalString,
    SMS_GATEWAY_URL: optionalString,
    SMS_API_KEY: optionalString,

    // Backups
    BACKUP_ENABLED: bool.default(false),
    BACKUP_CRON: z.string().default('30 2 * * *'),
    MONGODUMP_PATH: z.string().default('mongodump'),
    MONGORESTORE_PATH: z.string().default('mongorestore'),
    BACKUP_WORK_DIR: z.string().default('./var/backups'),

    // Web Push Notifications (24/7 background delivery even when app is closed)
    VAPID_PUBLIC_KEY: z.string().default('BN85zPW2Mp0qjdQrWHz9hn2cWbgpLPaXmN0G7rkD-cgQbw3woMYo8euzAtoMop-JpoLUdrYOa1fIfDq0h0RkTfY'),
    VAPID_PRIVATE_KEY: z.string().default('XoesusJN7yzkgQww1AtyG19xnljaGb9BPvb1z1a1WF0'),
    VAPID_SUBJECT: z.string().default('mailto:support@signalhrm.com'),

    // Integrations
    META_APP_SECRET: optionalString,
    META_VERIFY_TOKEN: optionalString,
    FEATURE_AI_ASSISTANT: bool.default(false),
    HEALTH_DB_DEGRADED_MS: z.coerce.number().int().positive().default(500),
    HEALTH_REDIS_DEGRADED_MS: z.coerce.number().int().positive().default(200),
    HEALTH_CHECK_TIMEOUT_MS: z.coerce.number().int().positive().default(2_000),
    /** Reverse-proxy hops to trust for client IPs (1 behind Caddy). 0 = direct. */
    TRUST_PROXY: z.coerce.number().int().min(0).max(5).default(0),
    LOG_LEVEL: z.enum(['error', 'warn', 'log', 'debug', 'verbose']).default('log'),
  })
  .superRefine((env, ctx) => {
    // Staging and production must never run without their data stores.
    if (env.APP_ENV !== 'development') {
      if (!env.MONGODB_URI) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['MONGODB_URI'], message: `required when APP_ENV=${env.APP_ENV}` });
      }
      if (env.CORS_ORIGINS.length === 0) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['CORS_ORIGINS'], message: `required when APP_ENV=${env.APP_ENV}` });
      }
      for (const key of ['JWT_SECRET', 'OTP_PEPPER', 'ENCRYPTION_KEY'] as const) {
        if (!env[key] || env[key]!.length < 24) {
          ctx.addIssue({ code: z.ZodIssueCode.custom, path: [key], message: `required (24+ characters) when APP_ENV=${env.APP_ENV}` });
        }
      }
      if (env.SETUP_TOKEN && env.SETUP_TOKEN.length < 24) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['SETUP_TOKEN'], message: 'must be 24+ characters' });
      }
      if (env.OTP_DEV_ECHO) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['OTP_DEV_ECHO'], message: 'must be false outside development' });
      }
    }
    if (env.APP_ENV === 'production' && !env.COOKIE_SECURE) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['COOKIE_SECURE'], message: 'must be true in production (HTTPS)' });
    }
    if (env.APP_ENV === 'production' && /_dev$|_staging$/.test(env.MONGODB_DB_NAME)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ['MONGODB_DB_NAME'],
        message: 'production must not point at a development or staging database',
      });
    }
  });

export type AppEnv = z.infer<typeof envSchema>;

/** Development fallbacks so a fresh clone runs. Never used outside development (validated above). */
export const DEV_SECRET = 'dev-only-secret-change-me-0123456789abcdef';
export const secretOf = (env: AppEnv, key: 'JWT_SECRET' | 'OTP_PEPPER' | 'ENCRYPTION_KEY'): string => env[key] ?? DEV_SECRET;

/** Parses and validates process environment. Throws one readable error listing every problem. */
export function loadEnv(source: Record<string, string | undefined> = process.env): AppEnv {
  const result = envSchema.safeParse(source);
  if (!result.success) {
    const lines = result.error.issues.map((i) => `  - ${i.path.join('.') || '(root)'}: ${i.message}`);
    throw new Error(`Invalid configuration:\n${lines.join('\n')}`);
  }
  return Object.freeze(result.data);
}
