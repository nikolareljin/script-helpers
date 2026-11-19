# fetch: download one release asset to a file, with retries and a clear error.
# PowerShell companion to lib/fetch.sh.
#
# Invoke-WebRequest has no retry option in Windows PowerShell 5.1, so the
# retry is a loop here: 3 attempts, 2 seconds apart. A failed download deletes
# the output file, so a partial file is never left for the caller to check or
# unpack. Callers still verify the checksum.
#
# Requires: logging (log_error; plain error stream without it)

# Usage: fetch_url_host -Url <url>
# Returns: the host of an absolute URL (never its user info), else '(unknown host)'.
# Output: none.
function fetch_url_host {
    param([string]$Url)
    $parsed = $null
    if ([uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed) -and $parsed.Host) { return $parsed.Host }
    return '(unknown host)'
}

# Usage: fetch_url_display -Url <url>
# Returns: the URL when it is an absolute http or https URL whose authority (from
#   '://' to the first '/', '?' or '#') has no '@'; else '(URL not shown)'. Fails
#   closed: user info, another or no scheme, or a URL that does not parse is
#   never shown. Same rule as lib/fetch.sh.
# Output: none.
function fetch_url_display {
    param([string]$Url)
    $hidden = '(URL not shown)'
    if (-not $Url) { return $hidden }
    $i = $Url.IndexOf('://')
    if ($i -lt 1) { return $hidden }
    $scheme = $Url.Substring(0, $i).ToLowerInvariant()
    if ($scheme -ne 'http' -and $scheme -ne 'https') { return $hidden }
    $rest = $Url.Substring($i + 3)
    $j = $rest.IndexOfAny([char[]]@('/', '?', '#'))
    $auth = if ($j -ge 0) { $rest.Substring(0, $j) } else { $rest }
    if (-not $auth -or $auth.Contains('@')) { return $hidden }
    $parsed = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed)) { return $hidden }
    if ($parsed.UserInfo) { return $hidden }
    return $Url
}

# Usage: fetch_to_file -Label <name> -Url <url> -OutFile <path> [-Attempts 3] [-DelaySeconds 2]
# Downloads <url> to <path>, retrying any error. On failure the file is deleted
# and one error line names the label, the host, the attempts and the last error.
# Returns: 0 downloaded; 1 every attempt failed; 2 an empty label, URL or path.
# Output: error line on failure (log_error when logging is loaded).
function fetch_to_file {
    param(
        [string]$Label,
        [string]$Url,
        [string]$OutFile,
        [int]$Attempts = 3,
        [int]$DelaySeconds = 2
    )
    if (-not $Label -or -not $Url -or -not $OutFile) {
        _fetch_err 'fetch_to_file: usage: fetch_to_file -Label <name> -Url <url> -OutFile <path>'
        return 2
    }
    if ($Attempts -lt 1) { $Attempts = 1 }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        # Windows PowerShell 5.1 does not negotiate TLS 1.2 by default.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $last = ''
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # the progress bar makes this ~10x slower
    try {
        for ($i = 1; $i -le $Attempts; $i++) {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop | Out-Null
                return 0
            } catch {
                $last = $_.Exception.Message
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                if ($i -lt $Attempts -and $DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
            }
        }
    } finally { $ProgressPreference = $prev }
    _fetch_err "${Label}: download failed from $(fetch_url_host $Url) after $Attempts attempts: $last; URL $(fetch_url_display $Url)"
    return 1
}

function _fetch_err([string]$m) {
    if (Get-Command log_error -ErrorAction SilentlyContinue) { log_error $m } else { [Console]::Error.WriteLine("[ERROR] $m") }
}
