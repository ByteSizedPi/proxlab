/* Dev only: upload the live markup of the top bar and the tabs, so selectors
 * can be written against the real DOM instead of guessed.
 *
 * Runs only in dev mode (?uidev=1). About 1.5 s after each page view it
 * POSTs one text document to Jellyfin's own client-log endpoint
 * (/ClientLog/Document). The server stores it in its log folder as
 * upload_*.log, readable with:
 *   ls -t /mnt/docker-data/appdata/jellyfin/log/ | grep -i upload
 * SVG path data is stripped to keep it short. */
(function () {
  'use strict';
  try { if (localStorage.getItem('ui-dev') !== '1') return; } catch (e) { return; }

  var last = '';
  function strip(html) {
    return html.replace(/ d="[^"]*"/g, ' d="…"').replace(/ style="[^"]*"/g, ' style="…"');
  }

  function dump() {
    var api = window.ApiClient;
    if (!api || !api.accessToken || !api.accessToken()) return;
    var parts = ['URL: ' + location.href, ''];
    var bar = document.querySelector('.MuiAppBar-root, .skinHeader');
    parts.push('== top bar', bar ? strip(bar.outerHTML) : '(none)', '');
    document.querySelectorAll('[role="tablist"], .emby-tabs, .headerTabs').forEach(function (t, i) {
      parts.push('== tabs #' + i, strip(t.outerHTML), '');
    });
    document.querySelectorAll('.emby-tab-button-active, .emby-tab-button-active .emby-button-foreground').forEach(function (el, i) {
      var cs = getComputedStyle(el);
      parts.push('== computed active tab #' + i + ' <' + el.tagName.toLowerCase() + ' class="' + el.className + '">',
        'font-weight=' + cs.fontWeight + ' color=' + cs.color + ' font-family=' + cs.fontFamily, '');
    });
    var rows = [];
    document.querySelectorAll('.sectionTitle').forEach(function (t) {
      var sec = t.closest('.verticalSection');
      var link = t.closest('a') || (sec && sec.querySelector('a.sectionTitleTextButton'));
      rows.push('  ' + t.textContent.trim() + '  | section: ' + (sec ? sec.className : 'NONE') +
        ' | parent: ' + (sec && sec.parentElement ? sec.parentElement.className : '-') +
        ' | link: ' + (link ? link.className + ' ' + (link.getAttribute('href') || '').slice(0, 70) : 'NONE') +
        ' | order: ' + (sec ? getComputedStyle(sec).order : '-'));
    });
    if (rows.length) parts.push('== section titles in page order', rows.join('\n'), '');
    var series = document.querySelector('.verticalSection:has(a.sectionTitleTextButton[href*="/tv?"])');
    if (series) {
      var clone = series.cloneNode(true);
      var cards = clone.querySelectorAll('.card');
      for (var c = 2; c < cards.length; c++) cards[c].remove(); // two cards are enough
      parts.push('== template row (Recently Added in Series, 2 cards)', strip(clone.outerHTML), '');
    }
    var seen = new Set();
    document.querySelectorAll('a .material-icons, button .material-icons').forEach(function (ic) {
      var host = ic.closest('a, button');
      var row = host && host.parentElement;
      if (!row || seen.has(row) || row.closest('.skinHeader')) return;
      seen.add(row);
      if (seen.size <= 4) parts.push('== icon links row #' + seen.size, strip(row.outerHTML).slice(0, 3000), '');
    });
    var text = parts.join('\n');
    if (text === last) return;
    last = text;
    fetch(api.getUrl('ClientLog/Document'), {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain', 'Authorization': 'MediaBrowser Token="' + api.accessToken() + '"' },
      body: text
    }).then(function (r) { console.info('[ui] devdump uploaded', r.status); })
      .catch(function (e) { console.warn('[ui] devdump failed', e); });
  }

  var timer;
  function schedule() { clearTimeout(timer); timer = setTimeout(dump, 1500); }
  window.addEventListener('hashchange', schedule);
  window.addEventListener('popstate', schedule);
  document.addEventListener('viewshow', schedule);
  schedule();
})();
