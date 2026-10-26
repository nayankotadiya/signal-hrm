import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/api.dart';
import 'bridge.dart';

/// Represents an attendance punch recorded while the device had no network connection.
class OfflinePunch {
  const OfflinePunch({
    required this.id,
    required this.action,
    required this.clientRecordedAt,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.address,
    this.selfieFileId,
  });

  final String id;
  final String action; // 'checkIn' | 'checkOut'
  final DateTime clientRecordedAt;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final String? address;
  final String? selfieFileId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'action': action,
        'clientRecordedAt': clientRecordedAt.toUtc().toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'accuracyMeters': accuracyMeters,
        'address': address,
        'selfieFileId': selfieFileId,
      };

  factory OfflinePunch.fromJson(Map<String, dynamic> j) => OfflinePunch(
        id: j['id'] as String? ?? 'offline_${DateTime.now().millisecondsSinceEpoch}',
        action: j['action'] as String? ?? 'checkIn',
        clientRecordedAt: DateTime.tryParse(j['clientRecordedAt'] as String? ?? '') ?? DateTime.now(),
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        accuracyMeters: (j['accuracyMeters'] as num?)?.toDouble(),
        address: j['address'] as String?,
        selfieFileId: j['selfieFileId'] as String?,
      );
}

/// Offline punch queue manager with automatic background synchronization.
class OfflineSyncService {
  OfflineSyncService._() {
    _load();
    _onlineSub = bridge.onlineChanges.listen((online) {
      if (online && _queue.isNotEmpty && _activeApi != null) {
        unawaited(syncAll(_activeApi!));
      }
    });
  }

  static final OfflineSyncService instance = OfflineSyncService._();

  static const String _storageKey = 'shrm_offline_punches';
  final List<OfflinePunch> _queue = [];
  StreamSubscription<bool>? _onlineSub;
  ApiClient? _activeApi;

  final ValueNotifier<int> queueCountNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool> isSyncingNotifier = ValueNotifier<bool>(false);

  void bindApi(ApiClient api) {
    _activeApi = api;
  }

  List<OfflinePunch> get queue => List.unmodifiable(_queue);
  int get count => _queue.length;

  void _load() {
    try {
      final raw = bridge.readLocal(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _queue.clear();
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              _queue.add(OfflinePunch.fromJson(item));
            }
          }
        }
      }
    } catch (_) {}
    queueCountNotifier.value = _queue.length;
  }

  void _save() {
    try {
      final raw = jsonEncode(_queue.map((p) => p.toJson()).toList());
      bridge.writeLocal(_storageKey, raw);
    } catch (_) {}
    queueCountNotifier.value = _queue.length;
  }

  /// Enqueues a punch when offline or when a network request fails.
  Future<void> enqueue({
    required String action,
    double? latitude,
    double? longitude,
    double? accuracyMeters,
    String? address,
    String? selfieFileId,
  }) async {
    final r = Random.secure();
    final punch = OfflinePunch(
      id: 'offline_${DateTime.now().millisecondsSinceEpoch}_${r.nextInt(999999)}',
      action: action,
      clientRecordedAt: DateTime.now().toUtc(),
      latitude: latitude,
      longitude: longitude,
      accuracyMeters: accuracyMeters,
      address: address,
      selfieFileId: selfieFileId,
    );
    _queue.add(punch);
    _save();
  }

  /// Synchronizes all queued punches to the server.
  Future<int> syncAll(ApiClient api) async {
    if (_queue.isEmpty || isSyncingNotifier.value) return 0;
    isSyncingNotifier.value = true;
    int syncedCount = 0;

    final toSync = List<OfflinePunch>.from(_queue);
    for (final punch in toSync) {
      final endpoint = punch.action == 'checkIn' ? '/attendance/check-in' : '/attendance/check-out';
      final payload = {
        'queuedOffline': true,
        'clientRecordedAt': punch.clientRecordedAt.toUtc().toIso8601String(),
        if (punch.latitude != null) 'latitude': punch.latitude,
        if (punch.longitude != null) 'longitude': punch.longitude,
        if (punch.accuracyMeters != null) 'accuracyMeters': punch.accuracyMeters,
        if (punch.address != null) 'address': punch.address,
        if (punch.selfieFileId != null) 'selfieFileId': punch.selfieFileId,
      };

      try {
        await api.post(endpoint, body: payload, idempotencyKey: punch.id);
        _queue.removeWhere((p) => p.id == punch.id);
        syncedCount++;
      } catch (e) {
        // If conflict (already recorded) we can safely remove from queue
        final errStr = e.toString().toLowerCase();
        if (errStr.contains('already_checked_in') || errStr.contains('already_checked_out')) {
          _queue.removeWhere((p) => p.id == punch.id);
          syncedCount++;
        }
      }
    }

    _save();
    isSyncingNotifier.value = false;
    return syncedCount;
  }

  void clear() {
    _queue.clear();
    _save();
  }

  void dispose() {
    _onlineSub?.cancel();
  }
}
