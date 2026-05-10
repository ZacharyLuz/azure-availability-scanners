// ── azure-availability-scanners · unified dashboard renderer ──
// Reads the global DATA object injected by Build-UnifiedDashboard.ps1
// and renders all charts, hero stats, per-tool cards, and tables.

(function () {
  'use strict';

  if (typeof DATA === 'undefined') {
    console.error('DATA is not defined — Build-UnifiedDashboard.ps1 did not inject data');
    return;
  }

  const C = { vm: '#3b82f6', ai: '#a855f7', paas: '#10b981' };
  const TOOL_LABEL = {
    all: 'all 3 tools',
    vm: 'Get-AzVMAvailability',
    ai: 'Get-AzAIModelAvailability',
    paas: 'Get-AzPaaSAvailability'
  };
  const TOOL_KEYS = ['vm', 'ai', 'paas'];

  // ── Chart.js global defaults ─────────────────────────────────
  Chart.defaults.color = '#94a3b8';
  Chart.defaults.font.family = "'Inter',ui-sans-serif,system-ui,-apple-system,sans-serif";
  Chart.defaults.font.size = 11;

  const gridX = {
    ticks: { color: '#64748b', maxRotation: 0, autoSkip: true, maxTicksLimit: 8 },
    grid: { color: 'rgba(148,163,184,0.06)', drawBorder: false }
  };
  const gridY = {
    ticks: { color: '#64748b' },
    grid: { color: 'rgba(148,163,184,0.06)', drawBorder: false },
    beginAtZero: true
  };

  function fillGradient(ctx, color) {
    const g = ctx.createLinearGradient(0, 0, 0, 280);
    g.addColorStop(0, color + '55');
    g.addColorStop(1, color + '02');
    return g;
  }

  function fmtNum(n) {
    if (n === null || n === undefined || Number.isNaN(n)) return '—';
    if (n >= 10000) return (n / 1000).toFixed(1) + 'k';
    return n.toLocaleString();
  }

  function pctDelta(curr, prev) {
    if (!prev) return null;
    return ((curr - prev) / prev) * 100;
  }

  function setDelta(elId, deltaPct, suffix) {
    const el = document.getElementById(elId);
    if (!el) return;
    if (deltaPct === null || deltaPct === undefined || Number.isNaN(deltaPct)) {
      el.textContent = '—';
      el.classList.add('flat');
      return;
    }
    const sign = deltaPct >= 0 ? '▲' : '▼';
    el.textContent = `${sign} ${Math.abs(deltaPct).toFixed(1)}%${suffix || ''}`;
    el.classList.remove('flat', 'neg');
    if (deltaPct < 0) el.classList.add('neg');
  }

  function setAbsDelta(elId, delta, label) {
    const el = document.getElementById(elId);
    if (!el) return;
    if (delta === null || delta === undefined) { el.textContent = '—'; el.classList.add('flat'); return; }
    const sign = delta >= 0 ? '▲' : '▼';
    el.textContent = `${sign} ${Math.abs(delta)} ${label || ''}`.trim();
    el.classList.remove('flat', 'neg');
    if (delta < 0) el.classList.add('neg');
  }

  // ── Per-tool versions (range-independent, set once) ──────────
  TOOL_KEYS.forEach(t => {
    const tool = DATA.tools[t];
    if (!tool) return;
    const vEl = document.getElementById(`tool-${t}-version`);
    if (vEl) vEl.textContent = tool.version || '—';
  });

  // ── Sparklines ───────────────────────────────────────────────
  function spark(canvasId, dataArr, color) {
    const el = document.getElementById(canvasId);
    if (!el) return;
    const ctx = el.getContext('2d');
    new Chart(el, {
      type: 'line',
      data: {
        labels: dataArr.map((_, i) => i),
        datasets: [{
          data: dataArr,
          borderColor: color,
          backgroundColor: fillGradient(ctx, color),
          fill: true,
          borderWidth: 1.6,
          pointRadius: 0,
          tension: 0.35
        }]
      },
      options: {
        plugins: { legend: { display: false }, tooltip: { enabled: false } },
        scales: { x: { display: false }, y: { display: false } },
        maintainAspectRatio: false,
        responsive: true
      }
    });
  }
  TOOL_KEYS.forEach(t => spark(`spark-${t}`, DATA.tools[t].series.views, C[t]));

  // ── Unified toggle-driven chart (Views / Clones / Stars) ─────
  const labels = DATA.labels; // shared date axis

  const metricData = {
    views: {
      vm: DATA.tools.vm.series.views,
      ai: DATA.tools.ai.series.views,
      paas: DATA.tools.paas.series.views,
      stacked: true,
      type: 'line'
    },
    clones: {
      vm: DATA.tools.vm.series.clones,
      ai: DATA.tools.ai.series.clones,
      paas: DATA.tools.paas.series.clones,
      stacked: true,
      type: 'bar'
    },
    stars: {
      vm: DATA.tools.vm.series.stars,
      ai: DATA.tools.ai.series.stars,
      paas: DATA.tools.paas.series.stars,
      stacked: false,
      type: 'line'
    }
  };
  const metricSubtitle = {
    views:  'Daily unique visitors · GitHub Traffic API',
    clones: 'Daily git clones · GitHub Traffic API',
    stars:  'Cumulative stargazer growth · all time'
  };

  let currentMetric = 'views';
  let currentScope = 'all';
  let currentRange = 60; // 7 | 30 | 60 | 'all'
  let mainChart = null;

  // ── MASTER toggle helpers — every number metric is windowed by currentRange ─
  function rangeToN(r) {
    if (r === 'all' || !Number.isFinite(parseInt(r, 10))) return labels.length;
    return Math.min(parseInt(r, 10), labels.length);
  }
  function rangeLabel(r) { return (r === 'all') ? 'all time' : `last ${r}d`; }
  function priorLabel(r) { return (r === 'all') ? '' : ` vs prior ${r}d`; }

  function sliceTail(arr, n) {
    if (n === 'all' || !Number.isFinite(n)) return arr.slice();
    return arr.slice(Math.max(0, arr.length - n));
  }
  function sumTail(arr, n) {
    return arr.slice(-n).reduce((a, b) => a + (Number.isFinite(b) ? b : 0), 0);
  }
  function lastTail(arr, n) {
    const tail = arr.slice(-n);
    return tail.length ? tail[tail.length - 1] : 0;
  }
  // Prior-window sum for additive metrics; returns null when no prior data exists
  function priorWindowSum(arr, n) {
    if (n >= arr.length) return null;
    const end = arr.length - n;
    const start = Math.max(0, end - n);
    return arr.slice(start, end).reduce((a, b) => a + (Number.isFinite(b) ? b : 0), 0);
  }
  // Value at the day immediately before the window for cumulative metrics; null when none
  function valueBeforeWindow(arr, n) {
    const idx = arr.length - n - 1;
    return idx >= 0 ? arr[idx] : null;
  }

  // Recompute hero band + per-tool card numbers for the active range.
  // Called on init and on every #range button click via renderMain().
  function recomputeStats(range) {
    const n = rangeToN(range);
    let famViews = 0, famClones = 0, famStars = 0, famGallery = 0;
    let famPriorViews = 0, famPriorClones = 0;
    let famPriorViewsHas = false, famPriorClonesHas = false;
    let famPriorStars = 0, famPriorGallery = 0;
    let famPriorStarsHas = false, famPriorGalleryHas = false;

    TOOL_KEYS.forEach(t => {
      const s = DATA.tools[t].series;
      const v  = sumTail(s.views, n);
      const c  = sumTail(s.clones, n);
      const st = lastTail(s.stars, n);
      const g  = lastTail(s.gallery, n);
      famViews += v; famClones += c; famStars += st; famGallery += g;

      const pv = priorWindowSum(s.views, n);
      const pc = priorWindowSum(s.clones, n);
      const ps = valueBeforeWindow(s.stars, n);
      const pg = valueBeforeWindow(s.gallery, n);
      if (pv !== null) { famPriorViews  += pv; famPriorViewsHas  = true; }
      if (pc !== null) { famPriorClones += pc; famPriorClonesHas = true; }
      if (ps !== null) { famPriorStars  += ps; famPriorStarsHas  = true; }
      if (pg !== null) { famPriorGallery += pg; famPriorGalleryHas = true; }

      // Per-tool card numbers + deltas
      document.getElementById(`tool-${t}-views`).textContent  = fmtNum(v);
      document.getElementById(`tool-${t}-clones`).textContent = fmtNum(c);
      document.getElementById(`tool-${t}-stars`).textContent  = fmtNum(st);
      setDelta(`tool-${t}-views-delta`,  pv === null ? null : pctDelta(v, pv));
      setDelta(`tool-${t}-clones-delta`, pc === null ? null : pctDelta(c, pc));
      setAbsDelta(`tool-${t}-stars-delta`, ps === null ? null : (st - ps), 'new');
    });

    // Hero band
    document.getElementById('hero-views').textContent   = fmtNum(famViews);
    document.getElementById('hero-clones').textContent  = fmtNum(famClones);
    document.getElementById('hero-stars').textContent   = fmtNum(famStars);
    document.getElementById('hero-gallery').textContent = fmtNum(famGallery);

    setDelta('hero-views-delta',
      famPriorViewsHas ? pctDelta(famViews, famPriorViews) : null,
      priorLabel(range));
    setDelta('hero-clones-delta',
      famPriorClonesHas ? pctDelta(famClones, famPriorClones) : null,
      priorLabel(range));
    setAbsDelta('hero-stars-delta',
      famPriorStarsHas ? (famStars - famPriorStars) : null,
      'new');
    setDelta('hero-gallery-delta',
      famPriorGalleryHas ? pctDelta(famGallery, famPriorGallery) : null,
      priorLabel(range));

    const rl = document.getElementById('hero-range-label');
    if (rl) rl.textContent = rangeLabel(range);
  }

  function buildDatasets(metric, scope, n) {
    const md = metricData[metric];
    const tools = (scope === 'all') ? TOOL_KEYS : [scope];
    const ctx = document.getElementById('chart-main').getContext('2d');
    return tools.map(t => {
      const color = C[t];
      const label = TOOL_LABEL[t];
      const data = sliceTail(md[t], n);
      if (md.type === 'bar') {
        return {
          label, data, backgroundColor: color, borderRadius: 2,
          stack: (scope === 'all') ? 's1' : undefined
        };
      }
      if (md.stacked) {
        return {
          label, data, borderColor: color,
          backgroundColor: fillGradient(ctx, color), fill: true,
          borderWidth: 1.6, pointRadius: 0, tension: 0.3,
          stack: (scope === 'all') ? 's1' : undefined
        };
      }
      // Non-stacked line (e.g. cumulative stars): same frosted fill, baseline = origin
      return {
        label, data, borderColor: color,
        backgroundColor: fillGradient(ctx, color), fill: 'origin',
        borderWidth: 1.8, pointRadius: 0, tension: 0.25
      };
    });
  }

  function renderMain() {
    const md = metricData[currentMetric];
    const stacked = md.stacked && currentScope === 'all';
    const slicedLabels = sliceTail(labels, currentRange);
    const config = {
      type: md.type,
      data: { labels: slicedLabels, datasets: buildDatasets(currentMetric, currentScope, currentRange) },
      options: {
        maintainAspectRatio: false,
        responsive: true,
        plugins: {
          legend: { display: false },
          tooltip: { mode: 'index', intersect: false }
        },
        scales: {
          x: stacked ? { ...gridX, stacked: true } : gridX,
          y: stacked ? { ...gridY, stacked: true } : gridY
        },
        interaction: { mode: 'index', intersect: false }
      }
    };
    if (mainChart) mainChart.destroy();
    mainChart = new Chart(document.getElementById('chart-main'), config);
    document.getElementById('chart-sub').textContent =
      `${metricSubtitle[currentMetric]} · ${TOOL_LABEL[currentScope]} · ${rangeLabel(currentRange)}`;
    recomputeStats(currentRange);
  }

  document.querySelectorAll('#metric button').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('#metric button').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentMetric = btn.dataset.m;
      renderMain();
    });
  });
  document.querySelectorAll('#scope button').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('#scope button').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentScope = btn.dataset.tool;
      renderMain();
    });
  });
  document.querySelectorAll('#range button').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('#range button').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      const r = btn.dataset.r;
      currentRange = (r === 'all') ? 'all' : parseInt(r, 10);
      renderMain();
    });
  });
  renderMain();

  // ── Standalone PSGallery cumulative chart ────────────────────
  (function renderGallery() {
    const el = document.getElementById('chart-gallery');
    if (!el) return;
    const ctx = el.getContext('2d');
    new Chart(el, {
      type: 'line',
      data: {
        labels,
        datasets: TOOL_KEYS.map(t => ({
          label: TOOL_LABEL[t],
          data: DATA.tools[t].series.gallery,
          borderColor: C[t],
          backgroundColor: fillGradient(ctx, C[t]),
          fill: true,
          borderWidth: 1.6,
          pointRadius: 0,
          tension: 0.25
        }))
      },
      options: {
        maintainAspectRatio: false,
        responsive: true,
        plugins: {
          legend: { display: false },
          tooltip: { mode: 'index', intersect: false }
        },
        scales: { x: gridX, y: gridY },
        interaction: { mode: 'index', intersect: false }
      }
    });
  })();

  // ── Top referrers table ──────────────────────────────────────
  (function renderReferrers() {
    const tbody = document.querySelector('#referrers-table tbody');
    const refs = DATA.referrers || [];
    if (refs.length === 0) {
      tbody.innerHTML = '<tr><td colspan="3" style="text-align:center;color:var(--text-dim);padding:24px">No referrer data yet</td></tr>';
      return;
    }
    const max = Math.max(...refs.map(r => r.visitors));
    tbody.innerHTML = refs.map(r => {
      const pct = max > 0 ? Math.round((r.visitors / max) * 100) : 0;
      const color = r.tool === 'all' ? 'linear-gradient(90deg,var(--vm),var(--paas))' : `var(--${r.tool})`;
      const pillClass = r.tool === 'all' ? 'fam' : r.tool;
      const pillLabel = r.tool === 'all' ? 'All 3' : r.tool.toUpperCase();
      // Escape HTML in referrer name to prevent injection
      const safeRef = String(r.referrer).replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
      return `<tr>
        <td>${safeRef}</td>
        <td><span class="pill ${pillClass}">${pillLabel}</span></td>
        <td style="text-align:right"><span class="bar"><span style="width:${pct}%;background:${color}"></span></span>${r.visitors.toLocaleString()}</td>
      </tr>`;
    }).join('');
  })();

  // ── Tool comparison table ────────────────────────────────────
  (function renderComparison() {
    const tbody = document.querySelector('#comparison-table tbody');
    const rows = TOOL_KEYS
      .map(t => ({ key: t, ...DATA.tools[t] }))
      .sort((a, b) => b.totals.views - a.totals.views);
    let totV = 0, totC = 0, totS = 0;
    const html = rows.map(r => {
      totV += r.totals.views; totC += r.totals.clones; totS += r.totals.stars;
      return `<tr>
        <td><span class="pill ${r.key}">${r.key.toUpperCase()}</span> ${TOOL_LABEL[r.key]}</td>
        <td style="text-align:right">${r.totals.views.toLocaleString()}</td>
        <td style="text-align:right">${r.totals.clones.toLocaleString()}</td>
        <td style="text-align:right">${r.totals.stars.toLocaleString()}</td>
      </tr>`;
    }).join('');
    tbody.innerHTML = html + `<tr style="font-weight:700">
      <td>Family total</td>
      <td style="text-align:right">${totV.toLocaleString()}</td>
      <td style="text-align:right">${totC.toLocaleString()}</td>
      <td style="text-align:right">${totS.toLocaleString()}</td>
    </tr>`;
  })();

})();
