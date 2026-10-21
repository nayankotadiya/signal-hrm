import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'bridge.dart';

PlatformBridge create() => StubBridge();

/// VM implementation for tests. No geolocation or file access.
class StubBridge implements PlatformBridge {
  final Map<String, String> _store = {};

  @override
  http.Client httpClient() => http.Client();

  @override
  String deviceId() => _store['device_id'] ??= 'test-device-0001';

  @override
  String? readLocal(String key) => _store[key];

  @override
  void writeLocal(String key, String? value) => value == null ? _store.remove(key) : _store[key] = value;

  @override
  Future<GeoReading> currentPosition({Duration timeout = const Duration(seconds: 20)}) async {
    return const GeoReading(latitude: 23.0225, longitude: 72.5714, accuracyMeters: 12.0);
  }

  @override
  Future<PickedFile?> pickFile({String accept = '*/*', String? capture}) async {
    try {
      final byteData = await rootBundle.load('assets/demo/selfie.jpg');
      final bytes = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      return PickedFile(name: 'selfie.jpg', bytes: bytes, mimeType: 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  @override
  void downloadBytes(Uint8List bytes, String fileName, String mimeType) {}

  @override
  Widget? googleButton({required String clientId, required void Function(String idToken) onToken, required void Function() onError}) => null;

  @override
  Future<String?> appleSignIn(String clientId, String redirectUri) async => null;

  @override
  bool get online => true;

  @override
  Stream<bool> get onlineChanges => const Stream.empty();

  @override
  Future<bool> subscribePushNotifications(String apiBaseUrl, String? token) async => false;

  @override
  Future<bool> isPushSubscribed() async => false;

  @override
  Future<bool> unsubscribePushNotifications(String apiBaseUrl, String? token) async => false;

  @override
  void openUrl(String url) {}

  @override
  void connectRealtime(String apiBaseUrl, String token, void Function(String event, String payloadJson) onEvent) {}

  @override
  void disconnectRealtime() {}
}
