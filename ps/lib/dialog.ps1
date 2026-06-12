# Interactive prompt helpers — PowerShell companion to lib/dialog.sh.
#
# Windows does not have the 'dialog' ncurses utility.
# These functions provide equivalent interactive prompts using Read-Host
# and Write-Host, matching the Bash API surface as closely as possible.

function dialog_input {
    param([string]$Title = 'Input', [string]$Prompt = '', [string]$Default = '')
    Write-Host "--- $Title ---"
    $hint = if ($Default) { " [$Default]" } else { '' }
    $val  = Read-Host "$Prompt$hint"
    return if ($val) { $val } else { $Default }
}

function dialog_yesno {
    param([string]$Title = 'Confirm', [string]$Message = 'Proceed?')
    Write-Host "--- $Title ---"
    $resp = Read-Host "$Message [y/N]"
    return ($resp -match '^[yY]$')
}

function dialog_menu {
    param([string]$Title = 'Menu', [string[]]$Items, [string]$Prompt = 'Select')
    Write-Host "--- $Title ---"
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host "  $($i + 1)) $($Items[$i])"
    }
    do {
        $raw = Read-Host "$Prompt (1-$($Items.Count))"
        $sel = [int]$raw - 1
    } while ($sel -lt 0 -or $sel -ge $Items.Count)
    return $Items[$sel]
}

function dialog_password {
    param([string]$Prompt = 'Password')
    $secure = Read-Host $Prompt -AsSecureString
    $ptr    = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

# Stub: progress display using Write-Progress.
function dialog_download_file {
    param([string]$Url, [string]$Output, [string]$Title = 'Downloading')
    Write-Progress -Activity $Title -Status "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Output -UseBasicParsing
    Write-Progress -Activity $Title -Completed
}
