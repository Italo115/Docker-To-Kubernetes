// Shared entrance + cursor-parallax behaviour for every error page.
(function () {
  var page = document.getElementById('errPage');
  if (page) {
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { page.classList.add('is-in'); });
    });
  }

  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  var group = document.getElementById('contourGroup');
  if (!group) return;

  // Subtle cursor parallax on the contour waves. Translates an inner <g> so it
  // composes with the SVG's contourDrift keyframe instead of fighting it.
  var MAX_X = 14, MAX_Y = 9;   // max shift in viewBox units — kept small on purpose
  var targetX = 0, targetY = 0, curX = 0, curY = 0;

  window.addEventListener('pointermove', function (e) {
    targetX = ((e.clientX / window.innerWidth) - 0.5) * 2 * MAX_X;
    targetY = ((e.clientY / window.innerHeight) - 0.5) * 2 * MAX_Y;
  }, { passive: true });

  (function tick() {
    curX += (targetX - curX) * 0.07;   // ease toward target for a smooth feel
    curY += (targetY - curY) * 0.07;
    group.setAttribute('transform', 'translate(' + curX.toFixed(2) + ' ' + curY.toFixed(2) + ')');
    requestAnimationFrame(tick);
  })();
})();
