/* Per-user defaults that Jellyfin 12 keeps only in browser storage.
 *
 * Audiobooks opens on "Books", not "Folders" (2026-11-03). The React library
 * page reads its starting view with userSettings.get('landing-<library>', false),
 * and `false` means browser storage only (key "<userId>-landing-<library>").
 * The Settings > Home page saves the choice to the server as well, but the
 * library page never reads it from there. So a choice made on one device did
 * not apply on another, and the setting "did not stick". This writes it into
 * browser storage on every client that runs the loader. */
(function () {
  'use strict';
  var DEFAULTS = {
    'landing-c0c1444b416777d3fa55d5f13da1ce58': 'books' // Audiobooks library
  };

  function apply() {
    var api = window.ApiClient;
    var uid = api && api.getCurrentUserId && api.getCurrentUserId();
    if (!uid) return false;
    // Once per user and device: a choice made later in the library page stays.
    // Bump MARK to apply changed DEFAULTS again.
    var MARK = uid + '-ui-defaults-v1';
    try {
      if (localStorage.getItem(MARK)) return true;
      Object.keys(DEFAULTS).forEach(function (k) { localStorage.setItem(uid + '-' + k, DEFAULTS[k]); });
      localStorage.setItem(MARK, '1');
    } catch (e) { /* storage blocked: Jellyfin's own default applies */ }
    return true;
  }

  // ApiClient knows the user only after login: retry until it does.
  if (!apply()) {
    var tries = 0;
    var t = setInterval(function () { if (apply() || ++tries > 60) clearInterval(t); }, 1000);
  }
})();
