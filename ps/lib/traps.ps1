# Exit/error trap helpers — PowerShell companion to lib/traps.sh.
#
# NOTE: PowerShell trap semantics differ from Bash.
# - Use $ErrorActionPreference = 'Stop' to make terminating errors the default.
# - Use try/catch or Register-EngineEvent for cleanup on exit.
# - The setup_exit_trap function registers a script block to run on engine exit.

$_SHLIB_EXIT_HANDLER = $null

function setup_exit_trap {
    param([scriptblock]$Handler)
    $script:_SHLIB_EXIT_HANDLER = $Handler
    Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
        if ($script:_SHLIB_EXIT_HANDLER) {
            & $script:_SHLIB_EXIT_HANDLER
        }
    } | Out-Null
}

function cleanup_on_exit {
    param([scriptblock]$Cleanup)
    setup_exit_trap $Cleanup
}

# Enable strict terminating-error mode — mirrors Bash 'set -e'.
function enable_strict_mode {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
}
