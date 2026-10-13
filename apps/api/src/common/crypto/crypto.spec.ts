import { decrypt, encrypt, hashPassword, mask, numericCode, passwordProblem, safeEqual, temporaryPassword, verifyPassword } from './crypto';

describe('crypto helpers', () => {
  const key = 'k'.repeat(40);

  it('AES-GCM round-trips and detects tampering', () => {
    const t = encrypt('123456789012', key);
    expect(t.startsWith('v1.')).toBe(true);
    expect(t).not.toContain('123456789012');
    expect(decrypt(t, key)).toBe('123456789012');
    const parts = t.split('.');
    parts[3] = Buffer.from('tampered').toString('base64url');
    expect(() => decrypt(parts.join('.'), key)).toThrow();
    expect(() => decrypt(t, 'x'.repeat(40))).toThrow();
  });

  it('encrypting twice gives different ciphertexts (random IV)', () => {
    expect(encrypt('same', key)).not.toBe(encrypt('same', key));
  });

  it('password hashing verifies only the right password', () => {
    const h = hashPassword('correct horse battery');
    expect(verifyPassword('correct horse battery', h)).toBe(true);
    expect(verifyPassword('wrong', h)).toBe(false);
  });

  it('numeric codes and masking', () => {
    for (let i = 0; i < 50; i++) expect(numericCode(6)).toMatch(/^\d{6}$/);
    expect(mask('ABCDE1234F')).toBe('••••••234F');
    expect(mask(null)).toBeNull();
    expect(safeEqual('abc', 'abc')).toBe(true);
    expect(safeEqual('abc', 'abd')).toBe(false);
    expect(safeEqual('abc', 'abcd')).toBe(false);
  });

  it('password rules reject short, single-class, common and personal passwords', () => {
    expect(passwordProblem('short1')).toMatch(/10 characters/);
    expect(passwordProblem('onlyletterslong')).toMatch(/Mix letters/);
    expect(passwordProblem('1234567890123')).toMatch(/Mix letters/);
    expect(passwordProblem('MyPassword2026')).toMatch(/common words/);
    expect(passwordProblem('nayan-2026-hrm!', ['nayan@bulletproof.test'])).toMatch(/name or email/);
    expect(passwordProblem('Blue-river-42-kite')).toBeNull();
  });

  it('temporary passwords are readable, unique and pass the rules', () => {
    const a = temporaryPassword();
    const b = temporaryPassword();
    expect(a).toMatch(/^[A-Za-z2-9]{4}-[A-Za-z2-9]{4}-[A-Za-z2-9]{4}$/);
    expect(a).not.toEqual(b);
    expect(a).not.toMatch(/[01OIl]/);
    expect(passwordProblem(a)).toBeNull();
  });
});
