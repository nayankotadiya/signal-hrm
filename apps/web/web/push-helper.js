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
    }
  };

  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () {
      window.SignalPush.registerServiceWorker();
    });
  }
})();
