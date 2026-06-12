# SCRIPT: ci_node.ps1
# DESCRIPTION: Run Node.js CI steps (install, lint, test, build) on Windows.
# USAGE: ps\scripts\ci_node.ps1 [-Workdir <path>] [-NoInstall] [-SkipLint] [-SkipTest] [-SkipBuild]
# PARAMETERS:
#   -Workdir <path>     Working directory for npm commands (default: current dir).
#   -NoInstall          Skip npm install step.
#   -SkipLint           Skip lint command.
#   -SkipTest           Skip test command.
#   -SkipBuild          Skip build command.
#   -InstallCmd <cmd>   Override install command (default: npm ci).
#   -LintCmd <cmd>      Override lint command (default: npm run lint).
#   -TestCmd <cmd>      Override test command (default: npm run test).
#   -BuildCmd <cmd>     Override build command (default: npm run build).
#   -UseDocker          Run inside Docker Desktop instead of natively.
#   -Image <img>        Docker image override (requires -UseDocker).
#   -Help               Show this help message.
# ----------------------------------------------------
param(
    [string]  $Workdir    = '.',
    [switch]  $NoInstall,
    [switch]  $SkipLint,
    [switch]  $SkipTest,
    [switch]  $SkipBuild,
    [string]  $InstallCmd = 'npm ci',
    [string]  $LintCmd    = 'npm run lint',
    [string]  $TestCmd    = 'npm run test',
    [string]  $BuildCmd   = 'npm run build',
    [switch]  $UseDocker,
    [string]  $Image      = '',
    [switch]  $Help
)

if ($env:CI -eq 'true') { Write-Error "This script is for local use only."; exit 1 }

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path (Split-Path $ScriptDir -Parent) -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging ci_defaults

if ($Help) { display_help $PSCommandPath; exit 0 }

$absWorkdir = Resolve-Path $Workdir -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path
if (-not $absWorkdir) { $absWorkdir = Join-Path $PWD.Path $Workdir }

function _Run {
    param([string]$Cmd)
    if ($UseDocker) {
        $img = if ($Image) { $Image } elseif ($env:CI_NODE_IMAGE) { $env:CI_NODE_IMAGE } else { 'node:22-alpine' }
        docker run --rm -v "${absWorkdir}:/work" -w /work $img sh -c $Cmd
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        Push-Location $absWorkdir
        try {
            $exe, $rest = $Cmd -split '\s+', 2
            $argList = if ($rest) { $rest -split '\s+' } else { @() }
            & $exe @argList
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        } finally { Pop-Location }
    }
}

log_info "Node CI — workdir: $absWorkdir"
if (-not $NoInstall) { log_info "Install: $InstallCmd";  _Run $InstallCmd }
if (-not $SkipLint)  { log_info "Lint:    $LintCmd";     _Run $LintCmd    }
if (-not $SkipTest)  { log_info "Test:    $TestCmd";      _Run $TestCmd    }
if (-not $SkipBuild) { log_info "Build:   $BuildCmd";    _Run $BuildCmd   }
print_success "Node CI complete."
