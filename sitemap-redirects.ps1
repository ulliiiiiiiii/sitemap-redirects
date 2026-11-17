#requires -Version 7.0
<#
.SYNOPSIS
    Builds the 301 redirects for a website move from the old sitemap and the list of new addresses.

.DESCRIPTION
    Reads every address from the old sitemap (a sitemap index is followed into its sitemaps) and looks for its
    new home: the same path, the same last path segment somewhere else, or a similar one. Writes redirect rules
    for Apache or nginx and a CSV report that lists every match and every gap, so nothing is left to chance.

    Exit status: 0 when every old address has a target, 2 when some have none or more than one.

.EXAMPLE
    ./sitemap-redirects.ps1 -OldSitemap https://www.example.org/sitemap_index.xml -New new-urls.txt

.EXAMPLE
    ./sitemap-redirects.ps1 -OldSitemap old.xml -New https://new.example.org/sitemap.xml -Format nginx
#>
[CmdletBinding()]
param(
    # Old sitemap or sitemap index, as URL or file.
    [Parameter(Mandatory)]
    [string] $OldSitemap,

    # New addresses: a sitemap (URL or file) or a text file with one address or path per line.
    [Parameter(Mandatory)]
    [string] $New,

    [ValidateSet('apache', 'nginx')]
    [string] $Format = 'apache',

    [string] $OutDir = 'redirects',

    # How similar two page names must be (0.5 to 1) to count as a match.
    [ValidateRange(0.5, 1.0)]
    [double] $MinScore = 0.8
)

$ErrorActionPreference = 'Stop'

if (-not ('SitemapRedirects' -as [type])) {
    Add-Type -TypeDefinition @'
public static class SitemapRedirects
{
    // Levenshtein similarity: 1 for equal strings, 0 for nothing in common.
    public static double Similarity(string a, string b)
    {
        if (a == b) return 1.0;
        if (a.Length == 0 || b.Length == 0) return 0.0;
        var prev = new int[b.Length + 1];
        var cur = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) prev[j] = j;
        for (int i = 1; i <= a.Length; i++)
        {
            cur[0] = i;
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                cur[j] = System.Math.Min(System.Math.Min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
            }
            var swap = prev; prev = cur; cur = swap;
        }
        return 1.0 - (double)prev[b.Length] / System.Math.Max(a.Length, b.Length);
    }
}
'@
}

function Get-Text {
    param([string] $Location)
    if ($Location -match '^https?://') {
        $content = (Invoke-WebRequest -Uri $Location -UseBasicParsing).Content
        if ($content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($content) } else { $content }
    } else {
        Get-Content -LiteralPath $Location -Raw
    }
}

function Get-SitemapAddress {
    # Every <loc> of a sitemap; a sitemap index is followed into its sitemaps.
    param([string] $Location, [int] $Depth = 0)
    if ($Depth -gt 3) { throw "Sitemaps nested too deep at $Location" }
    $doc = [xml] (Get-Text -Location $Location)
    if ($doc.sitemapindex) {
        $base = if ($Location -match '^https?://') { $null } else { Split-Path -Parent (Resolve-Path -LiteralPath $Location) }
        foreach ($loc in @($doc.sitemapindex.sitemap.loc)) {
            $child = $loc.Trim()
            if ($base -and $child -notmatch '^https?://') { $child = Join-Path $base $child }
            Get-SitemapAddress -Location $child -Depth ($Depth + 1)
        }
    } elseif ($doc.urlset) {
        foreach ($loc in @($doc.urlset.url.loc)) { $loc.Trim() }
    } else {
        throw "Not a sitemap: $Location"
    }
}

function Get-NewAddress {
    param([string] $Location)
    $text = Get-Text -Location $Location
    if ($text.TrimStart().StartsWith('<')) { return Get-SitemapAddress -Location $Location }
    $text -split "`r?`n" | ForEach-Object Trim | Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Get-UrlPath {
    param([string] $Address)
    if ($Address -match '^https?://') { return ([uri] $Address).AbsolutePath }
    if ($Address.StartsWith('/')) { $Address } else { "/$Address" }
}

function Get-Key {
    # Comparable form: decoded, lower case, umlauts spelled out, no file extension, no trailing slash.
    param([string] $UrlPath)
    $key = [uri]::UnescapeDataString($UrlPath).ToLowerInvariant()
    $key = $key -replace 'ä', 'ae' -replace 'ö', 'oe' -replace 'ü', 'ue' -replace 'ß', 'ss'
    $key = $key -replace '\.(html?|php|aspx?)$', '' -replace '/+$', ''
    if ($key) { $key } else { '/' }
}

function Get-Slug {
    param([string] $Key)
    ($Key -split '/')[-1]
}

function Format-Rule {
    param([string] $From, [string] $To)
    # Servers match the decoded path, so the rule uses it too, with or without a trailing slash.
    $pattern = '^' + [regex]::Escape([uri]::UnescapeDataString($From).TrimEnd('/')) + '/?$'
    if ($Format -eq 'nginx') { "location ~ `"$pattern`" { return 301 $To; }" }
    else { "RedirectMatch 301 `"$pattern`" `"$To`"" }
}

$oldAddresses = @(Get-SitemapAddress -Location $OldSitemap | Select-Object -Unique)
$newAddresses = @(Get-NewAddress -Location $New)
if ($oldAddresses.Count -eq 0) { throw 'The old sitemap lists no addresses.' }
if ($newAddresses.Count -eq 0) { throw 'The list of new addresses is empty.' }

$newByKey = @{}
$newBySlug = @{}
foreach ($address in $newAddresses) {
    $path = Get-UrlPath $address
    $key = Get-Key $path
    if (-not $newByKey.ContainsKey($key)) { $newByKey[$key] = $path }
    $slug = Get-Slug $key
    if (-not $newBySlug.ContainsKey($slug)) { $newBySlug[$slug] = [System.Collections.Generic.List[string]]::new() }
    if (-not $newBySlug[$slug].Contains($path)) { $newBySlug[$slug].Add($path) }
}
$slugs = @($newBySlug.Keys | Where-Object { $_ })

$report = foreach ($address in $oldAddresses) {
    $oldPath = Get-UrlPath $address
    $key = Get-Key $oldPath
    $slug = Get-Slug $key
    $target = ''
    $score = 1.0
    if ($newByKey.ContainsKey($key)) {
        $target = $newByKey[$key]
        $match = if ($oldPath -ceq $target) { 'unchanged' } else { 'normalized' }
    } elseif ($slug -and $newBySlug.ContainsKey($slug)) {
        $candidates = $newBySlug[$slug]
        if ($candidates.Count -eq 1) { $target = $candidates[0]; $match = 'same name' }
        else { $target = $candidates -join ' | '; $match = 'ambiguous' }
    } else {
        $best = $null
        $score = 0.0
        if ($slug) {
            foreach ($candidate in $slugs) {
                $similarity = [SitemapRedirects]::Similarity($slug, $candidate)
                if ($similarity -gt $score) { $score = $similarity; $best = $candidate }
            }
        }
        if ($best -and $score -ge $MinScore) {
            $candidates = $newBySlug[$best]
            if ($candidates.Count -eq 1) { $target = $candidates[0]; $match = 'similar' }
            else { $target = $candidates -join ' | '; $match = 'ambiguous' }
        } else {
            $match = 'none'
        }
        $score = [Math]::Round($score, 2)
    }
    $scoreText = ([double] $score).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    [pscustomobject]@{ Old = $oldPath; New = $target; Match = $match; Score = $scoreText }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$rulesFile = Join-Path $OutDir $(if ($Format -eq 'nginx') { 'redirects.nginx.conf' } else { 'redirects.htaccess' })
$reportFile = Join-Path $OutDir 'report.csv'
$rules = @($report | Where-Object Match -In 'normalized', 'same name', 'similar' | ForEach-Object { Format-Rule $_.Old $_.New })
Set-Content -LiteralPath $rulesFile -Value $rules -Encoding utf8
$report | Export-Csv -LiteralPath $reportFile -NoTypeInformation -Encoding utf8

$count = @{}
foreach ($kind in 'unchanged', 'normalized', 'same name', 'similar', 'ambiguous', 'none') {
    $count[$kind] = @($report | Where-Object Match -EQ $kind).Count
}
Write-Host ('{0} old addresses: {1} unchanged, {2} redirected ({3} same name, {4} similar, {5} spelling), {6} ambiguous, {7} without a target.' -f
    @($report).Count, $count['unchanged'], $rules.Count, $count['same name'], $count['similar'], $count['normalized'],
    $count['ambiguous'], $count['none'])
Write-Host "Rules:  $rulesFile"
Write-Host "Report: $reportFile"
if ($count['ambiguous'] + $count['none'] -gt 0) {
    Write-Host 'Check the rows marked ambiguous or none in the report and decide by hand.'
    exit 2
}
exit 0
