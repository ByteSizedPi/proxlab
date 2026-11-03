/* "Leaving Soon" row on the home page, right after "Next Up" (2026-11-03).
 *
 * Lists the items of every collection whose name starts with "Leaving soon"
 * (Maintainerr's collections, e.g. "Leaving soon - Shows"). Collections are
 * found by name on each visit, so the row survives Maintainerr recreating a
 * collection with a new id, and picks up a movies collection automatically.
 * No items: no row.
 *
 * Cards use the classes of Jellyfin's own portrait cards (markup read from
 * the live page with js/90-devdump.js), so css/40-cards.css styles them the
 * same. The scroller is a plain flex row: Jellyfin's is="emby-scroller"
 * elements may not upgrade when inserted after the page has rendered. */
(function () {
  'use strict';
  var ROW_ID = 'ui-leaving-soon';
  var NAME_PREFIX = 'leaving soon';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function cardHtml(api, item) {
    var href = '#/details?id=' + item.Id + '&serverId=' + item.ServerId;
    var img = item.ImageTags && item.ImageTags.Primary
      ? api.getScaledImageUrl(item.Id, { type: 'Primary', maxHeight: 480, tag: item.ImageTags.Primary })
      : '';
    var sub = item.ProductionYear ? String(item.ProductionYear) : '';
    if (item.Type === 'Series' && item.ProductionYear) sub += item.EndDate ? ' - ' + new Date(item.EndDate).getFullYear() : ' - Present';
    return '<div class="card overflowPortraitCard card-hoverable" data-id="' + esc(item.Id) + '" data-type="' + esc(item.Type) + '">' +
      '<div class="cardBox cardBox-bottompadded"><div class="cardScalable">' +
      '<div class="cardPadder cardPadder-overflowPortrait"></div>' +
      '<a href="' + href + '" class="cardImageContainer coveredImage cardContent itemAction" aria-label="' + esc(item.Name) + '" role="img"' +
      (img ? ' style="background-image:url(\'' + img + '\')"' : '') + '></a>' +
      '</div>' +
      '<div class="cardText cardTextCentered cardText-first"><bdi><a href="' + href + '" class="textActionButton" title="' + esc(item.Name) + '">' + esc(item.Name) + '</a></bdi></div>' +
      '<div class="cardText cardTextCentered cardText-secondary"><bdi>' + esc(sub) + '</bdi></div>' +
      '</div></div>';
  }

  function findNextUp() {
    var t = document.querySelector('.homePage:not(.hide) a.sectionTitleTextButton[href*="type=nextup"], #indexPage:not(.hide) a.sectionTitleTextButton[href*="type=nextup"]') ||
            document.querySelector('a.sectionTitleTextButton[href*="type=nextup"]');
    return t && t.closest('.verticalSection');
  }

  var busy = false;
  function render() {
    if (busy || !/^#\/home/.test(location.hash || '#/home')) return;
    var api = window.ApiClient;
    var uid = api && api.getCurrentUserId && api.getCurrentUserId();
    var nextUp = findNextUp();
    if (!uid || !nextUp) return false;
    busy = true;
    api.getItems(uid, { IncludeItemTypes: 'BoxSet', Recursive: true, Fields: 'ChildCount' }).then(function (res) {
      var cols = (res.Items || []).filter(function (c) { return c.Name.toLowerCase().indexOf(NAME_PREFIX) === 0; });
      return Promise.all(cols.map(function (c) {
        return api.getItems(uid, { ParentId: c.Id, Fields: 'PrimaryImageAspectRatio,ProductionYear,EndDate', SortBy: 'SortName', ImageTypeLimit: 1, EnableImageTypes: 'Primary' })
          .then(function (r) { return { col: c, items: r.Items || [] }; });
      }));
    }).then(function (groups) {
      var old = document.getElementById(ROW_ID);
      var items = [];
      (groups || []).forEach(function (g) { items = items.concat(g.items); });
      if (!items.length) { if (old) old.remove(); return; }
      var link = '#/details?id=' + groups.filter(function (g) { return g.items.length; })[0].col.Id + '&serverId=' + items[0].ServerId;
      var row = document.createElement('div');
      row.id = ROW_ID;
      row.className = 'verticalSection ui-row';
      row.innerHTML =
        '<div class="sectionTitleContainer sectionTitleContainer-cards padded-left">' +
        '<a href="' + link + '" class="more button-flat button-flat-mini sectionTitleTextButton emby-button">' +
        '<h2 class="sectionTitle sectionTitle-cards">Leaving Soon</h2>' +
        '<span class="material-icons chevron_right" aria-hidden="true"></span></a></div>' +
        '<div class="ui-row-scroller padded-left padded-right">' + items.map(function (i) { return cardHtml(api, i); }).join('') + '</div>';
      if (old) old.replaceWith(row); else nextUp.after(row);
    }).catch(function (e) { console.warn('[ui] leaving soon:', e); })
      .then(function () { busy = false; });
    return true;
  }

  // The home sections render after the view shows: wait for "Next Up".
  function schedule() {
    var tries = 0;
    var t = setInterval(function () {
      if (render() !== false || ++tries > 40) clearInterval(t);
    }, 250);
  }
  window.addEventListener('hashchange', schedule);
  document.addEventListener('viewshow', schedule);
  schedule();
})();
