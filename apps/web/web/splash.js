// Fades the HTML splash out on Flutter's first frame (the app's own splash continues the animation).
window.addEventListener('flutter-first-frame', function () {
  var s = document.getElementById('splash');
  if (!s) return;
  s.classList.add('leaving');
  setTimeout(function () { s.remove(); }, 380);
});

// Immediately check for updates so mobile Safari / Chrome never gets stuck on an outdated build.
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.getRegistrations().then(function (regs) {
    for (var i = 0; i < regs.length; i++) {
      regs[i].update();
    }
  });
}

