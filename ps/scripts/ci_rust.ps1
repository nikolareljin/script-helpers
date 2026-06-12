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
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path $ScriptDir -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }

$absWorkdir = if ([System.IO.Path]::IsPathRooted($Workdir)) { $Workdir } else { Join-Path $PWD.Path $Workdir }
$manifestFlag = if ($Manifest) { "--manifest-path $Manifest" } else { '' }

if ($UseDocker) {
    $img  = if ($Image) { $Image } else { $env:CI_RUST_IMAGE }
    $cmds = "cargo check $manifestFlag"
    if (-not $Quick) { $cmds += " && cargo clippy $manifestFlag && cargo test $manifestFlag" }
    docker run --rm -v "${absWorkdir}:/work" -w /work $img sh -c $cmds
} else {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { Write-Error "cargo not found on PATH. Install Rust via https://rustup.rs"; exit 1 }
    Push-Location $absWorkdir
    try {
        log_info "cargo check"
        Invoke-Expression "cargo check $manifestFlag"
        if (-not $Quick) {
            log_info "cargo clippy"
            Invoke-Expression "cargo clippy $manifestFlag"
            log_info "cargo test"
            Invoke-Expression "cargo test $manifestFlag"
        }
    } finally { Pop-Location }
}
print_success "Rust CI complete."
