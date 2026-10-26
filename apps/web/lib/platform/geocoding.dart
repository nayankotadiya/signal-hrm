import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service to resolve latitude/longitude coordinates into human-readable street addresses.
class Geocoding {
  static final Map<String, String> _cache = {};

  /// Reverse geocodes [lat] and [lng] into a human-readable address.
  /// Falls back to [fallbackAddress] or [fallbackLocationName] if network lookup fails or device is offline.
  static Future<String> reverseGeocode(
    double lat,
    double lng, {
    String? fallbackAddress,
    String? fallbackLocationName,
  }) async {
    final key = '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
    if (_cache.containsKey(key)) {
      return _cache[key]!;
    }

    // 1. Try BigDataCloud reverse geocode client API (free, open CORS, designed for client apps)
    try {
      final uri = Uri.parse(
        'https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=$lat&longitude=$lng&localityLanguage=en',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final parts = <String>[];
        final locality = data['locality'] as String?;
        final city = (data['city'] ?? data['principalSubdivision']) as String?;
        final country = data['countryName'] as String?;

        if (locality != null && locality.trim().isNotEmpty) {
          parts.add(locality.trim());
        }
        if (city != null && city.trim().isNotEmpty && !parts.contains(city.trim())) {
          parts.add(city.trim());
        }
        if (country != null && country.trim().isNotEmpty && !parts.contains(country.trim())) {
          parts.add(country.trim());
        }

        if (parts.isNotEmpty) {
          final resolved = parts.join(', ');
          _cache[key] = resolved;
          return resolved;
        }
      }
    } catch (_) {}

    // 2. Try OpenStreetMap Nominatim reverse geocoding
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lng',
      );
      final res = await http.get(uri, headers: {
        'User-Agent': 'SignalHRM/1.0',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final displayName = data['display_name'] as String?;
        if (displayName != null && displayName.trim().isNotEmpty) {
          final resolved = displayName.trim();
          _cache[key] = resolved;
          return resolved;
        }
      }
    } catch (_) {}

    // 3. Fallbacks
    if (fallbackAddress != null && fallbackAddress.trim().isNotEmpty) {
      _cache[key] = fallbackAddress.trim();
      return fallbackAddress.trim();
    }
    if (fallbackLocationName != null && fallbackLocationName.trim().isNotEmpty) {
      _cache[key] = fallbackLocationName.trim();
      return fallbackLocationName.trim();
    }

    final latDir = lat >= 0 ? 'N' : 'S';
    final lngDir = lng >= 0 ? 'E' : 'W';
    final coordStr = '${lat.abs().toStringAsFixed(4)}° $latDir, ${lng.abs().toStringAsFixed(4)}° $lngDir';
    _cache[key] = coordStr;
    return coordStr;
  }
}
