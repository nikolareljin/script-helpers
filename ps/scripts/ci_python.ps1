# SCRIPT: ci_python.ps1
# DESCRIPTION: Run Python CI steps (venv, install, test) on Windows.
# USAGE: ps\scripts\ci_python.ps1 [-Workdir <path>] [-SkipTest] [-Quick]
# PARAMETERS:
#   -Workdir <path>   Working directory (default: current dir).
#   -SkipTest         Skip pytest step.
#   -Quick            Skip install, only run tests.
#   -PythonBin <bin>  Python binary to use (auto-detected by default).
#   -TestCmd <cmd>    Override test command (default: pytest).
#   -UseDocker        Run inside Docker Desktop instead of natively.
#   -Image <img>      Docker image override (requires -UseDocker).
#   -Help             Show this help message.
# ----------------------------------------------------
param(
    [string] $Workdir   = '.',
    [switch] $SkipTest,
    [switch] $Quick,
    [string] $PythonBin = '',
    [string] $TestCmd   = 'pytest',
    [switch] $UseDocker,
    [string] $Image     = '',
    [switch] $Help
)

if ($env:CI -eq 'true') { Write-Error "This script is for local use only."; exit 1 }

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging python ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }

$absWorkdir = if ([System.IO.Path]::IsPathRooted($Workdir)) { $Workdir } else { Join-Path $PWD.Path $Workdir }

if ($UseDocker) {
    $img = if ($Image) { $Image } elseif ($env:CI_PYTHON_IMAGE) { $env:CI_PYTHON_IMAGE } else { 'python:3-slim' }
    $parts = @()
    if (-not $Quick) { $parts += 'pip install -r requirements.txt' }
    if (-not $SkipTest) { $parts += $TestCmd }
    if ($parts.Count -gt 0) {
        docker run --rm -v "${absWorkdir}:/work" -w /work $img sh -c ($parts -join ' && ')
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
} else {
    $py = python_resolve_3 $PythonBin
    if (-not $py) { Write-Error "Python 3.8+ not found on PATH."; exit 1 }
    log_info "Using Python: $py"

    $venv = Join-Path $absWorkdir '.venv'
    $venvPy = python_ensure_venv $py $venv
    activate_venv $venv

    if (-not $Quick) {
        $req = Join-Path $absWorkdir 'requirements.txt'
        if (Test-Path $req) {
            log_info "Installing dependencies from requirements.txt"
            & $venvPy -m pip install -r $req --quiet
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }
    if (-not $SkipTest) {
        log_info "Running: $TestCmd"
        Push-Location $absWorkdir
        try {
            $exe, $rest = $TestCmd -split '\s+', 2
            $argList = if ($rest) { $rest -split '\s+' } else { @() }
            & $exe @argList
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally { Pop-Location }
    }
}
print_success "Python CI complete."
