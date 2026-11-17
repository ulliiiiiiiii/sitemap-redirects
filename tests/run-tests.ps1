#requires -Version 7.0
# Runs without extra modules: pwsh ./tests/run-tests.ps1
$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot '..' 'sitemap-redirects.ps1'
$script:failures = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if ($Condition) { Write-Host "ok    $Message" }
    else { Write-Host "FAIL  $Message"; $script:failures++ }
}

function New-Sitemap {
    param([string[]] $Locations)
    $urls = ($Locations | ForEach-Object { "  <url><loc>https://www.example.org$_</loc></url>" }) -join "`n"
    "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<urlset xmlns=`"http://www.sitemaps.org/schemas/sitemap/0.9`">`n$urls`n</urlset>"
}

function Invoke-Tool {
    # Runs the tool like a user would and returns its exit status.
    param([string[]] $Arguments)
    $null = & pwsh -NoProfile -File $tool @Arguments 2>&1
    $LASTEXITCODE
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "sitemap-redirects-tests-$PID"
$old = Join-Path $work 'old'
New-Item -ItemType Directory -Path $old -Force | Out-Null

try {
    Set-Content -LiteralPath (Join-Path $old 'sitemap_index.xml') -Encoding utf8 -Value @'
<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap><loc>post-sitemap.xml</loc></sitemap>
  <sitemap><loc>page-sitemap.xml</loc></sitemap>
</sitemapindex>
'@
    Set-Content -LiteralPath (Join-Path $old 'post-sitemap.xml') -Encoding utf8 -Value (New-Sitemap @(
            '/news/sommerfest-2025/', '/news/neue-kurse/', '/%C3%BCber-uns/', '/kontakt/'))
    Set-Content -LiteralPath (Join-Path $old 'page-sitemap.xml') -Encoding utf8 -Value (New-Sitemap @(
            '/', '/angebote/fitness/', '/angebote/yoga-kurs/', '/alte-seite.html', '/termine/', '/info/', '/kurse/zumba.html'))
    $newList = Join-Path $work 'new-urls.txt'
    Set-Content -LiteralPath $newList -Encoding utf8 -Value @(
        '# new site', '/', '/aktuelles/sommerfest-2025/', '/aktuelles/neue-kurse/', '/verein/ueber-uns/', '/kontakt/',
        '/sport/fitness/', '/sport/yogakurs/', '/termine/', '/team/info/', '/hilfe/info/', '/kurse/zumba/')

    $out = Join-Path $work 'apache'
    $status = Invoke-Tool @('-OldSitemap', (Join-Path $old 'sitemap_index.xml'), '-New', $newList, '-OutDir', $out)
    Assert-True ($status -eq 2) 'exit status 2 while addresses are left without a clear target'
    $report = @(Import-Csv -LiteralPath (Join-Path $out 'report.csv'))
    $match = @{}
    foreach ($row in $report) { $match[$row.Old] = $row }
    Assert-True ($report.Count -eq 11) 'follows the sitemap index into both sitemaps'
    Assert-True ($match['/'].Match -eq 'unchanged' -and $match['/kontakt/'].Match -eq 'unchanged') 'keeps addresses that did not move'
    Assert-True ($match['/news/sommerfest-2025/'].New -eq '/aktuelles/sommerfest-2025/') 'finds a page under the same name in a new folder'
    Assert-True ($match['/%C3%BCber-uns/'].New -eq '/verein/ueber-uns/') 'treats ü and ue as the same'
    Assert-True ($match['/angebote/yoga-kurs/'].Match -eq 'similar' -and $match['/angebote/yoga-kurs/'].New -eq '/sport/yogakurs/') 'matches a similar name'
    Assert-True ($match['/kurse/zumba.html'].Match -eq 'normalized') 'drops .html and the trailing slash when comparing'
    Assert-True ($match['/info/'].Match -eq 'ambiguous') 'does not guess when two new pages share a name'
    Assert-True ($match['/alte-seite.html'].Match -eq 'none') 'reports pages without a new home'

    $rules = @(Get-Content -LiteralPath (Join-Path $out 'redirects.htaccess'))
    Assert-True ($rules.Count -eq 6) 'writes one rule per moved page'
    Assert-True ($rules -contains 'RedirectMatch 301 "^/news/sommerfest-2025/?$" "/aktuelles/sommerfest-2025/"') 'Apache rule matches with and without slash'
    Assert-True ($rules -contains 'RedirectMatch 301 "^/über-uns/?$" "/verein/ueber-uns/"') 'rule uses the decoded path the server sees'
    Assert-True ($rules -contains 'RedirectMatch 301 "^/kurse/zumba\.html/?$" "/kurse/zumba/"') 'escapes dots in the pattern'

    $nginx = Join-Path $work 'nginx'
    $null = Invoke-Tool @('-OldSitemap', (Join-Path $old 'sitemap_index.xml'), '-New', $newList, '-OutDir', $nginx, '-Format', 'nginx')
    $nginxRules = @(Get-Content -LiteralPath (Join-Path $nginx 'redirects.nginx.conf'))
    Assert-True ($nginxRules -contains 'location ~ "^/news/sommerfest-2025/?$" { return 301 /aktuelles/sommerfest-2025/; }') 'writes nginx rules'

    $strict = Join-Path $work 'strict'
    $null = Invoke-Tool @('-OldSitemap', (Join-Path $old 'sitemap_index.xml'), '-New', $newList, '-OutDir', $strict, '-MinScore', '0.95')
    $strictRow = Import-Csv -LiteralPath (Join-Path $strict 'report.csv') | Where-Object Old -EQ '/angebote/yoga-kurs/'
    Assert-True ($strictRow.Match -eq 'none') 'a higher -MinScore turns a weak match into a gap'

    $simpleOld = Join-Path $work 'simple.xml'
    Set-Content -LiteralPath $simpleOld -Encoding utf8 -Value (New-Sitemap @('/a/', '/b/'))
    $simpleNew = Join-Path $work 'simple.txt'
    Set-Content -LiteralPath $simpleNew -Encoding utf8 -Value @('/a/', '/neu/b/')
    Assert-True ((Invoke-Tool @('-OldSitemap', $simpleOld, '-New', $simpleNew, '-OutDir', (Join-Path $work 'simple'))) -eq 0) 'exit status 0 when every page has a target'
    Assert-True ((Invoke-Tool @('-OldSitemap', (Join-Path $work 'missing.xml'), '-New', $simpleNew, '-OutDir', (Join-Path $work 'x'))) -eq 1) 'exit status 1 when the sitemap is missing'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) test(s) failed"
    exit 1
}
Write-Host 'all tests passed'
exit 0
