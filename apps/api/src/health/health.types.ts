/**
 * Four-state health vocabulary shared with the N UI status chips.
 * "healthy" may only come from a check that actually ran and passed.
 */
export type HealthState = 'healthy' | 'degraded' | 'unavailable' | 'unknown';

export type HealthComponentName = 'api' | 'database' | 'redis' | 'storage' | 'backups' | 'jobs' | 'notifications';

/** Machine-readable reason. Safe to show to any user: never contains hosts, URIs or driver messages. */
export type HealthReason =
  | 'ok'
  | 'not_configured'
  | 'not_implemented'
  | 'connecting'
  | 'disconnected'
  | 'timeout'
  | 'check_failed'
  | 'slow_response'
  | 'event_loop_lag'
  | 'no_runs'
  | 'job_failures'
  | 'no_verified_backup'
  | 'backup_stale'
  | 'last_backup_failed'
  | 'delivery_failures'
  | 'deliveries_stuck'
  | 'storage_almost_full';

export interface ComponentHealth {
  component: HealthComponentName;
  state: HealthState;
  reason: HealthReason;
  /** Round-trip time of the check in ms, when a check ran. */
  latencyMs?: number;
  checkedAt: string;
  /** Critical components decide whether the API can serve traffic. */
  critical: boolean;
}

export interface HealthSummary {
  state: HealthState;
  checkedAt: string;
  version: string;
  environment: string;
  components: ComponentHealth[];
}

export interface HealthCheck {
  readonly component: HealthComponentName;
  readonly critical: boolean;
  check(): Promise<Omit<ComponentHealth, 'component' | 'critical' | 'checkedAt'>>;
}

/**
 * Overall state rules:
 * - any critical component unavailable            -> unavailable
 * - else any component degraded or unavailable    -> degraded
 * - else any critical component unknown           -> unknown
 * - else                                          -> healthy
 * Non-critical "unknown" (e.g. backups before Phase 9) does not block healthy, but is still shown per component.
 */
export function aggregateHealth(components: Pick<ComponentHealth, 'state' | 'critical'>[]): HealthState {
  if (components.length === 0) return 'unknown';
  if (components.some((c) => c.critical && c.state === 'unavailable')) return 'unavailable';
  if (components.some((c) => c.state === 'degraded' || c.state === 'unavailable')) return 'degraded';
  if (components.some((c) => c.critical && c.state === 'unknown')) return 'unknown';
  return 'healthy';
}

/** Runs a promise with a timeout; rejects with Error('timeout'). */
export async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('timeout')), ms);
      }),
    ]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
