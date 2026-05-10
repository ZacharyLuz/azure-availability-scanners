# Azure Availability Scanners — Family Dashboard

Unified GitHub traffic + PSGallery installs dashboard for the three sibling Azure availability scanner tools:

| Tool | Repo | PSGallery |
|------|------|-----------|
| 🟦 VM Availability | [Get-AzVMAvailability](https://github.com/zacharyluz/Get-AzVMAvailability) | [`AzVMAvailability`](https://www.powershellgallery.com/packages/AzVMAvailability) |
| 🟪 AI Model Availability | [Get-AzAIModelAvailability](https://github.com/zacharyluz/Get-AzAIModelAvailability) | [`Get-AzAIModelAvailability`](https://www.powershellgallery.com/packages/Get-AzAIModelAvailability) |
| 🟩 PaaS Availability | [Get-AzPaaSAvailability](https://github.com/zacharyluz/Get-AzPaaSAvailability) | [`Get-AzPaaSAvailability`](https://www.powershellgallery.com/packages/Get-AzPaaSAvailability) |

**Live dashboard:** https://zacharyluz.github.io/azure-availability-scanners/

## How it works

Each source repo runs its own `collect-traffic.yml` workflow on a 2x/day cron and on star/fork events. Those workflows publish CSV snapshots to a `traffic-data` orphan branch in their own repo and (after this repo exists) fire a `repository_dispatch` event back to this repo. This repo's `build-unified-dashboard.yml` workflow then:

1. Fetches the latest CSVs from each repo's `traffic-data` branch via `raw.githubusercontent.com` (no auth needed — all repos public).
2. Aggregates the data with [`tools/Build-UnifiedDashboard.ps1`](tools/Build-UnifiedDashboard.ps1).
3. Renders [`docs/index.template.html`](docs/index.template.html) with the data injected as a JSON blob consumed by [`docs/dashboard.js`](docs/dashboard.js) and Chart.js.
4. Commits the regenerated `docs/index.html` back to `main`.
5. GitHub Pages publishes from `main` `/docs`.

Cron offset: source repos run at `0 0,12 * * *`, this repo runs at `30 0,12 * * *` so the source CDN cache is warm.

## Layout (Option B)

- **Topbar** — title + last-updated stamp
- **Hero band** — 4 family-wide stats: views, clones, stars, PSGallery installs (all with Δ% vs prior 60-day window)
- **Per-tool cards** — one card per tool with version pill, current totals, and a sparkline
- **Unified chart** — toggles for metric (views / clones / stars) × scope (all / vm / ai / paas)
- **PSGallery card (standalone)** — cumulative install count over time, all three packages
- **Two-up row** — top 10 referrers + comparison table

## Local development

```pwsh
# Requires PowerShell 7+
./tools/Build-UnifiedDashboard.ps1
# Open docs/index.html in a browser
```

The aggregator fetches public CSVs over HTTPS — no GitHub token, no PSGallery API calls. Works offline only after a previous run has cached `docs/index.html`.

## Setup notes

After the repo is created on GitHub:

1. **Enable Pages** — Settings → Pages → Source: `main` branch, folder `/docs`.
2. **Create a fine-scoped PAT** named `UNIFIED_DASHBOARD_TOKEN`:
   - Repository access: only `azure-availability-scanners`
   - Permissions: `contents:read` + `actions:write`
3. **Add the PAT as a secret** to all three source repos (`Get-AzVMAvailability`, `Get-AzAIModelAvailability`, `Get-AzPaaSAvailability`) under Settings → Secrets → Actions → `UNIFIED_DASHBOARD_TOKEN`.

Once those steps are done, source-repo collectors will fire `repository_dispatch` events into this repo and the dashboard will rebuild within a minute of each upstream update — no extra cron lag.

## License

MIT — see [LICENSE](LICENSE).
