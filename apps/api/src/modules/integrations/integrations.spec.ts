import { createHmac } from 'node:crypto';
import { mapMetaLead, verifyMetaSignature } from './integrations.service';

describe('Meta lead ads', () => {
  it('maps lead form fields', () => {
    const m = mapMetaLead([
      { name: 'full_name', values: ['Asha Rao'] },
      { name: 'email', values: ['asha@example.com'] },
      { name: 'phone_number', values: ['+919876543210'] },
      { name: 'city', values: ['Surat'] },
    ]);
    expect(m).toEqual({ name: 'Asha Rao', email: 'asha@example.com', phone: '+919876543210', extra: { city: 'Surat' } });
    expect(mapMetaLead([{ name: 'first_name', values: ['A'] }, { name: 'last_name', values: ['B'] }]).name).toBe('A B');
    expect(mapMetaLead([]).name).toBe('Meta lead');
  });

  it('verifies X-Hub-Signature-256 over the raw body', () => {
    const raw = Buffer.from('{"entry":[]}');
    const sig = 'sha256=' + createHmac('sha256', 'secret').update(raw).digest('hex');
    expect(verifyMetaSignature(raw, sig, 'secret')).toBe(true);
    expect(verifyMetaSignature(raw, sig, 'other')).toBe(false);
    expect(verifyMetaSignature(Buffer.from('{"entry":[1]}'), sig, 'secret')).toBe(false);
    expect(verifyMetaSignature(undefined, sig, 'secret')).toBe(false);
    expect(verifyMetaSignature(raw, 'sha1=abc', 'secret')).toBe(false);
  });
});
