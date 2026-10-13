import { checkGeofence, haversineMeters, speedKmh } from './geo';

describe('Haversine geofence (Phase 4)', () => {
  const office = { latitude: 23.0225, longitude: 72.5714, radiusMeters: 150 };

  it('measures known distances accurately', () => {
    // Ahmedabad to Mumbai is about 440 km great-circle.
    const km = haversineMeters(23.0225, 72.5714, 19.076, 72.8777) / 1000;
    expect(km).toBeGreaterThan(435);
    expect(km).toBeLessThan(445);
    // One thousandth of a degree of latitude is about 111 m.
    expect(haversineMeters(0, 0, 0.001, 0)).toBeCloseTo(111.2, 0);
    expect(haversineMeters(10, 10, 10, 10)).toBe(0);
  });

  it('accepts a precise fix inside the radius', () => {
    const v = checkGeofence({ latitude: 23.0226, longitude: 72.5715, accuracyMeters: 12 }, office, 50);
    expect(v).toEqual({ ok: true, verification: 'within_radius', distanceMeters: expect.any(Number) });
    if (v.ok) expect(v.distanceMeters).toBeLessThan(20);
  });

  it('refuses a fix less precise than the configured limit, before looking at distance', () => {
    const v = checkGeofence({ latitude: 23.0225, longitude: 72.5714, accuracyMeters: 400 }, office, 50);
    expect(v).toEqual({ ok: false, verification: 'accuracy_too_low', accuracyMeters: 400, requiredAccuracy: 50 });
  });

  it('treats a non-numeric accuracy as too imprecise', () => {
    expect(checkGeofence({ latitude: 23.0225, longitude: 72.5714, accuracyMeters: Number.NaN }, office, 50).ok).toBe(false);
  });

  it('refuses a precise fix outside the radius and reports the distance', () => {
    const v = checkGeofence({ latitude: 23.04, longitude: 72.5714, accuracyMeters: 10 }, office, 50);
    expect(v.ok).toBe(false);
    if (!v.ok && v.verification === 'outside_radius') {
      expect(v.distanceMeters).toBeGreaterThan(1900);
      expect(v.radiusMeters).toBe(150);
    } else throw new Error('expected outside_radius');
  });

  it('boundary: exactly on the radius is inside', () => {
    const lat = 23.0225 + 150 / 111_195;
    const v = checkGeofence({ latitude: lat, longitude: 72.5714, accuracyMeters: 5 }, office, 50);
    expect(v.ok).toBe(true);
  });

  it('computes speeds for impossible-travel checks', () => {
    const a = { latitude: 23.0225, longitude: 72.5714, at: new Date('2026-10-12T10:00:00Z') };
    const b = { latitude: 19.076, longitude: 72.8777, at: new Date('2026-10-12T10:05:00Z') };
    expect(speedKmh(a, b)).toBeGreaterThan(5000);
    expect(speedKmh(a, { ...a, at: a.at })).toBe(0);
    expect(speedKmh(a, { ...b, at: a.at })).toBe(Infinity);
  });
});
