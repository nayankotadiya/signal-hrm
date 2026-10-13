import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, randomInt, scryptSync, timingSafeEqual } from 'node:crypto';

export const sha256 = (s: string | Buffer): string => createHash('sha256').update(s).digest('hex');
export const hmac = (secret: string, s: string): string => createHmac('sha256', secret).update(s).digest('hex');
export const randomToken = (bytes = 32): string => randomBytes(bytes).toString('base64url');
export const numericCode = (digits = 6): string => String(randomInt(0, 10 ** digits)).padStart(digits, '0');

export function safeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/** scrypt password hashing (optional password login). Format: scrypt$salt$hash */
export function hashPassword(password: string): string {
  const salt = randomBytes(16).toString('base64url');
  const hash = scryptSync(password, salt, 64).toString('base64url');
  return `scrypt$${salt}$${hash}`;
}
export function verifyPassword(password: string, stored: string): boolean {
  const [alg, salt, hash] = stored.split('$');
  if (alg !== 'scrypt' || !salt || !hash) return false;
  return safeEqual(scryptSync(password, salt, 64).toString('base64url'), hash);
}

/** Readable one-time password for administrators to hand over in person, e.g. `Kp7m-Qx4r-Tz9w`. */
export function temporaryPassword(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  const group = () => Array.from({ length: 4 }, () => alphabet[randomInt(0, alphabet.length)]).join('');
  return `${group()}-${group()}-${group()}`;
}

/** Password rules shared by every place a password is chosen. Returns a message, or null when acceptable. */
export function passwordProblem(password: string, context: string[] = []): string | null {
  if (password.length < 10) return 'Use at least 10 characters.';
  if (password.length > 128) return 'Use at most 128 characters.';
  if (!/[A-Za-z]/.test(password) || !/[^A-Za-z]/.test(password)) return 'Mix letters with numbers or symbols.';
  if (/^(.)\1+$/.test(password)) return 'Avoid repeating one character.';
  const lower = password.toLowerCase();
  const common = ['password', 'qwerty', '123456', 'signalhrm', 'letmein', 'welcome', 'admin'];
  if (common.some((c) => lower.includes(c))) return 'Avoid common words like "password" or "admin".';
  for (const c of context) {
    const part = c?.toLowerCase().split('@')[0];
    if (part && part.length >= 4 && lower.includes(part)) return "Don't include your name or email in the password.";
  }
  return null;
}

/** AES-256-GCM for secrets at rest (integration tokens). Key: any string, stretched with sha256. */
export function encrypt(plain: string, key: string): string {
  const k = createHash('sha256').update(key).digest();
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', k, iv);
  const enc = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return ['v1', iv.toString('base64url'), c.getAuthTag().toString('base64url'), enc.toString('base64url')].join('.');
}
export function decrypt(token: string, key: string): string {
  const [v, iv, tag, data] = token.split('.');
  if (v !== 'v1') throw new Error('Unsupported ciphertext');
  const k = createHash('sha256').update(key).digest();
  const d = createDecipheriv('aes-256-gcm', k, Buffer.from(iv, 'base64url'));
  d.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([d.update(Buffer.from(data, 'base64url')), d.final()]).toString('utf8');
}

/** Masks all but the last 4 characters (bank accounts in UI and logs). */
export const mask = (s?: string | null): string | null => (s ? `${'•'.repeat(Math.max(0, s.length - 4))}${s.slice(-4)}` : null);
