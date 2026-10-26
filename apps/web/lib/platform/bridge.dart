import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'bridge_stub.dart' if (dart.library.js_interop) 'bridge_web.dart' as impl;

/// A position reading from the device. The server decides whether it is acceptable.
class GeoReading {
  const GeoReading({required this.latitude, required this.longitude, required this.accuracyMeters, this.mockSuspected});
  final double latitude;
  final double longitude;
  final double accuracyMeters;

  /// Browsers do not expose mock-location flags; this stays null on the web.
  final bool? mockSuspected;
}

enum GeoFailure { denied, unavailable, timeout, unsupported }

class GeoException implements Exception {
  const GeoException(this.failure);
  final GeoFailure failure;
}

class PickedFile {
  const PickedFile({required this.name, required this.bytes, required this.mimeType});
  final String name;
  final Uint8List bytes;
  final String mimeType;
}

/// Everything the app needs from the browser, behind one interface so widget tests can run on the VM.
abstract class PlatformBridge {
  /// HTTP client that sends cookies (the refresh cookie is httpOnly and never readable by Dart).
  http.Client httpClient();

  /// Stable per-browser id used for device-based suspicious-pattern checks. Not a secret.
  String deviceId();

  String? readLocal(String key);
  void writeLocal(String key, String? value);

  Future<GeoReading> currentPosition({Duration timeout = const Duration(seconds: 20)});

  /// Opens the file chooser. [capture] = 'user' asks for the front camera on phones.
  Future<PickedFile?> pickFile({String accept = '*/*', String? capture});

  void downloadBytes(Uint8List bytes, String fileName, String mimeType);

  /// Google Identity Services: the official button rendered in a platform view. The ID token is
  /// delivered through [onToken]. Null when unsupported (tests).
  Widget? googleButton({required String clientId, required void Function(String idToken) onToken, required void Function() onError});
  Future<String?> appleSignIn(String clientId, String redirectUri);

  bool get online;
  Stream<bool> get onlineChanges;

  /// Subscribes the current device/browser to Web Push notifications for 24/7 background alerts.
  Future<bool> subscribePushNotifications(String apiBaseUrl, String? token);

  /// Checks if Web Push is currently active on this device.
  Future<bool> isPushSubscribed();

  /// Unsubscribes the current device/browser from Web Push notifications.
  Future<bool> unsubscribePushNotifications(String apiBaseUrl, String? token);

  /// Opens an external URL in a new tab or browser window.
  void openUrl(String url);

  /// Connects to the backend WebSocket/Socket.IO gateway for real-time notifications and updates.
  void connectRealtime(String apiBaseUrl, String token, void Function(String event, String payloadJson) onEvent);

  /// Disconnects the real-time WebSocket connection.
  void disconnectRealtime();

  /// Checks the current state of GPS, Notifications, and Camera permissions.
  Future<PermissionStatusReport> checkPermissions();

  /// Prompts the user to grant high-accuracy GPS location permission.
  Future<Map<String, dynamic>> requestLocationPermission();

  /// Prompts the user to grant Web Push notification permissions.
  Future<String> requestNotificationPermission();

  /// Tests or prompts for camera / selfie capture access.
  Future<Map<String, dynamic>> requestCameraPermission();

  /// Detects the user's OS, browser, mobile status, and PWA mode.
  Map<String, dynamic> detectDevice();
}

enum AppPermissionState {
  granted,
  prompt,
  denied,
  unsupported;

  static AppPermissionState fromString(String? val) {
    return switch (val) {
      'granted' => AppPermissionState.granted,
      'denied' => AppPermissionState.denied,
      'unsupported' => AppPermissionState.unsupported,
      _ => AppPermissionState.prompt,
    };
  }
}

class PermissionStatusReport {
  const PermissionStatusReport({
    required this.location,
    required this.notifications,
    required this.camera,
    required this.os,
    required this.browser,
    required this.isMobile,
    required this.isPwa,
  });

  final AppPermissionState location;
  final AppPermissionState notifications;
  final AppPermissionState camera;
  final String os;
  final String browser;
  final bool isMobile;
  final bool isPwa;
}

final PlatformBridge bridge = impl.create();
