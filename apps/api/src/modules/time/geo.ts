/** Mean Earth radius (IUGG), metres. */
const R = 6_371_008.8;
const rad = (d: number): number => (d * Math.PI) / 180;

/** Great-circle distance in metres between two WGS84 points (Haversine formula). */
export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const dLat = rad(lat2 - lat1);
  const dLon = rad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(a)));
}

export type GeofenceVerdict =
  | { ok: true; verification: 'within_radius'; distanceMeters: number }
  | { ok: false; verification: 'accuracy_too_low'; accuracyMeters: number; requiredAccuracy: number }
  | { ok: false; verification: 'outside_radius'; distanceMeters: number; radiusMeters: number };

/**
 * Server-side geofence check. The reported accuracy must be within the organization limit first
 * (a fix accurate to ±800 m can't prove someone is inside a 150 m radius); then the distance from the
 * assigned location must be within its radius.
 */
export function checkGeofence(
  point: { latitude: number; longitude: number; accuracyMeters: number },
  location: { latitude: number; longitude: number; radiusMeters: number },
  maxAccuracyMeters: number,
): GeofenceVerdict {
  if (!Number.isFinite(point.accuracyMeters) || point.accuracyMeters > maxAccuracyMeters) {
    return { ok: false, verification: 'accuracy_too_low', accuracyMeters: Math.round(point.accuracyMeters), requiredAccuracy: maxAccuracyMeters };
  }
  const distanceMeters = Math.round(haversineMeters(point.latitude, point.longitude, location.latitude, location.longitude));
  if (distanceMeters > location.radiusMeters) return { ok: false, verification: 'outside_radius', distanceMeters, radiusMeters: location.radiusMeters };
  return { ok: true, verification: 'within_radius', distanceMeters };
}

/** km/h between two timed points; Infinity when time difference is zero and distance > 0. */
export function speedKmh(a: { latitude: number; longitude: number; at: Date }, b: { latitude: number; longitude: number; at: Date }): number {
  const meters = haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude);
  const hours = Math.abs(b.at.getTime() - a.at.getTime()) / 3_600_000;
  if (hours === 0) return meters > 0 ? Infinity : 0;
  return meters / 1000 / hours;
}
