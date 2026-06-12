# SCRIPT: ci_rust.ps1
# DESCRIPTION: Run Rust CI steps (check, clippy, test) on Windows.
# USAGE: ps\scripts\ci_rust.ps1 [-Workdir <path>] [-Quick] [-Manifest <path>]
# PARAMETERS:
#   -Workdir <path>     Working directory (default: current dir).
#   -Quick              Run cargo check only, skip clippy and tests.
#   -Manifest <path>    Path to Cargo.toml (default: Cargo.toml in workdir).
#   -UseDocker          Run inside Docker Desktop instead of natively.
#   -Image <img>        Docker image override (requires -UseDocker).
#   -Help               Show this help message.
# ----------------------------------------------------
param(
    [string] $Workdir  = '.',
    [switch] $Quick,
    [string] $Manifest = '',
    [switch] $UseDocker,
    [string] $Image    = '',
    [switch] $Help
)

if ($env:CI -eq 'true') { Write-Error "This script is for local use only."; exit 1 }

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging docker ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }

$absWorkdir = if ([System.IO.Path]::IsPathRooted($Workdir)) { $Workdir } else { Join-Path $PWD.Path $Workdir }
if (-not (Test-Path $absWorkdir -PathType Container)) { Write-Error "Working directory not found: $absWorkdir"; exit 1 }
$cargoArgs  = if ($Manifest) { @('--manifest-path', $Manifest) } else { @() }

if ($UseDocker) {
    if (-not (check_docker)) { exit 1 }
    $img     = if ($Image) { $Image } elseif ($env:CI_RUST_IMAGE) { $env:CI_RUST_IMAGE } else { 'rust:latest' }
    $volArgs = @('run', '--rm', '-v', "${absWorkdir}:/work", '-w', '/work', $img)
    log_info "cargo check"
    docker @volArgs cargo check @cargoArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not $Quick) {
        log_info "cargo clippy"
        docker @volArgs cargo clippy @cargoArgs
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        log_info "cargo test"
        docker @volArgs cargo test @cargoArgs
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
} else {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { Write-Error "cargo not found on PATH. Install Rust via https://rustup.rs"; exit 1 }
    Push-Location $absWorkdir
    try {
        log_info "cargo check"
        cargo check @cargoArgs
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        if (-not $Quick) {
            log_info "cargo clippy"
            cargo clippy @cargoArgs
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            log_info "cargo test"
            cargo test @cargoArgs
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    } finally { Pop-Location }
}
print_success "Rust CI complete."
