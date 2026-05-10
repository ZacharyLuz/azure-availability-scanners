<#
.SYNOPSIS
    Builds the unified Azure Availability Scanners family dashboard.

.DESCRIPTION
    Fetches GitHub traffic CSVs from each source repo's `traffic-data` branch
    via raw.githubusercontent.com (no auth required — all repos are public),
    aggregates the data, and renders docs/index.html using
    docs/index.template.html as the layout.

    No GitHub API tokens needed. No PSGallery API calls (PSGallery data is
    already collected by each source repo's collector and stored in
    psgallery-downloads.csv on its traffic-data branch).

.PARAMETER OutputPath
    Path to write the rendered dashboard HTML. Defaults to docs/index.html
    relative to the script root.

.PARAMETER TemplatePath
    Path to the HTML template. Defaults to docs/index.template.html.

.PARAMETER WindowDays
    Day window for "current period" totals (and the prior window for delta %).
    Default 60.

.EXAMPLE
    .\tools\Build-UnifiedDashboard.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$TemplatePath,
    [int]$WindowDays = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Constants
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $TemplatePath) { $TemplatePath = Join-Path $RepoRoot 'docs\index.template.html' }
if (-not $OutputPath)   { $OutputPath   = Join-Path $RepoRoot 'docs\index.html' }

$Tools = @(
    [ordered]@{ key = 'vm';   repo = 'Get-AzVMAvailability';        package = 'AzVMAvailability' }
    [ordered]@{ key = 'ai';   repo = 'Get-AzAIModelAvailability';   package = 'Get-AzAIModelAvailability' }
    [ordered]@{ key = 'paas'; repo = 'Get-AzPaaSAvailability';      package = 'Get-AzPaaSAvailability' }
)
$Owner = 'zacharyluz'
$Branch = 'traffic-data'
$RawBase = "https://raw.githubusercontent.com/$Owner"

$CsvFiles = @('views.csv', 'clones.csv', 'stars.csv', 'referrers.csv', 'psgallery-downloads.csv', 'repo-stats.csv')
#endregion

#region Helpers
function Get-RawCsv {
    param([string]$Repo, [string]$File)
    # Always emit individual rows to the pipeline; callers wrap with @() to guarantee array shape.
    $url = "$RawBase/$Repo/$Branch/data/$File"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        if (-not $resp.Content -or $resp.Content.Trim() -eq '') { return }
        $resp.Content | ConvertFrom-Csv
    } catch {
        Write-Verbose "Could not fetch ${Repo}/${File}: $_"
    }
}

function Get-DateRange {
    param([int]$Days)
    $end = (Get-Date).Date
    $start = $end.AddDays(-($Days - 1))
    return @{
        Start = $start
        End = $end
        Labels = 0..($Days - 1) | ForEach-Object { $start.AddDays($_).ToString('yyyy-MM-dd') }
    }
}

function Get-DailySeries {
    param(
        [array]$Rows,
        [string]$DateField,
        [string]$ValueField,
        [string[]]$Labels
    )
    # Build a date->value lookup, default 0 for missing dates
    $map = @{}
    foreach ($r in $Rows) {
        if (-not $r.$DateField) { continue }
        $dateStr = ([datetime]$r.$DateField).ToString('yyyy-MM-dd')
        $val = 0
        if ($r.$ValueField) { $val = [int]$r.$ValueField }
        $map[$dateStr] = $val
    }
    return @($Labels | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { 0 } })
}

function Get-CumulativeStarsSeries {
    param(
        [array]$StarRows,
        [string[]]$Labels
    )
    # stars.csv: Date,User,CumulativeStars (one row per star event, sorted ascending)
    if ($StarRows.Count -eq 0) {
        return @($Labels | ForEach-Object { 0 })
    }
    $sortedStars = @($StarRows | Where-Object { $_.Date } | Sort-Object Date)
    $series = @()
    foreach ($lbl in $Labels) {
        $lblDate = [datetime]$lbl
        # Find the highest CumulativeStars for events on or before this label date
        $cum = 0
        foreach ($s in $sortedStars) {
            if (([datetime]$s.Date) -le $lblDate) {
                $cum = [int]$s.CumulativeStars
            } else {
                break
            }
        }
        $series += $cum
    }
    return @($series)
}

function Get-PSGallerySeries {
    param(
        [array]$Rows,
        [string[]]$Labels
    )
    # psgallery-downloads.csv: Date,Version,VersionDownloads,TotalDownloads,IsLatestVersion
    # Per date, prefer IsLatestVersion=true, then take TotalDownloads.
    # For days with no snapshot, carry forward the last known value.
    if ($Rows.Count -eq 0) {
        return @($Labels | ForEach-Object { 0 })
    }
    $perDate = @{}
    foreach ($r in $Rows) {
        if (-not $r.Date) { continue }
        $d = ([datetime]$r.Date).ToString('yyyy-MM-dd')
        $isLatest = ($r.IsLatestVersion -eq 'true')
        $total = 0
        if ($r.TotalDownloads) { $total = [int]$r.TotalDownloads }
        if (-not $perDate.ContainsKey($d) -or $isLatest) {
            $perDate[$d] = $total
        }
    }
    $series = @()
    $last = 0
    foreach ($lbl in $Labels) {
        if ($perDate.ContainsKey($lbl)) { $last = $perDate[$lbl] }
        $series += $last
    }
    return @($series)
}

function Get-LatestVersion {
    param([array]$PSGalleryRows)
    if ($PSGalleryRows.Count -eq 0) { return $null }
    $latestRow = $PSGalleryRows | Where-Object { $_.IsLatestVersion -eq 'true' -and $_.Version } | Sort-Object Date -Descending | Select-Object -First 1
    if ($latestRow) { return $latestRow.Version }
    $anyRow = $PSGalleryRows | Where-Object { $_.Version } | Sort-Object Date -Descending | Select-Object -First 1
    if ($anyRow) { return $anyRow.Version }
    return $null
}

function Get-DeltaPct {
    param([double]$Current, [double]$Prior)
    if ($Prior -le 0) { return $null }
    return [math]::Round((($Current - $Prior) / $Prior) * 100, 2)
}

function Get-LatestReferrers {
    param([array]$Rows, [string]$ToolKey)
    if ($Rows.Count -eq 0) { return @() }
    $latestDate = ($Rows | Sort-Object CollectedDate -Descending | Select-Object -First 1).CollectedDate
    return @($Rows | Where-Object { $_.CollectedDate -eq $latestDate } | ForEach-Object {
        [pscustomobject]@{
            referrer = $_.Referrer
            tool = $ToolKey
            visitors = [int]$_.UniqueVisitors
        }
    })
}
#endregion

#region Fetch all data
Write-Host "Fetching CSV data from $($Tools.Count) repos..." -ForegroundColor Cyan
$range = Get-DateRange -Days $WindowDays
$priorRange = @{ Start = $range.Start.AddDays(-$WindowDays); End = $range.Start.AddDays(-1) }

$dataset = [ordered]@{
    labels = $range.Labels
    tools = [ordered]@{}
    totals = [ordered]@{}
    referrers = @()
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

$allReferrers = @()

foreach ($t in $Tools) {
    Write-Host "  $($t.repo)..." -NoNewline
    # Defensive @() wrapping — single-row CSVs would otherwise become a scalar under strict mode
    $views        = @(Get-RawCsv -Repo $t.repo -File 'views.csv')
    $clones       = @(Get-RawCsv -Repo $t.repo -File 'clones.csv')
    $stars        = @(Get-RawCsv -Repo $t.repo -File 'stars.csv')
    $referrers    = @(Get-RawCsv -Repo $t.repo -File 'referrers.csv')
    $psgallery    = @(Get-RawCsv -Repo $t.repo -File 'psgallery-downloads.csv')

    # Daily series (filled to label range with 0 for missing dates)
    $viewsSeries  = Get-DailySeries -Rows $views  -DateField 'Date' -ValueField 'UniqueViews'  -Labels $range.Labels
    $clonesSeries = Get-DailySeries -Rows $clones -DateField 'Date' -ValueField 'UniqueClones' -Labels $range.Labels
    $starsSeries  = Get-CumulativeStarsSeries -StarRows $stars -Labels $range.Labels
    $gallerySeries = Get-PSGallerySeries -Rows $psgallery -Labels $range.Labels

    # Window totals (current window)
    $viewsTotal  = ($viewsSeries  | Measure-Object -Sum).Sum
    $clonesTotal = ($clonesSeries | Measure-Object -Sum).Sum
    $starsTotal  = ($starsSeries  | Select-Object -Last 1)
    if (-not $starsTotal) { $starsTotal = 0 }
    $galleryTotal = ($gallerySeries | Select-Object -Last 1)
    if (-not $galleryTotal) { $galleryTotal = 0 }

    # Prior window totals for deltas
    $priorLabels = 0..($WindowDays - 1) | ForEach-Object { $priorRange.Start.AddDays($_).ToString('yyyy-MM-dd') }
    $priorViews  = (Get-DailySeries -Rows $views  -DateField 'Date' -ValueField 'UniqueViews'  -Labels $priorLabels | Measure-Object -Sum).Sum
    $priorClones = (Get-DailySeries -Rows $clones -DateField 'Date' -ValueField 'UniqueClones' -Labels $priorLabels | Measure-Object -Sum).Sum
    $priorStars  = (Get-CumulativeStarsSeries -StarRows $stars -Labels $priorLabels | Select-Object -Last 1)
    if (-not $priorStars) { $priorStars = 0 }
    $priorGallery = (Get-PSGallerySeries -Rows $psgallery -Labels $priorLabels | Select-Object -Last 1)
    if (-not $priorGallery) { $priorGallery = 0 }

    $version = Get-LatestVersion -PSGalleryRows $psgallery
    if (-not $version) { $version = 'n/a' }

    $dataset.tools[$t.key] = [ordered]@{
        repo = $t.repo
        package = $t.package
        version = $version
        series = [ordered]@{
            views = $viewsSeries
            clones = $clonesSeries
            stars = $starsSeries
            gallery = $gallerySeries
        }
        totals = [ordered]@{
            views = $viewsTotal
            clones = $clonesTotal
            stars = $starsTotal
            gallery = $galleryTotal
            viewsDeltaPct = Get-DeltaPct -Current $viewsTotal -Prior $priorViews
            clonesDeltaPct = Get-DeltaPct -Current $clonesTotal -Prior $priorClones
            starsDelta = ($starsTotal - $priorStars)
            galleryDeltaPct = Get-DeltaPct -Current $galleryTotal -Prior $priorGallery
        }
    }

    $allReferrers += Get-LatestReferrers -Rows $referrers -ToolKey $t.key

    Write-Host " v=$viewsTotal c=$clonesTotal s=$starsTotal g=$galleryTotal" -ForegroundColor Green
}

# Family totals
$famViews   = ($Tools | ForEach-Object { $dataset.tools[$_.key].totals.views }   | Measure-Object -Sum).Sum
$famClones  = ($Tools | ForEach-Object { $dataset.tools[$_.key].totals.clones }  | Measure-Object -Sum).Sum
$famStars   = ($Tools | ForEach-Object { $dataset.tools[$_.key].totals.stars }   | Measure-Object -Sum).Sum
$famGallery = ($Tools | ForEach-Object { $dataset.tools[$_.key].totals.gallery } | Measure-Object -Sum).Sum

$famPriorViews   = 0; $famPriorClones = 0; $famPriorStars = 0; $famPriorGallery = 0
foreach ($t in $Tools) {
    # Recompute prior totals from the same data (no caching to keep this script straightforward)
    $views     = @(Get-RawCsv -Repo $t.repo -File 'views.csv')
    $clones    = @(Get-RawCsv -Repo $t.repo -File 'clones.csv')
    $stars     = @(Get-RawCsv -Repo $t.repo -File 'stars.csv')
    $psgallery = @(Get-RawCsv -Repo $t.repo -File 'psgallery-downloads.csv')
    $priorLabels = 0..($WindowDays - 1) | ForEach-Object { $priorRange.Start.AddDays($_).ToString('yyyy-MM-dd') }
    $famPriorViews  += (Get-DailySeries -Rows $views  -DateField 'Date' -ValueField 'UniqueViews'  -Labels $priorLabels | Measure-Object -Sum).Sum
    $famPriorClones += (Get-DailySeries -Rows $clones -DateField 'Date' -ValueField 'UniqueClones' -Labels $priorLabels | Measure-Object -Sum).Sum
    $ps = (Get-CumulativeStarsSeries -StarRows $stars -Labels $priorLabels | Select-Object -Last 1)
    if ($ps) { $famPriorStars += $ps }
    $pg = (Get-PSGallerySeries -Rows $psgallery -Labels $priorLabels | Select-Object -Last 1)
    if ($pg) { $famPriorGallery += $pg }
}

$dataset.totals = [ordered]@{
    views   = $famViews
    clones  = $famClones
    stars   = $famStars
    gallery = $famGallery
    viewsDeltaPct   = Get-DeltaPct -Current $famViews   -Prior $famPriorViews
    clonesDeltaPct  = Get-DeltaPct -Current $famClones  -Prior $famPriorClones
    starsDelta      = ($famStars - $famPriorStars)
    galleryDeltaPct = Get-DeltaPct -Current $famGallery -Prior $famPriorGallery
}

# Top 10 referrers across all tools (combined by name, summed visitors)
$grouped = $allReferrers | Group-Object -Property referrer
$dataset.referrers = @($grouped | ForEach-Object {
    $totalVisitors = ($_.Group | Measure-Object -Property visitors -Sum).Sum
    # If multiple tools share a referrer, mark as 'all'
    $tools = @($_.Group | Select-Object -ExpandProperty tool -Unique)
    $tool = if ($tools.Count -gt 1) { 'all' } else { $tools[0] }
    [pscustomobject]@{
        referrer = $_.Name
        tool = $tool
        visitors = $totalVisitors
    }
} | Sort-Object visitors -Descending | Select-Object -First 10)

#endregion

#region Render template
Write-Host "`nRendering template..." -ForegroundColor Cyan

if (-not (Test-Path $TemplatePath)) {
    throw "Template not found: $TemplatePath"
}
$template = Get-Content -Raw -Path $TemplatePath -Encoding UTF8

$lastUpdated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm UTC')
$dataJson = $dataset | ConvertTo-Json -Depth 12 -Compress

$out = $template.Replace('{{LAST_UPDATED}}', $lastUpdated).Replace('{{DATA_JSON}}', $dataJson)

$outDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Set-Content -Path $OutputPath -Value $out -Encoding UTF8 -NoNewline

$sizeKB = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
Write-Host "Wrote $OutputPath ($sizeKB KB)" -ForegroundColor Green
Write-Host "  Family totals: views=$famViews clones=$famClones stars=$famStars gallery=$famGallery" -ForegroundColor Gray
Write-Host "  Window: $($range.Start.ToString('yyyy-MM-dd')) to $($range.End.ToString('yyyy-MM-dd')) ($WindowDays days)" -ForegroundColor Gray
#endregion
