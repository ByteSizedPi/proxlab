# Jellyfin rating-distribution plugin — handoff

Carried over from a design session on claude.ai. Goal of this session: **find out what's possible on the real server** before writing the plugin. Explore first, build second.

## What we're building

A static panel on Jellyfin's item detail page that shows a title's audience-rating distribution, more informative than a single number.

- **Chart:** 10 bars, one per whole rating 1–10, counts on the y-axis. Each bar is coloured by quartile (Q1–Q4), and a bar that a quartile boundary falls inside is split at that point. There's a solid median line and a dashed mean line; the gap between them signals skew.
- **Headline row:** share rated ≥7 ("above 6"), mean, median with the IQR (Q1–Q3), and standard deviation.
- **Classifier row:** six profiles with the detected one highlighted, plus a one-line reason.
- **Not interactive.** No sliders and no resampling; it displays data and nothing else.
- `prototype/Main.dc.html` is the visual reference: a Claude design-canvas component, not production code. Its `stats()` and `classify()` methods are the maths to port.

## Data source decisions (already settled)

- **Trakt is the only viable source.** `/movies/:id/ratings` (and the shows, seasons and episodes equivalents) returns `{rating, votes, distribution: {"1": n, …, "10": n}}`. It needs a free client ID (`trakt-api-key` header) and accepts IMDb and TMDB IDs.
- **IMDb:** dropped. The official API is enterprise-only (AWS Data Exchange), and the free TSV dumps carry only the average and vote count. The histogram exists only on the website, and scraping it breaks IMDb's terms.
- **TMDB:** dropped. It has only an average and a count.
- **Rotten Tomatoes:** dropped. It doesn't expose individual scores.
- **Fallback** when Trakt has no entry or fewer than 30 votes: show Jellyfin's own `CommunityRating` / `CriticRating` without a chart.

## Maths (computed from the 10 counts c[1..10])

- **Mean and SD:** the usual weighted moments.
- **Quantiles:** grouped-data interpolation. Rating k covers [k−0.5, k+0.5], with votes spread evenly inside it.
- **Skew:** m3/m2^1.5. **Excess kurtosis:** m4/m2² − 3.
- **Sarle's bimodality coefficient:** BC = (skew² + 1) / (exk + 3(n−1)²/((n−2)(n−3))). A value above 0.555 suggests bimodal.
- **Classifier**, first match wins. These thresholds were tuned on synthetic data and **must be recalibrated against real Trakt distributions**.
  1. n < 30 → unclassified
  2. **Review-bombed:** at least 8% of votes are 1–2, median ≥ 6, and median − mean > 0.3
  3. **Cult flop:** mean < 5.5 and skew > 0.5
  4. **Divisive:** BC > 0.555 and SD > 1.6
  5. **Acclaimed:** median ≥ 7.8
  6. **Crowd-pleaser:** mean ≥ 6.3 and SD < 0.9
  7. **Middle of the road:** everything else

## Theming (requirement)

- Every colour is a CSS variable, so the panel follows the active Jellyfin theme, custom themes included.
- The prototype uses `--rd-surface`, `--rd-text`, `--rd-text-muted`, `--rd-text-faint`, `--rd-border`, `--rd-grid`, `--rd-accent` and `--rd-q1`…`--rd-q4`. Point each one at the host theme's variable where one exists, and use the prototype's values as fallbacks.
- **Two palettes:**
  - Trakt brand: purple → red (#8e44c4, #b23a98, #d22f62, #ed1c24).
  - Theme accent: `color-mix()` of `--rd-accent` at 35/58/80/100%.
- The font is Noto Sans, which Jellyfin's web client already uses.

## Open questions to answer on the real server

1. Which Jellyfin version is running? I couldn't find a "Jellyfin 12 theme spec"; the current line is 10.11.x. Check which CSS variables the installed web client and the active theme actually define.
2. How can a plugin add UI to the item detail page? There's no official hook that I know of. Community plugins inject JS into the web client. Find out what works on this version and how fragile it is.
3. Do the library items carry IMDb and TMDB provider IDs (`ProviderIds`)? Check what share of the library has them.
4. Pull real Trakt distributions for a sample of the library and recalibrate the classifier thresholds.
5. Plugin shape: a scheduled task that fetches from Trakt, a cache (SQLite or JSON in the plugin data dir) holding the counts, derived stats and fetched-at, an endpoint for the web UI, and a refresh policy (weekly for recent releases, monthly or less for older ones).

## Ground rules for this session

- Read-only against Jellyfin until told otherwise. No config changes, no plugin installs, no restarts.
- The Jellyfin API key and Trakt client ID come from environment variables (`JELLYFIN_URL`, `JELLYFIN_API_KEY`, `TRAKT_CLIENT_ID`). Never write them into files.
