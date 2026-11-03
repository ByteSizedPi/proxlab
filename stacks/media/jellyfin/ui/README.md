# Jellyfin UI revamp

Custom CSS and JavaScript for the Jellyfin web client, with a live dev loop.
No Jellyfin restart is needed for any change in this folder.

## How it loads

1. The JavaScript Injector plugin injects one script on every page:
   `/web/ui/loader.js`. That is the only thing configured in Jellyfin.
2. `loader.js` reads `manifest.json` and loads every file it lists:
   `css/*.css`, then `js/*.js`, each in name order (`00-`, `10-`, ...).
3. `manifest.json` maps each file to a short hash. The hash is the URL's
   `?v=`, so a browser never runs a stale cached copy.

| URL | Host folder | Who loads it |
|---|---|---|
| `/web/ui/` | this folder, in the Komodo stack clone | everybody |
| `/web/ui-dev/` | `/mnt/docker-data/appdata/jellyfin-ui-dev` | only browsers in dev mode |

The plugin's only entry is `Src: /web/ui/loader.js` (Dashboard > Plugins >
JavaScript Injector, or `GET/POST /Plugins/f5a34f7b2e8a4e6aa7223a216a81b374/Configuration`).
It loads `loader.js` with no version query, so a browser can cache the loader
itself. After a change to `loader.js`, set `Src` to `/web/ui/loader.js?v=2`
(then 3, ...). Files listed in the manifest never need this.

## Dev loop

1. On jj-laptop run `stacks/media/jellyfin/ui/dev.sh`. It syncs this folder to
   the dev mount on every save, over the LAN or, when away, the tailnet.
2. Open Jellyfin with `?uidev=1` once, for example
   `https://jellyfin.<home domain>/web/?uidev=1`. The browser remembers it.
   `?uidev=0` turns it off.
3. Edit. A CSS save shows in about 1 second without a reload. A JS save
   reloads the page.

Only that browser sees dev files. Every other client keeps the production copy.

## Release

1. `dev.sh build`, so `manifest.json` matches the files.
2. Commit `ui/` **and touch `../compose.yaml`** (a comment is enough), then
   push. A push that changes only `ui/` is not deployed: Komodo decides from
   the compose file. The ui mount is a directory, so the pull is enough. No
   recreate is needed.

## Which clients run this

- Browsers, Jellyfin Desktop and the Android app load the web UI from the
  server, so they run the loader.
- The Samsung TV (Tizen) app ships its own jellyfin-web. It still fetches the
  Branding "Custom CSS" from the server, but it is not known whether the
  injected loader runs there. Test on the TV before relying on it.
- The admin dashboard ignores Branding "Custom CSS" in Jellyfin 12. The
  loader does run there.

The older Branding "Custom CSS" (Catppuccin Frappé, `../custom.css`) still
applies on top. It is pasted in Dashboard > General > Branding.
