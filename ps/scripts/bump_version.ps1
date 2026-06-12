# SCRIPT: bump_version.ps1
# DESCRIPTION: Bump the semantic version in the VERSION file.
# USAGE: ps\scripts\bump_version.ps1 <major|minor|patch> [-File <path>]
# PARAMETERS:
#   BumpType         Required. One of: major, minor, patch.
#   -File <path>     Path to VERSION file (default: VERSION in project root).
#   -Help            Show this help message.
# ----------------------------------------------------
param(
    [Parameter(Position=0)]
    [ValidateSet('major','minor','patch')]
    [string] $BumpType,
    [string] $File = 'VERSION',
    [switch] $Help
)

$ScriptDir = $PSScriptRoot
$env:SCRIPT_HELPERS_DIR = if ($env:SCRIPT_HELPERS_DIR) { $env:SCRIPT_HELPERS_DIR } else { Split-Path $ScriptDir -Parent }
. (Join-Path $env:SCRIPT_HELPERS_DIR 'ps\helpers.ps1')
Import-ScriptHelpers help logging version env

if ($Help -or -not $BumpType) { display_help $PSCommandPath; exit 0 }

version_bump -BumpType $BumpType -VersionFile $File
