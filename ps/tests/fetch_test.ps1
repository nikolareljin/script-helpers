# Behaviour tests for ps/lib/fetch.ps1.
#
# Invoke-WebRequest is a stub that writes a partial file and throws for the
# first $script:failFirst calls, then writes the asset. Nothing is fetched.
#
# Usage: pwsh -NoProfile -File ps/tests/fetch_test.ps1
$ErrorActionPreference = 'Stop'
$lib = Join-Path (Join-Path $PSScriptRoot '..') 'lib'
. (Join-Path $lib 'logging.ps1')
. (Join-Path $lib 'fetch.ps1')

$script:failures = 0
function note([string]$m) { Write-Host "[fetch_test.ps1] $m" }
function check([string]$label, $want, $got) {
    if ("$want" -eq "$got") { note "  ok  $label" } else { Write-Host "[fetch_test.ps1][ERROR] ${label}: expected [$want], got [$got]"; $script:failures++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fetch-ps-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null

$script:calls = 0
$script:failFirst = 0
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
    $script:calls++
    if ($script:failFirst -lt 0 -or $script:calls -le $script:failFirst) {
        Set-Content -Path $OutFile -Value 'partial'
        throw 'Unable to connect to the remote server'
    }
    Set-Content -Path $OutFile -Value 'asset'
}

try {
    $out = Join-Path $tmp 'a.bin'

    $script:calls = 0; $script:failFirst = 2
    $rc = fetch_to_file -Label 't' -Url 'https://github.com/o/r/releases/download/v1/a' -OutFile $out -DelaySeconds 0
    check 'two failures, then the file on the third attempt' '0:3:asset' "${rc}:$($script:calls):$((Get-Content $out -Raw).Trim())"

    Remove-Item $out -Force
    $script:calls = 0; $script:failFirst = -1
    $rc = fetch_to_file -Label 't' -Url 'https://github.com/o/r/releases/download/v1/a' -OutFile $out -DelaySeconds 0 2>$null
    check 'every attempt fails: 1, three attempts, no partial file left' '1:3:False' "${rc}:$($script:calls):$(Test-Path $out)"

    check 'an empty URL is refused' '2' "$(fetch_to_file -Label 't' -Url '' -OutFile $out 2>$null)"
    check 'the host of a URL' 'github.com' (fetch_url_host 'https://github.com/o/r')
    check 'an unparseable URL has no host printed' '(unknown host)' (fetch_url_host 'not a url@secret')
    $n = '(URL not shown)'
    foreach ($row in @(
        @('https://user:pass@example.com/a', $n),
        @('https://token@example.com/a', $n),
        @('HTTPS://tok@Example.com', $n),
        @('user:pass@example.com/a', $n),
        @('ht!tp://x@y', $n),
        @('ftp://example.com/a', $n),
        @('https://', $n),
        @('https://example.com/a@b', 'https://example.com/a@b'),
        @('https://example.com/a?u=x@y', 'https://example.com/a?u=x@y'),
        @('https://github.com/o/r', 'https://github.com/o/r'))) {
        check "display of $($row[0])" $row[1] (fetch_url_display $row[0])
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { note "$($script:failures) failure(s)"; exit 1 }
note 'all passed'
