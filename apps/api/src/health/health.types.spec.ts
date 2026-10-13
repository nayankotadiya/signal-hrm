import { aggregateHealth, withTimeout } from './health.types';

const c = (state: 'healthy' | 'degraded' | 'unavailable' | 'unknown', critical = false) => ({ state, critical });

describe('aggregateHealth', () => {
  it('is unknown with no components (never green without a check)', () => {
    expect(aggregateHealth([])).toBe('unknown');
  });

  it('is healthy only when every critical check passed', () => {
    expect(aggregateHealth([c('healthy', true), c('healthy', true), c('unknown')])).toBe('healthy');
  });

  it('is unavailable when any critical component is unavailable', () => {
    expect(aggregateHealth([c('healthy', true), c('unavailable', true), c('degraded')])).toBe('unavailable');
  });

  it('is degraded when a non-critical component is unavailable', () => {
    expect(aggregateHealth([c('healthy', true), c('unavailable')])).toBe('degraded');
  });

  it('is degraded when a critical component is slow', () => {
    expect(aggregateHealth([c('healthy', true), c('degraded', true)])).toBe('degraded');
  });

  it('is unknown when a critical component could not be checked', () => {
    expect(aggregateHealth([c('healthy', true), c('unknown', true)])).toBe('unknown');
  });
});

describe('withTimeout', () => {
  it('resolves fast promises', async () => {
    await expect(withTimeout(Promise.resolve(7), 50)).resolves.toBe(7);
  });

  it('rejects slow promises with timeout', async () => {
    await expect(withTimeout(new Promise((r) => setTimeout(r, 200)), 10)).rejects.toThrow('timeout');
  });
});
