# Behaviour tests for templates/dev-cli/cli.ps1, the PowerShell ./dev.
#
# CI parsed only ps/, never the template, and nothing ran it. This drives it in
# a scratch repository: exit codes (2 unknown, 3 not applicable), a verb of the
# repository's own, and the service verbs handed to bash and lib/service.sh.
#
# Usage: pwsh -NoProfile -File ps/tests/dev_cli_template_test.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path

$script:failures = 0
function note([string]$m) { Write-Host "[dev_cli_template_test.ps1]   ok  $m" }
function fail([string]$m) { Write-Host "[dev_cli_template_test.ps1][ERROR] $m"; $script:failures++ }
# $r, when given, is a dev run: its output is printed on a failure, which is
# where the reason is.
function check([string]$what, $want, $got, $r = $null) {
    if ("$want" -eq "$got") { note $what; return }
    fail "${what}: expected [$want], got [$got]"
    if ($r) { Write-Host "    output: $($r.out)" }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("devcli-ps-" + [guid]::NewGuid())
$repo = Join-Path $tmp 'repo'
New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force | Out-Null
try {
    & git -C $repo init -q . | Out-Null
    foreach ($f in 'cli.ps1', '_bootstrap.ps1', 'cli.sh', '_bootstrap.sh') {
        Copy-Item (Join-Path $root "templates/dev-cli/$f") (Join-Path $repo 'scripts')
    }
    Copy-Item (Join-Path $root 'templates/dev-cli/dev.ps1') $repo
    $env:SCRIPT_HELPERS_DIR = $root

    # Each run is a fresh pwsh, as a person runs it; its exit code is the result.
    function dev([string[]]$a) {
        $out = & pwsh -NoProfile -File (Join-Path $repo 'dev.ps1') @a 2>&1 | Out-String
        return @{ rc = $LASTEXITCODE; out = $out }
    }

    $r = dev @()
    check './dev.ps1 alone shows the verbs and exits 0' 0 $r.rc $r
    if ($r.out -notmatch 'Services') { fail "the verb list has no Services section: $($r.out)" } else { note 'the verb list has the service verbs' }
    $r = dev @('bogus')
    check './dev.ps1 bogus exits 2' 2 $r.rc $r
    $r = dev @('build')
    check 'build with nothing to build is not applicable (3)' 3 $r.rc $r
    foreach ($v in 'start', 'restart', 'status', 'stop') {
        $r = dev @($v)
        check "$v with no services is not applicable (3)" 3 $r.rc $r
    }

    Set-Content -Path (Join-Path $repo 'scripts/project.ps1') -Value @(
        'function Project-Hello { Write-Host "hello: $($args -join '' '')" }'
    )
    $r = dev @('hello', 'a', '--b')
    check './dev.ps1 hello runs Project-Hello and exits 0' 0 $r.rc $r
    if ($r.out -notmatch 'hello: a --b') { fail "Project-Hello did not get its arguments as typed: $($r.out)" } else { note 'with its arguments as typed' }
    $r = dev @('hello', '--help')
    if ($r.out -notmatch 'hello: --help') { fail "--help after a repository verb went to the template, not the verb: $($r.out)" } else { note "--help after a repository verb is that verb's" }
    $r = dev @('--help')
    if ($r.out -notmatch '(?m)^  hello') { fail "--help does not list the repository's verb: $($r.out)" } else { note "--help lists the repository's own verbs" }

    # Services are lib/service.sh's: with SVC_BACKEND in project.sh, through bash.
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        New-Item -ItemType SymbolicLink -Path (Join-Path $repo 'scripts/script-helpers') -Target $root | Out-Null
        Set-Content -Path (Join-Path $repo 'scripts/project.sh') -Value @(
            'export SVC_BACKEND=proc',
            'SVC_PROCS=("web:sleep 300")'
        )
        $r = dev @('status')
        check 'status of a stopped proc service, through bash: 1' 1 $r.rc $r
        if ($r.out -notmatch 'web: stopped') { fail "status was not lib/service.sh's: $($r.out)" } else { note "status is lib/service.sh's" }
        $r = dev @('start')
        check 'start through bash: 0 (no phantom empty argument)' 0 $r.rc $r
        $r = dev @('stop')
        check 'stop through bash: 0' 0 $r.rc $r
        if ($r.out -notmatch 'stopped web') { fail "stop did not stop the service: $($r.out)" } else { note 'stop stopped it' }
    } else {
        note 'SKIP service verbs: no bash'
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { Write-Host "[dev_cli_template_test.ps1] FAILED: $script:failures"; exit 1 }
Write-Host '[dev_cli_template_test.ps1] ALL PASSED'
exit 0
