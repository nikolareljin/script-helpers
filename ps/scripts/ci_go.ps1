# SCRIPT: ci_go.ps1
# DESCRIPTION: Run Go CI steps (vet, test) on Windows.
# USAGE: ps\scripts\ci_go.ps1 [-Workdir <path>] [-Quick] [-Module <path>]
# PARAMETERS:
#   -Workdir <path>   Working directory (default: current dir).
#   -Quick            Run go vet only, skip tests.
#   -Module <path>    Specific module path to test.
#   -UseDocker        Run inside Docker Desktop instead of natively.
#   -Image <img>      Docker image override (requires -UseDocker).
#   -Help             Show this help message.
# ----------------------------------------------------
param(
    [string] $Workdir  = '.',
    [switch] $Quick,
    [string] $Module   = './...',
    [switch] $UseDocker,
    [string] $Image    = '',
    [switch] $Help
)

if ($env:CI -eq 'true') { Write-Error "This script is for local use only."; exit 1 }

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path $ScriptDir -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }

$absWorkdir = if ([System.IO.Path]::IsPathRooted($Workdir)) { $Workdir } else { Join-Path $PWD.Path $Workdir }

if ($UseDocker) {
    $img = if ($Image) { $Image } else { $env:CI_GO_IMAGE }
    $cmds = "go vet $Module"
    if (-not $Quick) { $cmds += " && go test $Module" }
    docker run --rm -v "${absWorkdir}:/work" -w /work $img sh -c $cmds
} else {
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Write-Error "go not found on PATH."; exit 1 }
    Push-Location $absWorkdir
    try {
        log_info "go vet $Module"
        go vet $Module
        if (-not $Quick) {
            log_info "go test $Module"
            go test $Module
        }
    } finally { Pop-Location }
}
print_success "Go CI complete."
