// Homepage custom JS.
// Docs: https://gethomepage.dev/configs/custom-css-js/
//
// ⚠️ THIS FILE IS TRACKED ON PURPOSE. Do not delete it, even if the code
// below is removed. The reason is the first comment block. The code is the
// "Top containers" table, explained in the second block.
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

// ── Top containers table ────────────────────────────────────────────────
//
// Fills the "Top containers" card (group "Load" in services.yaml). Its two
// customapi widgets fetch Netdata's 60 s average CPU (index 0) and RAM
// (index 1) per container. Homepage cannot sort, so this script reads the
// same JSON through Homepage's proxy, sorts by CPU, and replaces the card's
// widget area with a table. On any error the plain widgets stay visible.
(function () {
  const GROUP = "Load";
  const NAME = "Top containers";
  const ROWS = 8;
  const proxy = (i) =>
    "/api/services/proxy?" +
    new URLSearchParams({ group: GROUP, service: NAME, index: String(i) });

  // Netdata instance names look like "cgroup_jellyfin.cpu@<node>".
  function rank(json) {
    const names = json.view.dimensions.names;
    const row = json.result.data[0].slice(1);
    return names
      .map((n, i) => ({
        name: n.replace(/^cgroup_/, "").replace(/\.[a-z_]+@.*$/, ""),
        value: (row[i] && row[i][0]) || 0,
      }))
      .sort((a, b) => b.value - a.value);
  }

  function level(cpu) {
    if (cpu >= 400) return "tc-high"; // four full cores
    if (cpu >= 100) return "tc-mid"; // one full core
    return "";
  }

  async function render() {
    const li = document.querySelector('[data-name="' + NAME + '"]');
    if (!li) return;
    const card = li.querySelector(".service-card") || li;
    try {
      const [cpuJson, memJson] = await Promise.all(
        [0, 1].map((i) =>
          fetch(proxy(i)).then((r) => {
            if (!r.ok) throw new Error("HTTP " + r.status);
            return r.json();
          })
        )
      );
      const cpu = rank(cpuJson).slice(0, ROWS);
      const mem = new Map(rank(memJson).map((x) => [x.name, x.value]));

      let box = card.querySelector(".tc-table");
      if (!box) {
        box = document.createElement("div");
        box.className = "tc-table";
        card.appendChild(box);
        card
          .querySelectorAll(":scope > .service-container")
          .forEach((el) => (el.style.display = "none"));
      }
      box.innerHTML =
        '<div class="tc-row tc-head"><span>Container</span><span>CPU</span><span>RAM</span></div>' +
        cpu
          .map(
            (c) =>
              '<div class="tc-row"><span>' + c.name + "</span>" +
              '<span class="' + level(c.value) + '">' + c.value.toFixed(0) + "%</span>" +
              "<span>" + Math.round(mem.get(c.name) || 0) + " MiB</span></div>"
          )
          .join("");
    } catch (e) {
      console.warn("Top containers:", e);
    }
  }

  // The page renders client-side, so wait for the card to exist.
  const start = setInterval(() => {
    if (document.querySelector('[data-name="' + NAME + '"]')) {
      clearInterval(start);
      render();
      setInterval(render, 15000);
    }
  }, 500);
})();
