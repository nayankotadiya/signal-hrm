// Browser implementation of [PlatformBridge]. Only compiled for the web.
// ignore_for_file: non_constant_identifier_names
import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'bridge.dart';

PlatformBridge create() => WebBridge();

@JS('google.accounts.id.initialize')
external void _gInitialize(_GConfig config);

@JS('google.accounts.id.renderButton')
external void _gRenderButton(web.HTMLElement parent, _GButtonOptions options);

extension type _GConfig._(JSObject _) implements JSObject {
  external factory _GConfig({String client_id, JSFunction callback, bool auto_select, String ux_mode});
}

extension type _GButtonOptions._(JSObject _) implements JSObject {
  external factory _GButtonOptions({String type, String theme, String size, String shape, String text, int width});
}

extension type _GCredentialResponse._(JSObject _) implements JSObject {
  external String? get credential;
}

@JS('AppleID.auth.init')
external void _appleInit(_AppleConfig config);

@JS('AppleID.auth.signIn')
external JSPromise<_AppleResponse> _appleSignIn();

extension type _AppleConfig._(JSObject _) implements JSObject {
  external factory _AppleConfig({String clientId, String scope, String redirectURI, bool usePopup});
}

extension type _AppleResponse._(JSObject _) implements JSObject {
  external _AppleAuthorization? get authorization;
}

extension type _AppleAuthorization._(JSObject _) implements JSObject {
  external String? get id_token;
}

@JS('SignalPush.subscribe')
external JSPromise<JSObject?> _signalPushSubscribe(JSString apiBaseUrl, JSString token);

@JS('SignalPush.isSubscribed')
external JSPromise<JSBoolean> _signalPushIsSubscribed();

@JS('SignalPush.unsubscribe')
external JSPromise<JSObject?> _signalPushUnsubscribe(JSString apiBaseUrl, JSString token);

class WebBridge implements PlatformBridge {
  WebBridge() {
    web.window.addEventListener('online', ((web.Event _) => _online.add(true)).toJS);
    web.window.addEventListener('offline', ((web.Event _) => _online.add(false)).toJS);
  }

  final StreamController<bool> _online = StreamController<bool>.broadcast();
  final Map<String, Future<bool>> _scripts = {};

  @override
  http.Client httpClient() => BrowserClient()..withCredentials = true;

  @override
  String deviceId() {
    const key = 'shrm_device_id';
    final existing = readLocal(key);
    if (existing != null && existing.length >= 16) return existing;
    final r = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final id = 'web-${List.generate(24, (_) => chars[r.nextInt(chars.length)]).join()}';
    writeLocal(key, id);
    return id;
  }

  @override
  String? readLocal(String key) {
    try {
      return web.window.localStorage.getItem(key);
    } catch (_) {
      return null; // storage blocked (private mode): fall back to memory-only behaviour
    }
  }

  @override
  void writeLocal(String key, String? value) {
    try {
      if (value == null) {
        web.window.localStorage.removeItem(key);
      } else {
        web.window.localStorage.setItem(key, value);
      }
    } catch (_) {}
  }

  @override
  Future<GeoReading> currentPosition({Duration timeout = const Duration(seconds: 6)}) {
    final c = Completer<GeoReading>();
    try {
      final geo = web.window.navigator.geolocation;
      geo.getCurrentPosition(
        ((web.GeolocationPosition p) {
          if (c.isCompleted) return;
          c.complete(GeoReading(latitude: p.coords.latitude.toDouble(), longitude: p.coords.longitude.toDouble(), accuracyMeters: p.coords.accuracy.toDouble()));
        }).toJS,
        ((web.GeolocationPositionError e) {
          if (c.isCompleted) return;
          c.completeError(GeoException(switch (e.code) {
            1 => GeoFailure.denied,
            3 => GeoFailure.timeout,
            _ => GeoFailure.unavailable,
          }));
        }).toJS,
        web.PositionOptions(enableHighAccuracy: true, timeout: timeout.inMilliseconds, maximumAge: 0),
      );
    } catch (_) {
      if (!c.isCompleted) c.completeError(const GeoException(GeoFailure.unavailable));
    }
    return c.future.timeout(timeout + const Duration(seconds: 1), onTimeout: () => throw const GeoException(GeoFailure.timeout));
  }

  @override
  Future<PickedFile?> pickFile({String accept = '*/*', String? capture}) {
    final c = Completer<PickedFile?>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = accept;
    if (capture != null) input.setAttribute('capture', capture);
    // Safari / iOS WebKit blocks .click() if display is 'none'
    input.style
      ..position = 'fixed'
      ..top = '-1000px'
      ..left = '-1000px'
      ..width = '1px'
      ..height = '1px'
      ..opacity = '0';
    web.document.body?.append(input);

    void finish(PickedFile? f) {
      if (!c.isCompleted) c.complete(f);
      input.remove();
    }

    input.addEventListener(
      'change',
      ((web.Event _) {
        final file = input.files?.item(0);
        if (file == null) {
          finish(null);
          return;
        }
        file.arrayBuffer().toDart.then((buf) {
          finish(PickedFile(name: file.name, bytes: buf.toDart.asUint8List(), mimeType: file.type.isEmpty ? 'application/octet-stream' : file.type));
        }, onError: (Object _) => finish(null));
      }).toJS,
    );
    input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
    input.click();

    // Generous safety timeout (5 minutes) so user has plenty of time to snap selfie
    Timer(const Duration(minutes: 5), () {
      if (!c.isCompleted) finish(null);
    });

    return c.future;
  }

  @override
  void downloadBytes(Uint8List bytes, String fileName, String mimeType) {
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
    final url = web.URL.createObjectURL(blob);
    final a = web.HTMLAnchorElement()
      ..href = url
      ..download = fileName;
    web.document.body?.append(a);
    a.click();
    a.remove();
    Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  }

  Future<bool> _loadScript(String src) => _scripts[src] ??= () {
        final c = Completer<bool>();
        final s = web.HTMLScriptElement()
          ..src = src
          ..async = true
          ..defer = true;
        s.addEventListener('load', ((web.Event _) => c.complete(true)).toJS);
        s.addEventListener('error', ((web.Event _) => c.complete(false)).toJS);
        web.document.head?.append(s);
        return c.future.timeout(const Duration(seconds: 12), onTimeout: () => false);
      }();

  @override
  Widget? googleButton({required String clientId, required void Function(String idToken) onToken, required void Function() onError}) {
    return SizedBox(
      height: 44,
      child: HtmlElementView.fromTagName(
        tagName: 'div',
        onElementCreated: (Object el) async {
          final div = el as web.HTMLElement;
          final ok = await _loadScript('https://accounts.google.com/gsi/client');
          if (!ok) {
            onError();
            return;
          }
          _gInitialize(_GConfig(
            client_id: clientId,
            auto_select: false,
            ux_mode: 'popup',
            callback: ((_GCredentialResponse r) {
              final token = r.credential;
              if (token == null) {
                onError();
              } else {
                onToken(token);
              }
            }).toJS,
          ));
          _gRenderButton(div, _GButtonOptions(type: 'standard', theme: 'outline', size: 'large', shape: 'pill', text: 'continue_with', width: 320));
        },
      ),
    );
  }

  @override
  Future<String?> appleSignIn(String clientId, String redirectUri) async {
    final ok = await _loadScript('https://appleid.cdn-apple.com/appleauth/static/jsapi/appleid/1/en_US/appleid.auth.js');
    if (!ok) return null;
    _appleInit(_AppleConfig(clientId: clientId, scope: 'name email', redirectURI: redirectUri, usePopup: true));
    try {
      final r = await _appleSignIn().toDart;
      return r.authorization?.id_token;
    } catch (_) {
      return null; // closed or cancelled
    }
  }

  @override
  bool get online => web.window.navigator.onLine;

  @override
  Stream<bool> get onlineChanges => _online.stream;

  @override
  Future<bool> subscribePushNotifications(String apiBaseUrl, String? token) async {
    try {
      final promise = _signalPushSubscribe(apiBaseUrl.toJS, (token ?? '').toJS);
      final res = await promise.toDart;
      return res != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isPushSubscribed() async {
    try {
      final promise = _signalPushIsSubscribed();
      final res = await promise.toDart;
      return res.toDart;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> unsubscribePushNotifications(String apiBaseUrl, String? token) async {
    try {
      final promise = _signalPushUnsubscribe(apiBaseUrl.toJS, (token ?? '').toJS);
      final res = await promise.toDart;
      return res != null;
    } catch (_) {
      return false;
    }
  }

  @override
  void openUrl(String url) {
    web.window.open(url, '_blank');
  }
}
