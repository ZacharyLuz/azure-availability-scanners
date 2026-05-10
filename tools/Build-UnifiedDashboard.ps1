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
# In-memory cache so each CSV is fetched at most once per build run.
$script:CsvCache = @{}

function Get-RawCsv {
    param([string]$Repo, [string]$File)
    # Always emit individual rows to the pipeline; callers wrap with @() to guarantee array shape.
    $cacheKey = "$Repo/$File"
    if ($script:CsvCache.ContainsKey($cacheKey)) {
        # Cached value is already an array; re-emit row-by-row to preserve pipeline behaviour.
        foreach ($row in $script:CsvCache[$cacheKey]) { $row }
        return
    }
    $url = "$RawBase/$Repo/$Branch/data/$File"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        if (-not $resp.Content -or $resp.Content.Trim() -eq '') {
            $script:CsvCache[$cacheKey] = @()
            return
        }
        $rows = @($resp.Content | ConvertFrom-Csv)
        $script:CsvCache[$cacheKey] = $rows
        foreach ($row in $rows) { $row }
    } catch {
        Write-Verbose "Could not fetch ${Repo}/${File}: $_"
        $script:CsvCache[$cacheKey] = @()
    }
}

function Get-EarliestCsvDate {
    # Scan every cached row's Date column to find the earliest collected day across all tools/files.
    # Falls back to $FallbackStart if no parseable dates are found.
    param([datetime]$FallbackStart)
    $min = $null
    foreach ($rows in $script:CsvCache.Values) {
        foreach ($r in $rows) {
            if (-not $r.PSObject.Properties['Date'] -or -not $r.Date) { continue }
            try {
                $d = ([datetime]$r.Date).Date
                if ($null -eq $min -or $d -lt $min) { $min = $d }
            } catch {
                Write-Verbose "Skipping unparseable date '$($r.Date)'"
            }
        }
    }
    if ($null -eq $min) { return $FallbackStart }
    return $min
}

function Get-LabelsForRange {
    param([datetime]$Start, [datetime]$End)
    $days = ($End - $Start).Days + 1
    return @(0..($days - 1) | ForEach-Object { $Start.AddDays($_).ToString('yyyy-MM-dd') })
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

# The 60-day "current window" still drives the per-tool totals block (used by the static
# comparison table at the bottom of the page) and family-level deltas. The chart series
# is now full-history so the JS All toggle has real data to slice through.
$windowRange = Get-DateRange -Days $WindowDays
$priorRange = @{ Start = $windowRange.Start.AddDays(-$WindowDays); End = $windowRange.Start.AddDays(-1) }

# Pass 1: warm the CSV cache for every tool/file we care about. After this loop the script
# can compute the earliest date across all collected data.
foreach ($t in $Tools) {
    foreach ($file in $CsvFiles) { @(Get-RawCsv -Repo $t.repo -File $file) | Out-Null }
}

# Full history range = earliest date in any CSV → today. This is what the JS toggles slice.
$historyStart = Get-EarliestCsvDate -FallbackStart $windowRange.Start
$historyEnd   = (Get-Date).Date
$fullLabels   = Get-LabelsForRange -Start $historyStart -End $historyEnd
$fullDays     = $fullLabels.Count

$dataset = [ordered]@{
    labels = $fullLabels
    tools = [ordered]@{}
    totals = [ordered]@{}
    referrers = @()
    generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

$allReferrers = @()

foreach ($t in $Tools) {
    Write-Host "  $($t.repo)..." -NoNewline
    # Cached on first call in pass 1; this just re-reads from the in-memory cache.
    $views        = @(Get-RawCsv -Repo $t.repo -File 'views.csv')
    $clones       = @(Get-RawCsv -Repo $t.repo -File 'clones.csv')
    $stars        = @(Get-RawCsv -Repo $t.repo -File 'stars.csv')
    $referrers    = @(Get-RawCsv -Repo $t.repo -File 'referrers.csv')
    $psgallery    = @(Get-RawCsv -Repo $t.repo -File 'psgallery-downloads.csv')

    # Full-history series — JS slices these for 7d / 30d / 60d / All buttons.
    # Use TotalViews/TotalClones (matches the headline number GitHub shows on the Traffic page).
    $viewsSeries   = Get-DailySeries -Rows $views  -DateField 'Date' -ValueField 'TotalViews'  -Labels $fullLabels
    $clonesSeries  = Get-DailySeries -Rows $clones -DateField 'Date' -ValueField 'TotalClones' -Labels $fullLabels
    $starsSeries   = Get-CumulativeStarsSeries -StarRows $stars -Labels $fullLabels
    $gallerySeries = Get-PSGallerySeries -Rows $psgallery -Labels $fullLabels

    # 60-day window totals (kept for the static comparison table + backward-compat).
    $windowViewsSeries  = Get-DailySeries -Rows $views  -DateField 'Date' -ValueField 'TotalViews'  -Labels $windowRange.Labels
    $windowClonesSeries = Get-DailySeries -Rows $clones -DateField 'Date' -ValueField 'TotalClones' -Labels $windowRange.Labels
    $viewsTotal  = ($windowViewsSeries  | Measure-Object -Sum).Sum
    $clonesTotal = ($windowClonesSeries | Measure-Object -Sum).Sum
    $starsTotal  = ($starsSeries  | Select-Object -Last 1)
    if (-not $starsTotal) { $starsTotal = 0 }
    $galleryTotal = ($gallerySeries | Select-Object -Last 1)
    if (-not $galleryTotal) { $galleryTotal = 0 }

    # Prior window totals for deltas
    $priorLabels = 0..($WindowDays - 1) | ForEach-Object { $priorRange.Start.AddDays($_).ToString('yyyy-MM-dd') }
    $priorViews  = (Get-DailySeries -Rows $views  -DateField 'Date' -ValueField 'TotalViews'  -Labels $priorLabels | Measure-Object -Sum).Sum
    $priorClones = (Get-DailySeries -Rows $clones -DateField 'Date' -ValueField 'TotalClones' -Labels $priorLabels | Measure-Object -Sum).Sum
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
    # Re-uses cached CSVs from pass 1 (Get-RawCsv hits $script:CsvCache).
    $views     = @(Get-RawCsv -Repo $t.repo -File 'views.csv')
    $clones    = @(Get-RawCsv -Repo $t.repo -File 'clones.csv')
    $stars     = @(Get-RawCsv -Repo $t.repo -File 'stars.csv')
    $psgallery = @(Get-RawCsv -Repo $t.repo -File 'psgallery-downloads.csv')
    $priorLabels = 0..($WindowDays - 1) | ForEach-Object { $priorRange.Start.AddDays($_).ToString('yyyy-MM-dd') }
    $famPriorViews  += (Get-DailySeries -Rows $views  -DateField 'Date' -ValueField 'TotalViews'  -Labels $priorLabels | Measure-Object -Sum).Sum
    $famPriorClones += (Get-DailySeries -Rows $clones -DateField 'Date' -ValueField 'TotalClones' -Labels $priorLabels | Measure-Object -Sum).Sum
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
Write-Host "  Family totals (60d window): views=$famViews clones=$famClones stars=$famStars gallery=$famGallery" -ForegroundColor Gray
Write-Host "  Chart history: $($historyStart.ToString('yyyy-MM-dd')) to $($historyEnd.ToString('yyyy-MM-dd')) ($fullDays days)" -ForegroundColor Gray
#endregion
