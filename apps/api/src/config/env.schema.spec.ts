import { loadEnv } from './env.schema';

describe('loadEnv', () => {
  it('boots development with safe defaults and no data stores', () => {
    const env = loadEnv({ APP_ENV: 'development' });
    expect(env.PORT).toBe(3000);
    expect(env.MONGODB_URI).toBeUndefined();
    expect(env.STORAGE_PROVIDER).toBe('none');
    expect(env.FEATURE_AI_ASSISTANT).toBe(false);
  });

  it('treats blank strings as not configured', () => {
    const env = loadEnv({ APP_ENV: 'development', MONGODB_URI: '   ', REDIS_URL: '' });
    expect(env.MONGODB_URI).toBeUndefined();
    expect(env.REDIS_URL).toBeUndefined();
  });

  it('refuses production without MongoDB, Redis and CORS origins and lists every problem', () => {
    expect(() => loadEnv({ APP_ENV: 'production', MONGODB_DB_NAME: 'signal_hrm' })).toThrow(
      /MONGODB_URI[\s\S]*REDIS_URL[\s\S]*CORS_ORIGINS/,
    );
  });

  it('refuses production pointed at a dev database', () => {
    expect(() =>
      loadEnv({
        APP_ENV: 'production',
        MONGODB_URI: 'mongodb://x',
        REDIS_URL: 'redis://x',
        CORS_ORIGINS: 'https://hrm.example.com',
        MONGODB_DB_NAME: 'signal_hrm_dev',
      }),
    ).toThrow(/MONGODB_DB_NAME/);
  });

  it('parses booleans and CORS lists', () => {
    const env = loadEnv({ FEATURE_AI_ASSISTANT: 'true', CORS_ORIGINS: 'https://a.com, https://b.com' });
    expect(env.FEATURE_AI_ASSISTANT).toBe(true);
    expect(env.CORS_ORIGINS).toEqual(['https://a.com', 'https://b.com']);
  });
});
