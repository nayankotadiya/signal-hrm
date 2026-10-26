(function () {
  function urlB64ToUint8Array(base64String) {
    var padding = '='.repeat((4 - (base64String.length % 4)) % 4);
    var base64 = (base64String + padding).replace(/\-/g, '+').replace(/_/g, '/');
    var rawData = window.atob(base64);
    var outputArray = new Uint8Array(rawData.length);
    for (var i = 0; i < rawData.length; ++i) {
      outputArray[i] = rawData.charCodeAt(i);
    }
    return outputArray;
  }

  window.SignalPush = {
    isSupported: function () {
      return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
    },
    getPermission: function () {
      return 'Notification' in window ? Notification.permission : 'unsupported';
    },
    registerServiceWorker: async function () {
      if (!('serviceWorker' in navigator)) return null;
      try {
        return await navigator.serviceWorker.register('sw.js', { scope: './' });
      } catch (err) {
        console.warn('[SignalPush] SW registration failed:', err);
        return null;
      }
    },
    subscribe: async function (apiBaseUrl, token) {
      if (!this.isSupported()) return { ok: false, reason: 'unsupported' };
      var perm = await Notification.requestPermission();
      if (perm !== 'granted') return { ok: false, reason: 'permission_denied' };

      var reg = await this.registerServiceWorker();
      if (!reg) return { ok: false, reason: 'no_sw' };
      await navigator.serviceWorker.ready;

      try {
        var keyRes = await fetch(apiBaseUrl + '/v1/notifications/push/key', {
          headers: token ? { Authorization: 'Bearer ' + token } : {}
        });
        if (!keyRes.ok) return { ok: false, reason: 'key_fetch_failed' };
        var keyData = await keyRes.json();

        var sub = await reg.pushManager.getSubscription();
        if (!sub) {
          sub = await reg.pushManager.subscribe({
            userVisibleOnly: true,
            applicationServerKey: urlB64ToUint8Array(keyData.publicKey)
          });
        }

        var rawP256dh = sub.getKey('p256dh');
        var rawAuth = sub.getKey('auth');
        var p256dh = btoa(String.fromCharCode.apply(null, new Uint8Array(rawP256dh)));
        var auth = btoa(String.fromCharCode.apply(null, new Uint8Array(rawAuth)));

        var saveRes = await fetch(apiBaseUrl + '/v1/notifications/push/subscribe', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(token ? { Authorization: 'Bearer ' + token } : {})
          },
          body: JSON.stringify({
            endpoint: sub.endpoint,
            keys: { p256dh: p256dh, auth: auth },
            userAgent: navigator.userAgent
          })
        });

        return { ok: saveRes.ok };
      } catch (e) {
        console.warn('[SignalPush] Subscribe error:', e);
        return { ok: false, reason: e.message };
      }
    },
    isSubscribed: async function () {
      if (!this.isSupported()) return false;
      if (Notification.permission !== 'granted') return false;
      try {
        var reg = await navigator.serviceWorker.ready;
        if (!reg) return false;
        var sub = await reg.pushManager.getSubscription();
        return !!sub;
      } catch (e) {
        return false;
      }
    },
    unsubscribe: async function (apiBaseUrl, token) {
      if (!this.isSupported()) return { ok: false };
      try {
        var reg = await navigator.serviceWorker.ready;
        if (!reg) return { ok: false };
        var sub = await reg.pushManager.getSubscription();
        if (sub) {
          var endpoint = sub.endpoint;
          await sub.unsubscribe();
          if (apiBaseUrl && token) {
            try {
              await fetch(apiBaseUrl + '/v1/notifications/push/unsubscribe', {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer ' + token
                },
                body: JSON.stringify({ endpoint: endpoint })
              });
            } catch (_) {}
          }
        }
        return { ok: true };
      } catch (e) {
        console.warn('[SignalPush] Unsubscribe error:', e);
        return { ok: false, reason: e.message };
      }
    }
  };

  window.SignalRealtime = {
    socket: null,
    connect: function (apiBaseUrl, token, onEvent) {
      if (this.socket) {
        try { this.socket.close(); } catch (_) {}
        this.socket = null;
      }
      if (!token) return;
      try {
        var base = apiBaseUrl.replace(/\/v1\/?$/, '').replace(/\/api\/?$/, '');
        var wsUrl = base.replace(/^http/, 'ws') + '/ws/?EIO=4&transport=websocket';
        var ws = new WebSocket(wsUrl);
        this.socket = ws;
        ws.onopen = function () {
          ws.send('40{"token":"' + token + '"}');
        };
        ws.onmessage = function (e) {
          var msg = e.data;
          if (msg === '2') {
            ws.send('3'); // pong
            return;
          }
          if (typeof msg === 'string' && msg.indexOf('42') === 0) {
            try {
              var arr = JSON.parse(msg.slice(2));
              var eventName = arr[0];
              var payload = JSON.stringify(arr[1] || {});
              if (onEvent) onEvent(eventName, payload);
            } catch (_) {}
          }
        };
      } catch (err) {
        console.warn('[SignalRealtime] Connect error:', err);
      }
    },
    disconnect: function () {
      if (this.socket) {
        try { this.socket.close(); } catch (_) {}
        this.socket = null;
      }
    }
  };

  window.SignalPermissions = {
    detectDevice: function () {
      var ua = navigator.userAgent || '';
      var os = 'Unknown';
      var browser = 'Browser';
      var isMobile = false;

      if (/iPhone|iPad|iPod/i.test(ua)) {
        os = 'iOS';
        isMobile = true;
      } else if (/Android/i.test(ua)) {
        os = 'Android';
        isMobile = true;
      } else if (/Macintosh|Mac OS X/i.test(ua)) {
        os = 'macOS';
      } else if (/Windows/i.test(ua)) {
        os = 'Windows';
      } else if (/Linux/i.test(ua)) {
        os = 'Linux';
      }

      if (/Edg\//i.test(ua)) {
        browser = 'Edge';
      } else if (/Chrome\//i.test(ua) && !/Edg\//i.test(ua)) {
        browser = 'Chrome';
      } else if (/Safari\//i.test(ua) && !/Chrome\//i.test(ua)) {
        browser = 'Safari';
      } else if (/Firefox\//i.test(ua)) {
        browser = 'Firefox';
      }

      return JSON.stringify({
        os: os,
        browser: browser,
        isMobile: isMobile,
        isPwa: window.matchMedia && window.matchMedia('(display-mode: standalone)').matches,
        userAgent: ua
      });
    },

    checkStatus: async function () {
      var loc = 'prompt';
      if (!('geolocation' in navigator)) {
        loc = 'unsupported';
      } else if (navigator.permissions && navigator.permissions.query) {
        try {
          var res = await navigator.permissions.query({ name: 'geolocation' });
          loc = res.state; // 'granted', 'prompt', 'denied'
        } catch (_) {
          loc = 'prompt';
        }
      }

      var notif = 'prompt';
      if (!('Notification' in window)) {
        notif = 'unsupported';
      } else if (Notification.permission === 'granted') {
        notif = 'granted';
      } else if (Notification.permission === 'denied') {
        notif = 'denied';
      } else {
        notif = 'prompt';
      }

      var cam = 'prompt';
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        cam = 'unsupported';
      } else if (navigator.permissions && navigator.permissions.query) {
        try {
          var camRes = await navigator.permissions.query({ name: 'camera' });
          cam = camRes.state;
        } catch (_) {
          cam = 'prompt';
        }
      }

      return JSON.stringify({
        location: loc,
        notifications: notif,
        camera: cam
      });
    },

    requestLocation: function () {
      return new Promise(function (resolve) {
        if (!('geolocation' in navigator)) {
          resolve(JSON.stringify({ ok: false, reason: 'unsupported' }));
          return;
        }
        navigator.geolocation.getCurrentPosition(
          function (pos) {
            resolve(JSON.stringify({
              ok: true,
              lat: pos.coords.latitude,
              lng: pos.coords.longitude,
              accuracy: pos.coords.accuracy
            }));
          },
          function (err) {
            resolve(JSON.stringify({
              ok: false,
              code: err.code, // 1: denied, 2: unavailable, 3: timeout
              message: err.message
            }));
          },
          { enableHighAccuracy: true, timeout: 10000, maximumAge: 0 }
        );
      });
    },

    requestNotifications: async function () {
      if (!('Notification' in window)) {
        return 'unsupported';
      }
      try {
        var res = await Notification.requestPermission();
        return res; // 'granted', 'denied', 'default'
      } catch (e) {
        return 'denied';
      }
    },

    requestCamera: function () {
      return new Promise(function (resolve) {
        if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
          resolve(JSON.stringify({ ok: false, reason: 'unsupported' }));
          return;
        }
        navigator.mediaDevices.getUserMedia({ video: { facingMode: 'user' } })
          .then(function (stream) {
            stream.getTracks().forEach(function (t) { t.stop(); });
            resolve(JSON.stringify({ ok: true }));
          })
          .catch(function (err) {
            resolve(JSON.stringify({ ok: false, name: err.name, message: err.message }));
          });
      });
    }
  };

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      window.SignalPush.registerServiceWorker();
    });
  }
})();
