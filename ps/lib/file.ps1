# File and directory helpers — PowerShell companion to lib/file.sh.

function command_exists {
    param([string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

function file_exists     { param([string]$Path); return (Test-Path $Path -PathType Leaf) }
function directory_exists { param([string]$Path); return (Test-Path $Path -PathType Container) }

function create_directory {
    param([string]$Path)
    if (Test-Path $Path -PathType Container) {
        Write-Host "Directory $Path already exists."
        return
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Write-Host "Directory $Path created."
}

function ensure_dir {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function download_file {
    param(
        [string]$Url,
        [string]$Output = ''
    )
    if (-not $Output) {
        $Output = [System.IO.Path]::GetFileName(([uri]$Url).LocalPath)
    }
    Write-Host "[script-helpers] Downloading $Url -> $Output"
    Invoke-WebRequest -Uri $Url -OutFile $Output -UseBasicParsing
}

function verify_checksum {
    param(
        [string]$FilePath,
        [string]$ExpectedHash,
        [string]$Algorithm = 'SHA256'
    )
    $actual = (Get-FileHash -Path $FilePath -Algorithm $Algorithm).Hash
    if ($actual -eq $ExpectedHash.ToUpper()) {
        if (Get-Command print_success -ErrorAction SilentlyContinue) { print_success "Checksum OK: $FilePath" }
        else { Write-Host "Checksum OK: $FilePath" }
        return $true
    } else {
        if (Get-Command print_error -ErrorAction SilentlyContinue) { print_error "Checksum MISMATCH for $FilePath" }
        else { Write-Error "Checksum MISMATCH for $FilePath" }
        return $false
    }
}
