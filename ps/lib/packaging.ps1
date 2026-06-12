# Packaging metadata helpers — PowerShell companion to lib/packaging.sh.
# Linux-specific formats (deb/rpm/arch) are not applicable on Windows.

function join_by {
    param([string]$Separator, [string[]]$Items)
    return ($Items -join $Separator)
}

function quote_args {
    param([string[]]$Items)
    return ($Items | ForEach-Object { '"' + $_ + '"' })
}

function load_packaging_metadata {
    param([string]$MetaFile = 'packaging.json')
    if (-not (Test-Path $MetaFile)) {
        if (Test-Path 'package.json') { $MetaFile = 'package.json' }
        else { throw "No packaging metadata file found (packaging.json / package.json)" }
    }
    return (Get-Content $MetaFile -Raw | ConvertFrom-Json)
}

function get_package_version {
    param([string]$MetaFile = '')
    if ($MetaFile) {
        $meta = load_packaging_metadata $MetaFile
        return $meta.version
    }
    if (Test-Path 'VERSION') { return (Get-Content 'VERSION' -Raw).Trim() }
    $meta = load_packaging_metadata
    return $meta.version
}

function to_camel_case {
    param([string]$Value)
    $parts = $Value -split '[_\-\s]+'
    return ($parts | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }) -join ''
}
