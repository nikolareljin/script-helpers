# Behaviour tests for ps/lib/rust.ps1.
#
# Usage: pwsh -NoProfile -File ps/tests/rust_test.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$originalHelpersDir = $env:SCRIPT_HELPERS_DIR
$env:SCRIPT_HELPERS_DIR = $repo
. (Join-Path $repo 'ps\helpers.ps1')
Import-ScriptHelpers rust

$script:failures = 0
function note([string]$m) { Write-Host "[rust_test.ps1] $m" }
function fail([string]$m) { Write-Host "[rust_test.ps1][ERROR] $m"; $script:failures++ }
function check([string]$label, [bool]$value) { if ($value) { note "  ok  $label" } else { fail $label } }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rust-ps-" + [guid]::NewGuid())
$originalPath = $env:PATH
$originalToolchain = $env:RUST_TOOLCHAIN
New-Item -ItemType Directory -Path $tmp | Out-Null
$distro = Join-Path $tmp 'distro'; $stable = Join-Path $tmp 'stable'; $custom = Join-Path $tmp 'custom'
New-Item -ItemType Directory -Path $distro, $stable, $custom | Out-Null
$distroCargo = Join-Path $distro 'cargo.exe'; $stableCargo = Join-Path $stable 'cargo.exe'; $customCargo = Join-Path $custom 'cargo.exe'
Set-Content -Path $distroCargo -Value 'fake distro cargo'
Set-Content -Path $stableCargo -Value 'fake stable cargo'
Set-Content -Path $customCargo -Value 'fake custom cargo'
$script:stableCargo = $stableCargo
$script:customCargo = $customCargo
function global:rustup {
    param([string]$verb, [string]$flag, [string]$toolchain, [string]$binary)
    if ($verb -ne 'which' -or $flag -ne '--toolchain' -or $binary -ne 'cargo') { return }
    switch ($toolchain) {
        'stable' { $script:stableCargo; return }
        '1.85.0' { $script:customCargo; return }
        default { return }
    }
}
function global:cargo { 'cargo 1.75.0 (distribution)' }

try {
    check 'Import-ScriptHelpers rust exposes the resolver' ([bool](Get-Command rust_toolchain_ci_uses -ErrorAction SilentlyContinue))

    $env:PATH = "$distro$([System.IO.Path]::PathSeparator)$originalPath"
    $result = rust_toolchain_ci_uses
    check 'stable Cargo replaces a PATH shadow' ($result -and $env:PATH.Split([System.IO.Path]::PathSeparator)[0] -eq $stable)

    $env:RUST_TOOLCHAIN = '1.85.0'
    $env:PATH = "$distro$([System.IO.Path]::PathSeparator)$originalPath"
    $result = rust_toolchain_ci_uses
    check 'RUST_TOOLCHAIN selects the named toolchain' ($result -and $env:PATH.Split([System.IO.Path]::PathSeparator)[0] -eq $custom)
    Remove-Item Env:RUST_TOOLCHAIN -ErrorAction SilentlyContinue

    Remove-Item Function:global:rustup
    # PowerShell caches application discovery, so changing PATH alone does not
    # hide the runner's rustup. Mock that lookup for this refusal case only.
    function global:Get-Command {
        param([string]$Name, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)
        if ($Name -eq 'rustup') { return $null }
        Microsoft.PowerShell.Core\Get-Command $Name @Arguments
    }
    $refused = $false
    try { rust_toolchain_ci_uses | Out-Null } catch { $refused = $_.Exception.Message -match 'rustup is not installed' }
    check 'missing rustup is refused with the next action' $refused

    Remove-Item Function:global:Get-Command
    function global:rustup { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$args) }
    $refused = $false
    try { rust_toolchain_ci_uses | Out-Null } catch { $refused = $_.Exception.Message -match 'toolchain install stable' }
    check 'missing selected toolchain is refused with the install command' $refused
}
finally {
    $env:PATH = $originalPath
    if ($null -eq $originalToolchain) { Remove-Item Env:RUST_TOOLCHAIN -ErrorAction SilentlyContinue } else { $env:RUST_TOOLCHAIN = $originalToolchain }
    if ($null -eq $originalHelpersDir) { Remove-Item Env:SCRIPT_HELPERS_DIR -ErrorAction SilentlyContinue } else { $env:SCRIPT_HELPERS_DIR = $originalHelpersDir }
    Remove-Item Function:global:rustup -ErrorAction SilentlyContinue
    Remove-Item Function:global:cargo -ErrorAction SilentlyContinue
    Remove-Item Function:global:Get-Command -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmp
}

if ($script:failures -eq 0) { note 'ALL PASSED'; exit 0 }
note "$($script:failures) FAILURE(S)"
exit 1
