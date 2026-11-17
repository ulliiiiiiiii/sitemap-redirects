# sitemap-redirects

When a website moves to a new CMS, most addresses change. Every old link in search results, bookmarks and on
other sites then ends in a 404, unless the server redirects it. The old sitemap already lists every address
that needs a new home. sitemap-redirects compares it with the new addresses and writes the redirects.

For each old address it looks, in this order, for the same path, the same page name in another folder and a
similar page name. Where two new pages share a name or nothing fits, it does not guess: the address goes into
the report so you can decide by hand.

## Usage

```powershell
./sitemap-redirects.ps1 -OldSitemap https://www.example.org/sitemap_index.xml -New new-urls.txt
./sitemap-redirects.ps1 -OldSitemap old-sitemap.xml -New https://new.example.org/sitemap.xml -Format nginx
./sitemap-redirects.ps1 -OldSitemap old-sitemap.xml -New new-urls.txt -MinScore 0.9   # stricter on similar names
```

`-New` takes a sitemap or a text file with one address or path per line. A sitemap index is followed into its
sitemaps.

```text
11 old addresses: 4 unchanged, 5 redirected (3 same name, 1 similar, 1 spelling), 1 ambiguous, 1 without a target.
Rules:  redirects/redirects.htaccess
Report: redirects/report.csv
Check the rows marked ambiguous or none in the report and decide by hand.
```

`redirects/redirects.htaccess`:

```apache
RedirectMatch 301 "^/news/new-courses/?$" "/club/news/new-courses/"
RedirectMatch 301 "^/about-us/?$" "/club/about-us/"
RedirectMatch 301 "^/offers/fitness/?$" "/sports/fitness/"
RedirectMatch 301 "^/offers/yoga-class/?$" "/sports/yogaclass/"
RedirectMatch 301 "^/courses/zumba\.html/?$" "/courses/zumba/"
```

`redirects/report.csv` lists every old address with its target, the kind of match and a score (excerpt):

```text
"Old","New","Match","Score"
"/offers/yoga-class/","/sports/yogaclass/","similar","0.9"
"/old-page.html","","none","0.22"
"/info/","/team/info/ | /help/info/","ambiguous","1"
"/courses/zumba.html","/courses/zumba/","normalized","1"
```

Comparisons ignore upper and lower case, a trailing slash, endings such as `.html` and the spelling of umlauts,
so `über-uns` finds `ueber-uns`. `normalized` means only the spelling differs. The rules match the path with and
without a trailing slash.

Exit status: 0 when every old address has a target, 2 when some need a decision, 1 on errors.

A real sitemap index with twelve sitemaps and 721 addresses took under 20 seconds, downloads included.

## Requirements

PowerShell 7 on Windows, macOS or Linux. No modules needed.

## Tests

```powershell
./tests/run-tests.ps1
```

## License

MIT
