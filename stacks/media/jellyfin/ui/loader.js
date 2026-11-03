/* Jellyfin UI loader. JavaScript Injector loads this one file on every page
 * (script src /web/ui/loader.js). Everything else comes from manifest.json.
 *
 * Production: files from /web/ui/, the ./ui folder of the Komodo stack clone.
 * Dev mode:   files from /web/ui-dev/, which dev.sh rsyncs from the laptop on
 *             every save. The manifest is polled once a second. A changed CSS
 *             file is swapped in place. A changed JS file, or a changed file
 *             list, reloads the page.
 *
 * Dev mode is per browser. Turn it on with ?uidev=1 in the URL, off with
 * ?uidev=0. It is stored in localStorage, so nobody else sees dev files.
 * See README.md in this folder.
 */
(function () {
  'use strict';
  if (window.__uiLoader) return; // the SPA can run the injector twice
  window.__uiLoader = true;

  var KEY = 'ui-dev';
  var flag = new URLSearchParams(location.search).get('uidev');
  try {
    if (flag === '1') localStorage.setItem(KEY, '1');
    if (flag === '0') localStorage.removeItem(KEY);
  } catch (e) { /* private window: production files */ }
  var dev = false;
  try { dev = localStorage.getItem(KEY) === '1'; } catch (e) { }
  var base = dev ? '/web/ui-dev/' : '/web/ui/';

  function fetchManifest() {
    return fetch(base + 'manifest.json?t=' + Date.now(), { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); });
  }

  var links = {}; // css file -> <link>

  function addCss(file, hash) {
    var el = document.createElement('link');
    el.rel = 'stylesheet';
    el.href = base + file + '?v=' + hash;
    el.dataset.ui = file;
    document.head.appendChild(el);
    links[file] = el;
  }

  function swapCss(file, hash) {
    // Load the new sheet first, then drop the old one: no flash of unstyled UI.
    var old = links[file];
    addCss(file, hash);
    links[file].onload = function () { if (old) old.remove(); };
  }

  function addJs(files, hashes, i) {
    if (i >= files.length) return;
    var el = document.createElement('script');
    el.src = base + files[i] + '?v=' + hashes[files[i]];
    el.dataset.ui = files[i];
    el.onload = el.onerror = function () { addJs(files, hashes, i + 1); };
    document.head.appendChild(el);
  }

  function keys(o) { return Object.keys(o || {}).sort().join('|'); }

  fetchManifest().then(function (m) {
    Object.keys(m.css || {}).forEach(function (f) { addCss(f, m.css[f]); });
    var js = Object.keys(m.js || {}).sort();
    addJs(js, m.js || {}, 0);
    if (!dev) return;

    console.info('[ui] dev mode: files from ' + base + ', ?uidev=0 to leave');
    var cur = m;
    setInterval(function () {
      fetchManifest().then(function (n) {
        if (keys(n.css) !== keys(cur.css) || keys(n.js) !== keys(cur.js)) return location.reload();
        for (var f in n.js) if (n.js[f] !== cur.js[f]) return location.reload();
        for (var c in n.css) if (n.css[c] !== cur.css[c]) { swapCss(c, n.css[c]); console.info('[ui] reloaded ' + c); }
        cur = n;
      }).catch(function () { /* server busy or restarting: try again */ });
    }, 1000);
  }).catch(function (e) { console.warn('[ui] no manifest at ' + base, e); });
})();
