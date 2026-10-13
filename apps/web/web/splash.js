// Fades the HTML splash out on Flutter's first frame (the app's own splash continues the animation).
window.addEventListener('flutter-first-frame', function () {
  var s = document.getElementById('splash');
  if (!s) return;
  s.classList.add('leaving');
  setTimeout(function () { s.remove(); }, 380);
});
