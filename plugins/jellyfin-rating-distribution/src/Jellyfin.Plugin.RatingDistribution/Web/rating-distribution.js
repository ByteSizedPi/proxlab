// Rating Distribution: draws the Trakt rating histogram on the item detail page.
// The server adds this file to index.html (see ScriptInjectionStartupFilter.cs).
// stats() and classify() are ported unchanged from prototype/Main.dc.html.
(function () {
    'use strict';

    if (window.__ratingDistribution) return;
    window.__ratingDistribution = true;

    const PANEL = 'rd-panel';
    const NAMES = { mid: 'Middle of the road', safe: 'Crowd-pleaser', acclaimed: 'Acclaimed', divisive: 'Divisive', cult: 'Cult flop', bombed: 'Review-bombed' };
    const ORDER = ['mid', 'safe', 'acclaimed', 'divisive', 'cult', 'bombed'];

    // Every colour is a variable. Text colours derive from the page's own text colour,
    // so the panel follows any theme without knowing its variable names.
    const CSS = `
.${PANEL} {
  --rd-text: currentColor;
  --rd-text-muted: color-mix(in srgb, currentColor 62%, transparent);
  --rd-text-faint: color-mix(in srgb, currentColor 42%, transparent);
  --rd-border: color-mix(in srgb, currentColor 12%, transparent);
  --rd-grid: color-mix(in srgb, currentColor 7%, transparent);
  --rd-accent: var(--jf-palette-primary-main, #00a4dc);
  --rd-q1: #8e44c4; --rd-q2: #b23a98; --rd-q3: #d22f62; --rd-q4: #ed1c24;
  box-sizing: border-box; max-width: 840px; margin: 1.5em 0; padding: 0;
  color: var(--rd-text); font-variant-numeric: tabular-nums;
  display: flex; flex-direction: column; gap: 16px;
}
.${PANEL}[data-palette="accent"] {
  --rd-q1: color-mix(in srgb, var(--rd-accent) 35%, transparent);
  --rd-q2: color-mix(in srgb, var(--rd-accent) 58%, transparent);
  --rd-q3: color-mix(in srgb, var(--rd-accent) 80%, transparent);
  --rd-q4: var(--rd-accent);
}
.${PANEL} .rd-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.${PANEL} .rd-title { margin: 0; font-size: 1.15em; font-weight: 500; }
.${PANEL} .rd-sub { font-size: .8em; color: var(--rd-text-muted); }
.${PANEL} .rd-brand { display: flex; flex-direction: column; align-items: flex-end; gap: 6px; color: inherit; text-decoration: none; }
.${PANEL} .rd-brand span:first-child { font-size: .7em; font-weight: 600; letter-spacing: .08em; text-transform: uppercase; }
.${PANEL} .rd-brand span:last-child { width: 56px; height: 4px; border-radius: 2px; background: linear-gradient(90deg, var(--rd-q1), var(--rd-q2), var(--rd-q3), var(--rd-q4)); }
.${PANEL} .rd-stats { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px; }
.${PANEL} .rd-stat { display: flex; flex-direction: column; gap: 2px; border-left: 1px solid var(--rd-border); padding-left: 12px; min-width: 0; }
.${PANEL} .rd-stat:first-child { border-left: 2px solid var(--rd-q4); }
.${PANEL} .rd-k { font-size: .7em; letter-spacing: .06em; text-transform: uppercase; color: var(--rd-text-muted); }
.${PANEL} .rd-v { font-size: 1.7em; font-weight: 300; line-height: 1.15; }
.${PANEL} .rd-n { font-size: .7em; color: var(--rd-text-faint); }
.${PANEL} svg { width: 100%; height: auto; display: block; overflow: visible; }
.${PANEL} .rd-profile { display: flex; flex-direction: column; gap: 8px; border-top: 1px solid var(--rd-border); padding-top: 12px; }
.${PANEL} .rd-pills { display: flex; align-items: center; gap: 4px; flex-wrap: wrap; }
.${PANEL} .rd-pill { height: 28px; padding: 0 12px; border-radius: 14px; display: inline-flex; align-items: center; font-size: .8em; color: var(--rd-text-faint); border: 1px solid transparent; }
.${PANEL} .rd-pill.on { color: var(--rd-text); font-weight: 600; border-color: var(--rd-text); background: var(--rd-grid); }
.${PANEL} .rd-reason { font-size: .8em; color: var(--rd-text-muted); }
@media (max-width: 600px) { .${PANEL} .rd-stats { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
`;

    // ---- Maths: identical to the prototype ----
    function stats(c) {
        let n = 0, s1 = 0;
        for (let k = 1; k <= 10; k++) { n += c[k]; s1 += k * c[k]; }
        const mean = s1 / n;
        let m2 = 0, m3 = 0, m4 = 0;
        for (let k = 1; k <= 10; k++) { const d = k - mean; m2 += c[k] * d * d; m3 += c[k] * d * d * d; m4 += c[k] * d * d * d * d; }
        m2 /= n; m3 /= n; m4 /= n;
        const q = function (p) {
            const target = p * n;
            let cum = 0;
            for (let k = 1; k <= 10; k++) {
                if (c[k] > 0 && cum + c[k] >= target) return (k - 0.5) + (target - cum) / c[k];
                cum += c[k];
            }
            return 10;
        };
        let above = 0; for (let k = 7; k <= 10; k++) above += c[k];
        const skew = m2 > 0 ? m3 / Math.pow(m2, 1.5) : 0;
        const exk = m2 > 0 ? m4 / (m2 * m2) - 3 : 0;
        const bc = n > 3 ? (skew * skew + 1) / (exk + 3 * (n - 1) * (n - 1) / ((n - 2) * (n - 3))) : 0;
        return { n: n, mean: mean, sd: Math.sqrt(m2 * n / Math.max(1, n - 1)), med: q(0.5), q1: q(0.25), q3: q(0.75), skew: skew, bc: bc, low: (c[1] + c[2]) / n, above: above / n };
    }

    function classify(st, minVotes) {
        const f = function (x, d) { return x.toFixed(d); };
        const pct = function (x) { return Math.round(x * 100) + '%'; };
        if (st.n < minVotes) return { id: null, why: 'Only ' + st.n + ' ratings so far: too few to call a shape.' };
        if (st.low >= 0.08 && st.med >= 6 && st.med - st.mean > 0.3) return { id: 'bombed', why: pct(st.low) + ' of votes are a 1 or 2 on a title with a median of ' + f(st.med, 1) + ', dragging the mean ' + f(st.med - st.mean, 1) + ' below it.' };
        if (st.mean < 5.5 && st.skew > 0.5) return { id: 'cult', why: 'Low centre (' + f(st.mean, 1) + ') with right skew ' + f(st.skew, 2) + ': a tail of fans lifts the mean above the median.' };
        if (st.bc > 0.555 && st.sd > 1.6) return { id: 'divisive', why: 'Bimodality coefficient ' + f(st.bc, 2) + ' (above 0.555) and spread ' + f(st.sd, 1) + ': two camps, little middle ground.' };
        if (st.med >= 7.8) return { id: 'acclaimed', why: 'Median ' + f(st.med, 1) + ': half of all ratings are at or above it.' };
        if (st.mean >= 6.3 && st.sd < 0.9) return { id: 'safe', why: 'Mean ' + f(st.mean, 1) + ' with a tight spread of ' + f(st.sd, 2) + ': broad, mild approval.' };
        return { id: 'mid', why: 'Centred at ' + f(st.mean, 1) + ' with spread ' + f(st.sd, 1) + ': no strong lean either way.' };
    }

    function niceStep(raw) {
        const p = Math.pow(10, Math.floor(Math.log10(raw)));
        const m = raw / p;
        return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p;
    }

    // ---- Chart: the prototype's geometry, with the tick labels moved into the SVG ----
    function chartSvg(c, st) {
        const PL = 28, PR = 784, TOP = 24, BASE = 196, lo = 0.5, hi = 10.5;
        const sx = function (x) { return PL + (x - lo) / (hi - lo) * (PR - PL); };
        let cmax = 0; for (let k = 1; k <= 10; k++) if (c[k] > cmax) cmax = c[k];
        const step = niceStep(Math.max(1, cmax * 1.05) / 3);
        const yTop = Math.ceil((cmax * 1.05) / step) * step;
        const sy = function (v) { return BASE - v / yTop * (BASE - TOP); };
        const r = function (v) { return Math.round(v * 10) / 10; };

        const bars = ['', '', '', ''];
        const cuts = [st.q1, st.med, st.q3];
        const halfW = 0.38;
        for (let k = 1; k <= 10; k++) {
            if (c[k] === 0) continue;
            const a = k - halfW, z = k + halfW;
            const pts = [a];
            cuts.forEach(function (q) { if (q > a && q < z) pts.push(q); });
            pts.push(z);
            pts.sort(function (p, q) { return p - q; });
            const yT = r(sy(c[k]));
            const hgt = r(BASE - yT);
            for (let j = 0; j < pts.length - 1; j++) {
                const x0 = sx(pts[j]), x1 = sx(pts[j + 1]);
                const mid = (pts[j] + pts[j + 1]) / 2;
                const qi = mid < st.q1 ? 0 : mid < st.med ? 1 : mid < st.q3 ? 2 : 3;
                bars[qi] += 'M' + r(x0) + ',' + yT + 'h' + r(x1 - x0) + 'v' + hgt + 'h' + r(x0 - x1) + 'Z';
            }
        }

        let grid = '', yLabels = '', xLabels = '';
        for (let v = step; v <= yTop + 1e-9; v += step) {
            const y = r(sy(v));
            grid += 'M' + PL + ',' + (y + 0.5) + ' L' + PR + ',' + (y + 0.5) + ' ';
            const label = v >= 1000 ? (Math.round(v / 100) / 10) + 'k' : String(Math.round(v));
            yLabels += '<text x="22" y="' + (y + 4) + '" text-anchor="end" font-size="10" style="fill: var(--rd-text-faint)">' + label + '</text>';
        }
        for (let v = 1; v <= 10; v++) {
            xLabels += '<text x="' + r(sx(v)) + '" y="214" text-anchor="middle" font-size="11" style="fill: var(--rd-text-muted)">' + v + '</text>';
        }

        const xMed = r(sx(st.med)), xMean = r(sx(st.mean));
        const close = Math.abs(xMed - xMean) < 48;
        const meanTop = close ? 38 : 22, meanLabelY = close ? 32 : 14;
        const aria = 'Votes per rating from 1 to 10, shaded by quartile, median ' + st.med.toFixed(1) + ', mean ' + st.mean.toFixed(1);

        return '<svg viewBox="0 0 784 222" role="img" aria-label="' + aria + '" font-family="inherit">' +
            '<path d="' + grid + '" style="stroke: var(--rd-grid); fill: none" stroke-width="1"></path>' +
            '<path d="' + bars[0] + '" style="fill: var(--rd-q1)"></path>' +
            '<path d="' + bars[1] + '" style="fill: var(--rd-q2)"></path>' +
            '<path d="' + bars[2] + '" style="fill: var(--rd-q3)"></path>' +
            '<path d="' + bars[3] + '" style="fill: var(--rd-q4)"></path>' +
            '<line x1="28" x2="784" y1="196.5" y2="196.5" style="stroke: var(--rd-text-faint)" stroke-width="1"></line>' +
            '<line x1="' + xMed + '" x2="' + xMed + '" y1="22" y2="196" style="stroke: var(--rd-text)" stroke-width="1.5"></line>' +
            '<text x="' + xMed + '" y="14" text-anchor="middle" font-size="11" style="fill: var(--rd-text)">median</text>' +
            '<line x1="' + xMean + '" x2="' + xMean + '" y1="' + meanTop + '" y2="196" style="stroke: var(--rd-text)" stroke-width="1" stroke-dasharray="3 3"></line>' +
            '<text x="' + xMean + '" y="' + meanLabelY + '" text-anchor="middle" font-size="11" style="fill: var(--rd-text-muted)">mean</text>' +
            yLabels + xLabels + '</svg>';
    }

    function stat(key, value, note) {
        return '<div class="rd-stat"><span class="rd-k">' + key + '</span><span class="rd-v">' + value + '</span><span class="rd-n">' + note + '</span></div>';
    }

    function buildPanel(itemId, data) {
        const el = document.createElement('div');
        el.className = PANEL;
        el.dataset.item = itemId;

        const c = [0].concat(data.counts);
        const st = stats(c);
        const cls = classify(st, data.minVotes || 30);
        const brand = '<span>Trakt</span><span></span>';

        let html = '<div class="rd-head"><div><h2 class="rd-title">Rating distribution</h2>' +
            '<div class="rd-sub">' + st.n.toLocaleString() + ' votes</div></div>' +
            (data.traktUrl ? '<a class="rd-brand" target="_blank" rel="noopener">' + brand + '</a>' : '<div class="rd-brand">' + brand + '</div>') +
            '</div>';

        if (cls.id !== null) {
            html += '<div class="rd-stats">' +
                stat('Above 6', Math.round(st.above * 100) + '%', 'rated 7 or higher') +
                stat('Mean', st.mean.toFixed(1), 'out of 10') +
                stat('Median', st.med.toFixed(1), 'middle half ' + st.q1.toFixed(1) + '–' + st.q3.toFixed(1)) +
                stat('Spread', st.sd.toFixed(2), 'standard deviation') +
                '</div>' + chartSvg(c, st) +
                '<div class="rd-profile"><div class="rd-pills"><span class="rd-k" style="margin-right:10px">Profile</span>' +
                ORDER.map(function (id) { return '<span class="rd-pill' + (id === cls.id ? ' on' : '') + '">' + NAMES[id] + '</span>'; }).join('') +
                '</div><div class="rd-reason"></div></div>';
        } else {
            html += '<div class="rd-reason"></div>';
        }

        el.innerHTML = html;
        el.querySelector('.rd-reason').textContent = cls.why;
        const link = el.querySelector('a.rd-brand');
        if (link) link.setAttribute('href', data.traktUrl);
        return el;
    }

    // ---- Page wiring ----
    const responses = new Map();
    const pending = new Set();

    function currentItemId() {
        const query = location.hash.split('?')[1] || location.search.slice(1);
        return new URLSearchParams(query).get('id');
    }

    function insert(page, panel) {
        const reviews = page.querySelector('.tmdb-reviews-section');
        if (reviews && reviews.parentNode) { reviews.parentNode.insertBefore(panel, reviews); return true; }
        const anchor = page.querySelector('.streaming-lookup-container') || page.querySelector('.itemExternalLinks') || page.querySelector('.tagline');
        if (anchor && anchor.parentNode) { anchor.parentNode.insertBefore(panel, anchor.nextSibling); return true; }
        const content = page.querySelector('.detailPageContent');
        if (content) { content.appendChild(panel); return true; }
        return false;
    }

    function render(page, itemId, data) {
        page.querySelectorAll('.' + PANEL).forEach(function (p) { if (p.dataset.item !== itemId) p.remove(); });
        if (page.querySelector('.' + PANEL + '[data-item="' + itemId + '"]')) return;
        if (!data || data.source !== 'trakt' || !data.counts || !data.counts.some(function (n) { return n > 0; })) return;
        insert(page, buildPanel(itemId, data));
    }

    async function process() {
        const page = document.querySelector('#itemDetailPage:not(.hide)');
        if (!page || !window.ApiClient) return;
        const itemId = currentItemId();
        if (!itemId) return;

        if (responses.has(itemId)) { render(page, itemId, responses.get(itemId)); return; }
        if (pending.has(itemId)) return;
        pending.add(itemId);
        try {
            const data = await ApiClient.ajax({ type: 'GET', url: ApiClient.getUrl('RatingDistribution/Items/' + itemId), dataType: 'json' });
            responses.set(itemId, data);
        } catch (e) {
            responses.set(itemId, null);
            console.warn('Rating Distribution: request failed for', itemId, e);
        } finally {
            pending.delete(itemId);
        }
        if (currentItemId() === itemId) render(page, itemId, responses.get(itemId));
    }

    // Throttle, not debounce: constant DOM churn must not postpone the check forever.
    let scheduled = false;
    function schedule(delay) {
        if (scheduled) return;
        scheduled = true;
        setTimeout(function () { scheduled = false; process(); }, delay);
    }

    const style = document.createElement('style');
    style.textContent = CSS;
    document.head.appendChild(style);

    document.addEventListener('viewshow', function () { schedule(150); });
    window.addEventListener('hashchange', function () { schedule(150); });
    window.addEventListener('popstate', function () { schedule(150); });
    // The web client re-renders detail sections after load. A throttled body observer
    // puts the panel back if a re-render removes it.
    new MutationObserver(function () { schedule(400); }).observe(document.body, { childList: true, subtree: true });
    schedule(500);
})();
