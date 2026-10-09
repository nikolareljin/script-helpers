param([Parameter(Mandatory)][string]$OutputPath)
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $Root 'ps/lib/android.ps1')
if (-not (android_generate_keystore $OutputPath)) { exit 1 }
