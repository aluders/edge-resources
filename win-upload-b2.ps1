# =============================================================================
# backblaze.ps1  v1.0
# -----------------------------------------------------------------------------
# B2 Upload Automation Script (Windows / PowerShell)
#
# Interactive PowerShell port of backblaze.sh. Run with:
#   irm backblaze.vcc.net | iex
#
# Two backends:
#   rclone  -- multipart / chunked upload (recommended for large files / NAS)
#   native  -- B2 b2_upload_file over HttpClient (single request, max 5 GB/file)
#
# MODE BEHAVIOR:
#   auto    Prefer rclone. If missing, download portable rclone to
#           %LOCALAPPDATA%\EdgeTools\backblaze\rclone\. Fall back to native.
#   rclone  rclone only; download if needed, stop if unavailable
#   native  B2 native API only (no rclone download)
#
# PROMPTS:
#   App Key ID, App Key (hidden), bucket id or name, remote prefix,
#   local file or folder, mode. Advanced prompt covers bucket name,
#   auto cutoff, skip hash, chunk size, transfers, and no-install.
#
# REQUIREMENTS / DEPENDENCIES
#   Windows PowerShell 5.1 or PowerShell 7+
#   HTTPS access to api.backblazeb2.com (and downloads.rclone.org for rclone)
#   No jq / python / shasum needed -- JSON, SHA-1, and URL encoding are native
#
# DATA
#   %LOCALAPPDATA%\EdgeTools\backblaze\rclone\rclone.exe   portable rclone
#   %LOCALAPPDATA%\EdgeTools\backblaze\rclone.conf         empty; credentials
#                                                          go to rclone via env
#
# NOTES
#   Script is ASCII-only so it survives irm | iex without charset issues.
#   Uses 'return', never 'exit', so it will not close the caller's window.
#
# CHANGELOG
#   1.0  Initial PowerShell port of backblaze.sh v1.6 (interactive only)
# =============================================================================

& {

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ---- CONFIG -----------------------------------------------------------------
$Version          = '1.0'
$DefaultMode      = 'auto'
$DefaultCutoff    = 209715200          # 200 MiB: auto mode warns above this on native
$DefaultChunk     = '96M'
$DefaultTransfers = 4
$RcloneUpCutoff   = '200M'
$NativeMaxBytes   = 5000000000         # B2 single-request upload limit
$DataDir          = Join-Path $env:LOCALAPPDATA 'EdgeTools\backblaze'
$RcloneDir        = Join-Path $DataDir 'rclone'
$RcloneConf       = Join-Path $DataDir 'rclone.conf'
$B2AuthUrl        = 'https://api.backblazeb2.com/b2api/v2/b2_authorize_account'
# -----------------------------------------------------------------------------

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$IsPS7 = $PSVersionTable.PSVersion.Major -ge 6
$B2    = @{ Auth = $null; BucketId = ''; BucketName = ''; UploadUrl = ''; UploadToken = '' }
$Http  = New-Object System.Net.Http.HttpClient
$Http.Timeout = [Threading.Timeout]::InfiniteTimeSpan

# ---- output helpers ----------------------------------------------------------
function Write-Ok   ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Info ([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Warn ([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err  ([string]$m) { Write-Host "[x] $m" -ForegroundColor Red }

# ---- prompt helpers ----------------------------------------------------------
function Read-Default([string]$Prompt, [string]$Default) {
    $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $v = Read-Host $label
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    $v.Trim()
}

function Read-Required([string]$Prompt) {
    do { $v = (Read-Host $Prompt).Trim() } while (-not $v)
    $v
}

function Read-Secret([string]$Prompt) {
    do {
        $s = Read-Host $Prompt -AsSecureString
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
        try     { $v = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } while (-not $v)
    $v.Trim()
}

function Read-YesNo([string]$Prompt, [bool]$Default) {
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $v = Read-Host "$Prompt ($hint)"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    $v.Trim() -match '^(y|yes)$'
}

function Read-LocalPath {
    while ($true) {
        # Strip quotes added by drag-and-drop / "Copy as path"
        $p = (Read-Host 'Local file or folder path').Trim().Trim('"').Trim("'")
        if ($p -and (Test-Path -LiteralPath $p)) {
            return (Resolve-Path -LiteralPath $p).ProviderPath
        }
        Write-Warn "Not a file or directory: $p"
    }
}

function Format-Prefix([string]$p) {
    if (-not $p) { return '' }
    $p = $p.Replace('\', '/').TrimStart('/')
    if ($p -and -not $p.EndsWith('/')) { $p += '/' }
    $p
}

# ---- file helpers --------------------------------------------------------------
function Get-SourceFiles {
    if ($IsDir) {
        Get-ChildItem -LiteralPath $LocalPath -File -Recurse -Force | Sort-Object FullName
    } else {
        Get-Item -LiteralPath $LocalPath -Force
    }
}

function Get-RemoteName($File) {
    if ($IsDir) {
        $root = $LocalPath.TrimEnd('\', '/')
        $rel  = $File.FullName.Substring($root.Length).TrimStart('\', '/')
    } else {
        $rel = $File.Name
    }
    $Prefix + $rel.Replace('\', '/')
}

function ConvertTo-B2Name([string]$Name) {
    # B2 wants UTF-8 percent-encoding; '/' stays literal
    ($Name -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
}

function ConvertTo-ArgString([string[]]$Items) {
    # Windows command-line quoting for ProcessStartInfo.Arguments
    ($Items | ForEach-Object {
        if ($_ -and $_ -notmatch '[\s"]') { $_ }
        else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

# ---- B2 API ------------------------------------------------------------------
function Get-B2ErrorMessage($ErrRecord) {
    $msg = $ErrRecord.ErrorDetails.Message
    if ($msg) {
        try { $j = $msg | ConvertFrom-Json; if ($j.message) { return $j.message } } catch { }
        return $msg
    }
    $ErrRecord.Exception.Message
}

function Invoke-B2Rest([hashtable]$Params) {
    # PS7 rejects B2's raw (scheme-less) Authorization tokens without this
    if ($IsPS7) { $Params.SkipHeaderValidation = $true }
    $Params.UseBasicParsing = $true
    Invoke-RestMethod @Params
}

function Invoke-B2Api([string]$Name, [hashtable]$Body) {
    try {
        Invoke-B2Rest @{
            Uri         = "$($B2.Auth.apiUrl)/b2api/v2/$Name"
            Method      = 'Post'
            Headers     = @{ Authorization = $B2.Auth.authorizationToken }
            ContentType = 'application/json'
            Body        = ($Body | ConvertTo-Json -Compress)
        }
    } catch {
        throw "$Name failed: $(Get-B2ErrorMessage $_)"
    }
}

function Connect-B2 {
    Write-Info 'Authorizing B2 account...'
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${AppId}:${AppKey}"))
    try {
        $B2.Auth = Invoke-B2Rest @{ Uri = $B2AuthUrl; Method = 'Get'; Headers = @{ Authorization = "Basic $basic" } }
    } catch {
        throw "Authorization failed: $(Get-B2ErrorMessage $_)"
    }
    # Restricted keys often include the allowed bucket name/id
    $allowed = $B2.Auth.allowed
    if ($allowed) {
        if (-not $B2.BucketName -and $allowed.bucketName) { $B2.BucketName = $allowed.bucketName }
        if ($allowed.bucketId) { $B2.BucketId = $allowed.bucketId }
    }
}

function Resolve-B2Bucket {
    # BucketRef may be an id or a name. Native wants id; rclone wants name.
    if ($BucketRef -match '^[0-9a-fA-F]{16,}$') {
        if (-not $B2.BucketId) { $B2.BucketId = $BucketRef }
    } elseif (-not $B2.BucketName) {
        $B2.BucketName = $BucketRef
    }
    if ($B2.BucketName -and $B2.BucketId) { return }

    try {
        $buckets = @((Invoke-B2Api 'b2_list_buckets' @{ accountId = $B2.Auth.accountId }).buckets)
    } catch {
        Write-Warn $_.Exception.Message
        return
    }
    if (-not $B2.BucketName -and $B2.BucketId) {
        $m = $buckets | Where-Object { $_.bucketId -eq $B2.BucketId } | Select-Object -First 1
        if ($m) { $B2.BucketName = $m.bucketName }
    }
    if (-not $B2.BucketId -and $B2.BucketName) {
        $m = $buckets | Where-Object { $_.bucketName -eq $B2.BucketName } | Select-Object -First 1
        if ($m) { $B2.BucketId = $m.bucketId }
    }
}

function Update-UploadUrl {
    $r = Invoke-B2Api 'b2_get_upload_url' @{ bucketId = $B2.BucketId }
    if (-not $r.uploadUrl -or -not $r.authorizationToken) { throw 'Failed to get upload URL.' }
    $B2.UploadUrl   = $r.uploadUrl
    $B2.UploadToken = $r.authorizationToken
}

# ---- native backend --------------------------------------------------------------
function Send-B2File($File, [string]$RemoteName) {
    $size = $File.Length
    Write-Info "-> $RemoteName  ($size bytes)  [native]"
    if ($size -gt $NativeMaxBytes) {
        Write-Err '     Larger than the 5 GB single-request limit. Use rclone mode.'
        return $false
    }
    $sha1    = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
    $encoded = ConvertTo-B2Name $RemoteName

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $stream = $null; $req = $null; $resp = $null; $code = 0; $text = ''
        try {
            $stream  = [IO.File]::OpenRead($File.FullName)
            $content = New-Object System.Net.Http.StreamContent($stream, 1MB)
            $content.Headers.ContentType   = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream')
            $content.Headers.ContentLength = $size
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $B2.UploadUrl)
            $req.Content = $content
            [void]$req.Headers.TryAddWithoutValidation('Authorization', $B2.UploadToken)
            [void]$req.Headers.TryAddWithoutValidation('X-Bz-File-Name', $encoded)
            [void]$req.Headers.TryAddWithoutValidation('X-Bz-Content-Sha1', $sha1)
            $resp = $Http.SendAsync($req).GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } catch {
            $text = $_.Exception.Message
        } finally {
            if ($resp)   { $resp.Dispose() }
            if ($req)    { $req.Dispose() }
            if ($stream) { $stream.Dispose() }
        }

        if ($code -ge 200 -and $code -lt 300) {
            $fileId = $null
            try { $fileId = ($text | ConvertFrom-Json).fileId } catch { }
            if ($fileId) { Write-Ok "     $fileId"; return $true }
            Write-Err '     Unexpected 2xx without fileId'
            return $false
        }

        $msg = $text
        try { $j = $text | ConvertFrom-Json; if ($j.message) { $msg = $j.message } } catch { }
        Write-Warn "     HTTP $code (attempt $attempt) $msg"

        # Network errors, expired token, timeouts, throttling, server errors: new URL + retry
        if ($code -eq 0 -or $code -in 401, 408, 429 -or $code -ge 500) {
            try { Update-UploadUrl } catch { Write-Err "     $($_.Exception.Message)"; return $false }
            continue
        }
        return $false
    }
    $false
}

function Invoke-NativeBackend {
    if (-not $B2.BucketId) {
        Write-Err 'Could not resolve bucket id for native backend.'
        return $false
    }
    $files = @(Get-SourceFiles)
    if ($files.Count -eq 0) {
        Write-Warn "No files found under '$LocalPath'."
        return $false
    }
    Write-Info 'Retrieving upload URL...'
    Update-UploadUrl
    Write-Info 'Starting B2 upload via native API...'
    Write-Info "Source: $LocalPath"
    if ($Prefix) { Write-Info "Prefix: $Prefix" }

    $ok = 0; $fail = 0
    foreach ($f in $files) {
        if (Send-B2File $f (Get-RemoteName $f)) { $ok++ }
        else { $fail++; Write-Err "     Failed: $($f.FullName)" }
    }
    Write-Host ''
    $line = "Done. Uploaded $ok / $($files.Count) file(s). Failed: $fail"
    if ($fail -eq 0) { Write-Ok $line } else { Write-Err $line }
    $fail -eq 0
}

# ---- rclone backend --------------------------------------------------------------
function Find-Rclone {
    $cmd = Get-Command rclone -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $RcloneDir 'rclone.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $null
}

function Install-Rclone {
    $cpu  = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($cpu) { 'ARM64' { 'arm64' } 'x86' { '386' } default { 'amd64' } }
    $url  = "https://downloads.rclone.org/rclone-current-windows-$arch.zip"
    $tmp  = Join-Path $env:TEMP ("rclone-" + [guid]::NewGuid().ToString('N'))
    $zip  = "$tmp.zip"
    Write-Info "rclone not found. Downloading portable rclone ($arch)..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $exe = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'rclone.exe' | Select-Object -First 1
        if (-not $exe) { throw 'rclone.exe not found in archive.' }
        New-Item -ItemType Directory -Path $RcloneDir -Force | Out-Null
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $RcloneDir 'rclone.exe') -Force
        Write-Ok "rclone installed to $RcloneDir"
        return $true
    } catch {
        Write-Warn "rclone download failed: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-RcloneBin {
    $bin = Find-Rclone
    if ($bin) { return $bin }
    if ($NoInstall) { Write-Warn 'rclone not found and no-install was set.'; return $null }
    if (Install-Rclone) { return (Find-Rclone) }
    $null
}

function Invoke-RcloneBackend {
    if (-not $B2.BucketName) {
        Write-Err 'rclone needs a bucket name. Enter a name as the bucket, or set one under advanced options.'
        return $false
    }
    $dest = (":b2:$($B2.BucketName)/$Prefix").TrimEnd('/')

    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    if (-not (Test-Path -LiteralPath $RcloneConf)) { New-Item -ItemType File -Path $RcloneConf | Out-Null }

    $rcArgs = @()
    if ($IsDir) { $rcArgs += 'copy', $LocalPath, $dest }
    else        { $rcArgs += 'copyto', $LocalPath, "$dest/$(Split-Path -Leaf $LocalPath)" }
    $rcArgs += '--b2-chunk-size', $ChunkSize,
               '--b2-upload-cutoff', $RcloneUpCutoff,
               '--transfers', "$Transfers",
               '--checkers', '8',
               '--stats', '10s',
               '--stats-one-line',
               '-P',
               '--config', $RcloneConf
    if ($SkipHash) {
        $rcArgs += '--b2-disable-checksum'
        Write-Info 'rclone checksums disabled for large files (skip hash).'
    }

    Write-Info 'Starting B2 upload via rclone...'
    Write-Info "Source: $LocalPath"
    Write-Info "Dest:   $dest"
    Write-Info "Chunk:  $ChunkSize   Transfers: $Transfers"

    # Run attached to this console (live -P progress); credentials only in the
    # child's environment, never on the command line or in a config file.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $RcloneBin
    $psi.Arguments       = ConvertTo-ArgString $rcArgs
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['RCLONE_B2_ACCOUNT'] = $AppId
    $psi.EnvironmentVariables['RCLONE_B2_KEY']     = $AppKey
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()

    if ($proc.ExitCode -ne 0) {
        Write-Err "rclone exited with code $($proc.ExitCode)."
        return $false
    }
    Write-Ok 'rclone upload complete.'
    $true
}

# ==== main ====================================================================
try {
    Write-Host ''
    Write-Host "=== B2 Upload  v$Version ===" -ForegroundColor Cyan
    Write-Host ''

    $AppId     = Read-Required 'B2 Application Key ID'
    $AppKey    = Read-Secret   'B2 Application Key'
    $BucketRef = Read-Required 'Bucket ID or name'
    $Prefix    = Format-Prefix (Read-Default 'Remote prefix (optional, e.g. backups/2026-11/)' '')
    $LocalPath = Read-LocalPath
    $IsDir     = (Get-Item -LiteralPath $LocalPath -Force).PSIsContainer

    do {
        $Mode = (Read-Default 'Mode: auto | rclone | native' $DefaultMode).ToLowerInvariant()
        if ($Mode -eq 'curl') { $Mode = 'native' }
    } until ($Mode -in 'auto', 'rclone', 'native')

    $Cutoff    = [int64]$DefaultCutoff
    $SkipHash  = $false
    $ChunkSize = $DefaultChunk
    $Transfers = $DefaultTransfers
    $NoInstall = $false

    if (Read-YesNo 'Advanced options?' $false) {
        $bn = Read-Default 'Bucket name for rclone (blank = resolve automatically)' ''
        if ($bn) { $B2.BucketName = $bn }
        do { $c = Read-Default 'Auto cutoff in bytes' "$DefaultCutoff" } until ($c -match '^\d+$')
        $Cutoff    = [int64]$c
        $SkipHash  = Read-YesNo 'Skip rclone full-file SHA-1 (--b2-disable-checksum)?' $false
        $ChunkSize = Read-Default 'rclone chunk size' $DefaultChunk
        do { $t = Read-Default 'rclone parallel transfers' "$DefaultTransfers" } until ($t -match '^\d+$' -and [int]$t -gt 0)
        $Transfers = [int]$t
        $NoInstall = Read-YesNo 'Do not download rclone if missing?' $false
    }

    Write-Host '------------------------------------'

    # ---- decide backend ----
    $Largest = [int64]((@(Get-SourceFiles) | Measure-Object -Property Length -Maximum).Maximum)
    Write-Info "Largest source object: $Largest bytes"
    Write-Info "Mode: $Mode   cutoff: $Cutoff"

    $RcloneBin = $null
    $Chosen    = ''
    if ($Mode -eq 'native') {
        $Chosen    = 'native'
        $RcloneBin = Find-Rclone
    } else {
        $RcloneBin = Get-RcloneBin
        if ($RcloneBin) {
            $Chosen = 'rclone'
        } elseif ($Mode -eq 'rclone') {
            Write-Err 'rclone is required for rclone mode.'
            Write-Err '   Re-run and allow the portable rclone download, or install rclone.'
            return
        } else {
            $Chosen = 'native'
            if ($Largest -ge $Cutoff) {
                Write-Warn 'rclone could not be installed; falling back to native.'
                Write-Warn '    native uses one HTTP request and a full SHA-1 first -- poor fit for huge files.'
            } else {
                Write-Warn 'rclone unavailable; using native backend.'
            }
        }
    }
    $rcShown = if ($RcloneBin) { $RcloneBin } else { 'not found' }
    Write-Info "Backend: $Chosen   rclone: $rcShown"

    Connect-B2
    Resolve-B2Bucket
    $idShown   = if ($B2.BucketId)   { $B2.BucketId }   else { 'unknown' }
    $nameShown = if ($B2.BucketName) { $B2.BucketName } else { 'unknown' }
    Write-Info "Bucket id:   $idShown"
    Write-Info "Bucket name: $nameShown"

    if ($Chosen -eq 'rclone') {
        if (Invoke-RcloneBackend) { return }
        if ($Mode -eq 'auto') {
            Write-Warn 'rclone failed; falling back to native...'
            [void](Invoke-NativeBackend)
        }
        return
    }

    [void](Invoke-NativeBackend)
}
catch {
    Write-Err $_.Exception.Message
}
finally {
    if ($Http) { $Http.Dispose() }
    $AppKey = $null
}

}
