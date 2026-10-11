# Jellyfin Rating Distribution plugin

A Jellyfin 12.1 plugin. It shows the Trakt audience-rating histogram, headline
stats and a shape classifier on the item detail page. `HANDOFF.md` holds the
design brief. `prototype/Main.dc.html` is the visual reference.

## Status (2026-10-11)

- The plugin builds against Jellyfin.Controller 12.1.0 / net10.0 (`./build.sh`).
- Not deployed yet. Not yet tested against a live server or the Trakt API.

## How it works

| Part | File | Job |
|---|---|---|
| Script injection | `Services/ScriptInjectionStartupFilter.cs` | ASP.NET middleware. Adds `<script src="../RatingDistribution/script">` to `index.html` when the server sends it. Nothing on disk changes. |
| Data endpoint | `Api/RatingDistributionController.cs` | `GET /RatingDistribution/Items/{itemId}` (needs auth) returns the 10 counts. `GET /RatingDistribution/script` serves the client JS. |
| Trakt | `Services/TraktClient.cs`, `Services/DistributionService.cs` | Maps Movie / Series / Season / Episode to the Trakt ratings path. Uses the IMDb ID directly. Falls back to a TMDB or TVDB search. |
| Cache | `Services/RatingCache.cs` | `trakt-cache.json` in the plugin data folder. 7 days for titles from the last 180 days, 30 days for older titles. Both values are configurable. |
| Client | `Web/rating-distribution.js` | Detects the detail page and draws the panel. `stats()` and `classify()` are ported unchanged from the prototype. |
| Settings | `Configuration/configPage.html` | Trakt client ID (or the `TRAKT_CLIENT_ID` env var), minimum votes, cache days. |

The data fetch is lazy: the first view of a title fetches from Trakt. There is
no scheduled pre-fetch yet (handoff question 5).

## Research findings (verified on pve-prod, 2026-10-11)

- Jellyfin 12.1.0, image `lscr.io/linuxserver/jellyfin:latest`, .NET 10.0.12.
  Plugins are in `/config/data/plugins` (host: `/mnt/docker-data/appdata/jellyfin/data/plugins`).
- **Jellyfin 12 has no official way to add UI to the detail page.**
- **Jellyfin Enhanced 12.11 does not use File Transformation on 12.x.** It
  registers its own `IStartupFilter` middleware that rewrites `index.html` as
  the server sends it (`ScriptInjectionStartupFilter.cs` in n00bcodr/Jellyfin-Enhanced).
  This plugin copies that pattern, so it does not depend on File Transformation.
- File Transformation 3.0.1 is installed and is an alternative. A plugin
  registers a payload by reflection (`PluginInterface.RegisterTransformation(JObject)`),
  with a callback by assembly method, named pipe or HTTP endpoint.
  It was not chosen: the `JObject` parameter couples us to the Newtonsoft
  version that File Transformation loads.
- Enhanced detects the detail page with `#itemDetailPage:not(.hide)`, the
  `viewshow` event and a hook on `Emby.Page.onViewShow`. It inserts panels after
  `.streaming-lookup-container`, `.itemExternalLinks` or `.tagline`. This
  plugin uses the same anchors and puts the chart before Enhanced's
  `.tmdb-reviews-section` when that section exists.
- **Theme variables:** the 7 bundled themes each define only 4 CSS
  variables on disk (`--jf-palette-background-defaultImage`,
  `--jf-palette-AppBar-*`, `--jf-card-borderRadius`). The panel therefore
  derives its text, border and grid colours from `currentColor` with
  `color-mix()`, and needs no theme variable names. The only host variable it
  reads is `--jf-palette-primary-main` (fallback `#00a4dc`), and that one is
  unverified.

## Known limits

- Only the web client (and clients that wrap it) shows the panel. Native
  Android TV, Swiftfin, Findroid and Kodi do not.
- The DOM anchors can change between jellyfin-web versions.
- The classifier thresholds are still the synthetic-data values (handoff question 4).

## Deploy (not done yet)

1. Run `./build.sh`.
2. Copy `dist/Jellyfin.Plugin.RatingDistribution.dll` and `dist/meta.json` to
   `/mnt/docker-data/appdata/jellyfin/data/plugins/Rating Distribution_0.1.0.0/` on pve-prod.
3. Make the folder owner `abc` inside the container (uid 1000 on linuxserver images).
4. Restart the `jellyfin` container.
5. In Dashboard → Plugins → Rating Distribution, enter the Trakt client ID.
