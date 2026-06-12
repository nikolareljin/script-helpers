# Exit/error trap helpers — PowerShell companion to lib/traps.sh.
#
# NOTE: PowerShell trap semantics differ from Bash.
# - Use $ErrorActionPreference = 'Stop' to make terminating errors the default.
# - Use try/catch or Register-EngineEvent for cleanup on exit.
# - The setup_exit_trap function registers a script block to run on engine exit.

$_SHLIB_EXIT_HANDLER      = $null
$_SHLIB_EXIT_SUBSCRIPTION = $null

function setup_exit_trap {
    param([scriptblock]$Handler)
    $script:_SHLIB_EXIT_HANDLER = $Handler
    if ($script:_SHLIB_EXIT_SUBSCRIPTION) {
        Unregister-Event -SubscriptionId $script:_SHLIB_EXIT_SUBSCRIPTION -ErrorAction SilentlyContinue
    }
    $script:_SHLIB_EXIT_SUBSCRIPTION = (Register-EngineEvent `
        -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) `
        -Action {
            if ($script:_SHLIB_EXIT_HANDLER) { & $script:_SHLIB_EXIT_HANDLER }
        }
    ).Id
}

function cleanup_on_exit {
    param([scriptblock]$Cleanup)
    setup_exit_trap $Cleanup
}

# Enable strict terminating-error mode — mirrors Bash 'set -e'.
# Writes ErrorActionPreference into the immediate caller's scope (Scope 1) so it
# applies to that script without leaking into the wider session.
function enable_strict_mode {
    Set-Variable -Name 'ErrorActionPreference' -Value 'Stop' -Scope 1
    Set-StrictMode -Version Latest
}
