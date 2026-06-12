# Logging and color helpers — PowerShell companion to lib/logging.sh.
# Provides the same function names as the Bash module for cross-platform consistency.

# Detect ANSI support: PS 7+ on any platform, or when TERM indicates color.
$_SHLIB_ANSI = ($PSVersionTable.PSVersion.Major -ge 7) -or ($env:TERM -match 'color')

function _Shlib_WriteColor {
    param([string]$Color, [string]$Message, [switch]$Stderr)
    $map = @{
        Red     = 'Red';     Green   = 'Green'
        Yellow  = 'Yellow';  Blue    = 'Blue'
        Cyan    = 'Cyan';    Magenta = 'Magenta'
        White   = 'White';   Gray    = 'Gray'
    }
    if ($Stderr) {
        [Console]::Error.WriteLine($Message)
        return
    }
    $fc = if ($map.ContainsKey($Color)) { $map[$Color] } else { 'White' }
    Write-Host $Message -ForegroundColor $fc
}

function print_color {
    param([string]$Color, [string]$Text, [string]$Text2 = '', [string]$Color2 = '')
    _Shlib_WriteColor -Color $Color -Message $Text
    if ($Text2) {
        $c2 = if ($Color2) { $Color2 } else { $Color }
        _Shlib_WriteColor -Color $c2 -Message $Text2
    }
}

function print_info    { _Shlib_WriteColor White   "[Info]: $args" }
function print_error   { _Shlib_WriteColor Red    "[Error!]: $args";   try { [Console]::Beep(800, 200) } catch {} }
function print_success { _Shlib_WriteColor Green  "Success [OK]: $args" }
function print_warning { _Shlib_WriteColor Yellow "[Warning!]: $args"; try { [Console]::Beep(800, 200) } catch {} }
function print_line    { Write-Host "----------------------------------------" }

function log_info  { _Shlib_WriteColor Green  "[INFO] $args" -Stderr }
function log_warn  { _Shlib_WriteColor Yellow "[WARN] $args" -Stderr }
function log_error { _Shlib_WriteColor Red    "[ERROR] $args" -Stderr }
function log_debug {
    if ($env:DEBUG -eq 'true') {
        _Shlib_WriteColor Blue "[DEBUG] $args" -Stderr
    }
}

function print_red     { _Shlib_WriteColor Red     "$args" }
function print_green   { _Shlib_WriteColor Green   "$args" }
function print_yellow  { _Shlib_WriteColor Yellow  "$args" }
function print_blue    { _Shlib_WriteColor Blue    "$args" }
