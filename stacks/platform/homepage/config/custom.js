// Homepage custom JS.
// Docs: https://gethomepage.dev/configs/custom-css-js/
//
// ⚠️ THIS FILE IS TRACKED ON PURPOSE AND IT IS MEANT TO STAY EMPTY.
//
// Homepage's checkAndCopyConfig() copies a skeleton into /app/config for any
// of its 9 config names that is ABSENT at startup:
//
//   bookmarks.yaml  custom.css  custom.js  docker.yaml  kubernetes.yaml
//   proxmox.yaml    services.yaml  settings.yaml  widgets.yaml
//
// /app/config is a bind mount of this directory inside Komodo's deploy clone,
// so a generated file lands in the clone as an UNTRACKED file. A later commit
// that adds a file of the same name then makes `git pull` refuse:
//
//   error: The following untracked working tree files would be
//   overwritten by merge: .../config/bookmarks.yaml, .../config/custom.css
//
// The pull aborts, the clone stays on its old commit, and Komodo keeps
// deploying stale config with no visible error. That happened here: the
// 2026-08-24 bookmarks strip never reached production, and it was only found
// on 2026-09-08 when the next change also failed.
//
// Tracking all 9 names closes the hole. A file that already exists is never
// generated, so no untracked collision can appear again.
//
// See the header of custom.css for the same warning, and compose.yaml for the
// full write-up.
