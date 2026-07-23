#requires -Version 5.1
# ============================================================================
# Backup-GYBMailboxes.ps1 v2.1
# ----------------------------------------------------------------------------
# All-in-one setup + runner for GYB (Got Your Back) Gmail backups against a
# Google Workspace domain, using a domain-wide-delegated service account so
# no per-mailbox password or user consent is needed.
#
# WHAT IT DOES
#   1. Finds or installs a portable copy of GYB (pulls the latest Windows
#      x86_64 release straight from GitHub - no separate Python needed).
#   2. Walks you through creating a GCP service account and enabling domain-
#      wide delegation in the Workspace Admin console. Skipped automatically
#      once a key is already in place.
#   3. Test-authenticates against one mailbox before doing real work.
#   4. Backs up each mailbox you give it, one GYB folder per user, with a
#      log file and a pass/fail summary at the end.
#
#   Re-running is safe: steps already done are skipped, and GYB's own
#   incremental backup means an interrupted run just picks up where it left
#   off. Nothing here requires admin/elevated PowerShell.
#
# REQUIREMENTS
#   - Windows 10/11, PowerShell 5.1+
#   - A Google Workspace super admin to authorize the service account
#     (steps 3-4 below open the relevant consoles for you)
#   - Outbound HTTPS to github.com, accounts.google.com, *.googleapis.com
#
# USAGE
#   .\Backup-GYBMailboxes.ps1
#       Interactive. Installs GYB if needed, runs the setup wizard if
#       needed, then prompts for mailboxes to back up.
#
#   .\Backup-GYBMailboxes.ps1 -Mailboxes user1@domain.com,user2@domain.com
#       Non-interactive mailbox list. Setup wizard still runs if not yet
#       configured.
#
#   .\Backup-GYBMailboxes.ps1 -MailboxListPath C:\lists\mailboxes.txt
#       One address per line in the file. Blank lines and lines starting
#       with # are ignored.
#
#   .\Backup-GYBMailboxes.ps1 -SkipBackup
#       Only run prerequisite / service account setup, no backups.
#
#   .\Backup-GYBMailboxes.ps1 -Reauthorize
#       Force the service-account wizard again even if a key already exists.
#
#   .\Backup-GYBMailboxes.ps1 -Help
#       Show this usage block and exit.
#
# CHANGELOG (newest first)
# CHANGELOG (newest first)
# CHANGELOG (newest first)
#   2.1  Blank stderr noise from GYB (shown as a bare
#        "System.Management.Automation.RemoteException" line once the
#        progress-collapsing logic started extracting message text
#        itself) is now dropped from the live display instead of printed.
#        Still captured in the log file; real error messages still show.
#   2.0  Backup-location prompt now comes after mailbox selection instead
#        of before, so you pick who's being backed up first and where to
#        put it second.
#   1.9  GYB's repeating per-batch lines ("Got N Message IDs", "backed up
#        N of M messages") now overwrite a single status line on screen
#        instead of scrolling one line per batch. Milestone lines ("Using
#        backup folder...", "GYB needs to...") still print normally, and
#        the log file still gets every line, uncollapsed.
#   1.8  Now keeps a full session log (session-log-<timestamp>.log) next to
#        the script itself, capturing everything from the version banner
#        onward - setup steps, the pre-flight test, and all GYB output,
#        including any stray "NativeCommandError" noise from merged
#        stderr. Independent of -BackupRoot, so it's still there even if
#        that's a network/removable drive.
#   1.7  Now confirms the backup destination folder (showing the default,
#        editable) before gathering mailboxes, instead of silently using
#        %USERPROFILE%\GYB-Backups. Skipped when -BackupRoot is passed
#        explicitly.
#   1.6  Directory pull failures now surface Google's actual JSON error
#        body instead of a generic "(403) Forbidden" - and the hint text
#        now calls out the Admin SDK API needing to be enabled in the
#        Cloud project, which is a separate step from Gmail API and easy
#        to miss.
#   1.5  Pre-flight auth test no longer asks for a separate throwaway
#        mailbox - it now reuses the first address from whatever list you
#        end up with (directory pull, file, or typed). -SkipBackup still
#        asks on its own since there's no list to draw from in that mode.
#   1.4  Added an option to auto-pull the full mailbox list from the
#        Workspace directory (Admin SDK) instead of typing or maintaining
#        a file, then run it through the same numbered picker. Needs one
#        extra delegated scope -
#        https://www.googleapis.com/auth/admin.directory.user.readonly -
#        on top of the three already in use; the delegation step now
#        mentions it. Signs its own JWT for this since Windows
#        PowerShell's .NET runtime can't import PKCS#8 keys directly.
#   1.3  Mailbox lists (from -MailboxListPath or typed in) now show as a
#        numbered menu - pick a subset with something like "2,5,8-10", or
#        press Enter to use all of them.
#   1.2  Fixed a bug where GYB's own console output leaked into the
#        auth-test return value, making a successful test look like a
#        failure. Native command output is now routed through Out-Host so
#        it can't get captured.
#   1.1  Auto-detect a service account JSON sitting next to the script and
#        offer to use it; added a shortcut for "I already have a key" /
#        "delegation's already done" so the wizard only asks about what's
#        actually missing.
#   1.0  Initial version - GYB install, service account wizard, mailbox
#        loop with logging/summary.
# ============================================================================

param(
    [string[]]$Mailboxes,
    [string]$MailboxListPath,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GYB'),
    [string]$BackupRoot = (Join-Path $env:USERPROFILE 'GYB-Backups'),
    [string]$TestMailbox,
    [string]$DirectoryAdmin,
    [switch]$PullFromDirectory,
    [switch]$Reauthorize,
    [switch]$SkipBackup,
    [switch]$Help
)

$ScriptVersion = '2.1'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Success', 'Info', 'Warn', 'Error')][string]$Type = 'Info'
    )
    switch ($Type) {
        'Success' { Write-Host "[+] $Message" -ForegroundColor Green }
        'Info'    { Write-Host "[*] $Message" -ForegroundColor Cyan }
        'Warn'    { Write-Host "[!] $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "[x] $Message" -ForegroundColor Red }
    }
}

function Show-Usage {
    Write-Host @"
Backup-GYBMailboxes.ps1 v$ScriptVersion
GYB installer + service account wizard + mailbox backup runner

  .\Backup-GYBMailboxes.ps1
      Interactive: install GYB if needed, run setup wizard if needed,
      then prompt for mailboxes.

  .\Backup-GYBMailboxes.ps1 -Mailboxes user1@domain.com,user2@domain.com
  .\Backup-GYBMailboxes.ps1 -MailboxListPath C:\lists\mailboxes.txt
  .\Backup-GYBMailboxes.ps1 -PullFromDirectory -DirectoryAdmin admin@domain.com
  .\Backup-GYBMailboxes.ps1 -SkipBackup
  .\Backup-GYBMailboxes.ps1 -Reauthorize
  .\Backup-GYBMailboxes.ps1 -Help

Parameters:
  -Mailboxes          One or more addresses to back up
  -MailboxListPath    Text file, one address per line (# comments ok) -
                       shown as a numbered pick list, e.g. "2,5,8-10"
  -PullFromDirectory  Pull the mailbox list from the Workspace directory
                       instead of a file/typed list, same numbered picker
  -DirectoryAdmin     Admin email to impersonate for the directory lookup
                       (remembered next to the key after first use)
  -InstallDir       Where GYB gets installed  (default: %LOCALAPPDATA%\GYB)
  -BackupRoot       Where backups get written (default: %USERPROFILE%\GYB-Backups)
  -TestMailbox      Address to use for the pre-flight auth check
  -Reauthorize      Force the service account wizard even if a key exists
  -SkipBackup       Run setup only, skip the backup loop
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

function Get-GYBExecutable {
    param([string]$InstallDir)
    if (-not (Test-Path $InstallDir)) { return $null }
    $found = Get-ChildItem -Path $InstallDir -Filter 'gyb.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Install-GYB {
    param([string]$InstallDir)

    Write-Status 'Looking up the latest GYB release on GitHub...' Info
    $headers = @{ 'User-Agent' = 'Backup-GYBMailboxes-Script' }
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/GAM-team/got-your-back/releases/latest' -Headers $headers
    } catch {
        Write-Status "Couldn't reach the GitHub API: $($_.Exception.Message)" Error
        throw
    }

    $asset = $release.assets | Where-Object { $_.name -like '*windows-x86_64.zip' } | Select-Object -First 1
    if (-not $asset) {
        Write-Status "No Windows zip found in release $($release.tag_name). Grab it manually: https://github.com/GAM-team/got-your-back/releases" Error
        throw 'GYB Windows asset not found'
    }

    Write-Status "Downloading GYB $($release.tag_name) ($($asset.name))..." Info
    $zipPath = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $InstallDir -Force
    Remove-Item $zipPath -Force

    $exe = Get-GYBExecutable -InstallDir $InstallDir
    if (-not $exe) { throw "Extracted the release but couldn't find gyb.exe under $InstallDir" }

    Write-Status "GYB installed: $exe" Success
    return $exe
}

function Test-ServiceAccountKeyFile {
    # Returns the parsed key object if $Path is a valid service account JSON key, otherwise $null.
    param([string]$Path)
    try {
        $json = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($json.type -eq 'service_account') { return $json }
    } catch {}
    return $null
}

function Find-ServiceAccountKeyCandidates {
    # Any *.json file sitting next to the script that looks like a service account key.
    param([string]$Directory)
    if (-not $Directory -or -not (Test-Path $Directory)) { return @() }
    $candidates = @()
    foreach ($file in Get-ChildItem -Path $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $parsed = Test-ServiceAccountKeyFile -Path $file.FullName
        if ($parsed) { $candidates += [PSCustomObject]@{ Path = $file.FullName; Json = $parsed } }
    }
    return $candidates
}

function Invoke-CreateServiceAccountFlow {
    # Full browser walkthrough for someone with no service account yet.
    Write-Host ''
    Write-Status '=== Creating a new service account ===' Info
    Write-Host ''

    Write-Status 'Step 1: Create or select a Google Cloud project' Info
    Write-Host '  Opening: https://console.cloud.google.com/projectcreate'
    Start-Process 'https://console.cloud.google.com/projectcreate'
    Read-Host '  Press Enter once the project exists and is selected' | Out-Null

    Write-Status 'Step 2: Enable the Gmail API for that project' Info
    Write-Host '  Opening: https://console.cloud.google.com/apis/library/gmail.googleapis.com'
    Start-Process 'https://console.cloud.google.com/apis/library/gmail.googleapis.com'
    Read-Host "  Press Enter once you've clicked Enable" | Out-Null

    Write-Status 'Step 3: Create a service account + JSON key' Info
    Write-Host '  Opening: https://console.cloud.google.com/iam-admin/serviceaccounts'
    Write-Host "  - Create Service Account, name it e.g. 'GYB Backup'"
    Write-Host '  - Skip granting it a role, click Done'
    Write-Host '  - Open it -> Keys -> Add Key -> Create new key -> JSON'
    Write-Host '  - Your browser will download a .json file'
    Start-Process 'https://console.cloud.google.com/iam-admin/serviceaccounts'

    $downloadedPath = (Read-Host '  Paste the full path to the downloaded JSON key file').Trim('"')
    $parsed = Test-ServiceAccountKeyFile -Path $downloadedPath
    while (-not $parsed) {
        Write-Status "Can't find that file, or it's not a service account key." Error
        $downloadedPath = (Read-Host '  Paste the full path again').Trim('"')
        $parsed = Test-ServiceAccountKeyFile -Path $downloadedPath
    }

    return [PSCustomObject]@{ Path = $downloadedPath; Json = $parsed }
}

function Get-ServiceAccountKey {
    # Figures out where the service account key comes from: a JSON already sitting next to
    # the script, one the person already has saved elsewhere, or a brand new one via the
    # full Cloud Console walkthrough. Returns @{ Path; Json }.
    param([string]$ScriptDir)

    $candidates = Find-ServiceAccountKeyCandidates -Directory $ScriptDir
    foreach ($candidate in $candidates) {
        Write-Status "Found a service account key next to the script: $(Split-Path $candidate.Path -Leaf) ($($candidate.Json.client_email))" Info
        $use = Read-Host '  Use this key? (y/n)'
        if ($use -eq 'y') { return $candidate }
    }

    $already = Read-Host "`nDo you already have a service account JSON key downloaded somewhere? (y/n)"
    if ($already -eq 'y') {
        $path = (Read-Host '  Full path to the JSON key file').Trim('"')
        $parsed = Test-ServiceAccountKeyFile -Path $path
        while (-not $parsed) {
            Write-Status "That's not a valid service account key file." Error
            $path = (Read-Host '  Full path to the JSON key file').Trim('"')
            $parsed = Test-ServiceAccountKeyFile -Path $path
        }
        return [PSCustomObject]@{ Path = $path; Json = $parsed }
    }

    return Invoke-CreateServiceAccountFlow
}

function Invoke-DelegationStep {
    # Domain-wide delegation authorization is a separate yes/no since someone reusing an
    # existing key has usually already done this.
    param($KeyJson)

    $already = Read-Host "`nHas domain-wide delegation already been authorized for this service account in the Admin console? (y/n)"
    if ($already -eq 'y') {
        Write-Status 'Skipping delegation step' Success
        return
    }

    Write-Status 'Authorize domain-wide delegation' Info
    Write-Host "  Client ID:  $($KeyJson.client_id)"
    Write-Host '  Scopes (paste as one comma-separated line):'
    Write-Host '    https://mail.google.com/,https://www.googleapis.com/auth/apps.groups.migration,https://www.googleapis.com/auth/drive.appdata'
    Write-Host '  Add this one too if you want the directory auto-pull mailbox picker:'
    Write-Host '    https://www.googleapis.com/auth/admin.directory.user.readonly'
    Write-Host '  Opening: https://admin.google.com/ac/owl/domainwidedelegation'
    Start-Process 'https://admin.google.com/ac/owl/domainwidedelegation'
    Read-Host "  Press Enter once you've added the Client ID + scopes and clicked Authorize" | Out-Null

    Write-Status 'Delegation authorized' Success
    Write-Status 'Can take a few minutes to propagate - if the test below fails, wait and retry' Warn
}

function Test-GYBAuth {
    param([string]$GybExe, [string]$TestEmail)
    Write-Status "Testing service account access for $TestEmail ..." Info
    & $GybExe --email $TestEmail --service-account --action count 2>&1 | Out-Host
    return $LASTEXITCODE
}

function Select-Mailboxes {
    # Shows a numbered list and lets the person narrow it down with something like
    # "2,5,8-9" instead of retyping addresses. Blank input = use everything.
    param([string[]]$Candidates)

    if ($Candidates.Count -le 1) { return $Candidates }

    Write-Host ''
    Write-Status 'Available mailboxes:' Info
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        Write-Host ('  {0,3}) {1}' -f ($i + 1), $Candidates[$i])
    }
    Write-Host ''
    $selection = Read-Host 'Which ones? (e.g. 2,5,8-10 - Enter for all)'

    if ([string]::IsNullOrWhiteSpace($selection)) { return $Candidates }

    $indices = New-Object System.Collections.Generic.List[int]
    foreach ($part in $selection -split ',') {
        $part = $part.Trim()
        if (-not $part) { continue }
        if ($part -match '^(\d+)\s*-\s*(\d+)$') {
            $lo = [int]$matches[1]; $hi = [int]$matches[2]
            if ($lo -gt $hi) { $lo, $hi = $hi, $lo }
            for ($n = $lo; $n -le $hi; $n++) { $indices.Add($n) }
        } elseif ($part -match '^\d+$') {
            $indices.Add([int]$part)
        } else {
            Write-Status "Ignoring unrecognized selection: '$part'" Warn
        }
    }

    $chosen = New-Object System.Collections.Generic.List[string]
    foreach ($n in ($indices | Sort-Object -Unique)) {
        if ($n -ge 1 -and $n -le $Candidates.Count) {
            $chosen.Add($Candidates[$n - 1])
        } else {
            Write-Status "Skipping out-of-range selection: $n" Warn
        }
    }

    if ($chosen.Count -eq 0) {
        Write-Status 'Nothing valid selected - using the full list instead' Warn
        return $Candidates
    }

    return $chosen
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-DerTlvContent {
    # Content bytes of the DER TLV starting at $StartOffset.
    param([byte[]]$Bytes, [int]$StartOffset = 0)
    $pos = $StartOffset + 1
    $lenByte = $Bytes[$pos]; $pos++
    if ($lenByte -lt 0x80) {
        $len = [int]$lenByte
    } else {
        $numLenBytes = $lenByte -band 0x7F
        $len = 0
        for ($i = 0; $i -lt $numLenBytes; $i++) { $len = ($len -shl 8) -bor $Bytes[$pos]; $pos++ }
    }
    $value = New-Object byte[] $len
    [Array]::Copy($Bytes, $pos, $value, 0, $len)
    return $value
}

function Get-DerChildren {
    # Splits the content of a DER SEQUENCE into its child TLVs' value bytes.
    param([byte[]]$Content)
    $children = New-Object System.Collections.Generic.List[byte[]]
    $pos = 0
    while ($pos -lt $Content.Length) {
        $pos++
        $lenByte = $Content[$pos]; $pos++
        if ($lenByte -lt 0x80) {
            $len = [int]$lenByte
        } else {
            $numLenBytes = $lenByte -band 0x7F
            $len = 0
            for ($i = 0; $i -lt $numLenBytes; $i++) { $len = ($len -shl 8) -bor $Content[$pos]; $pos++ }
        }
        $value = New-Object byte[] $len
        [Array]::Copy($Content, $pos, $value, 0, $len)
        $children.Add($value)
        $pos += $len
    }
    return $children
}

function ConvertTo-UnsignedBytes {
    # Strips DER's leading 0x00 sign byte and left-pads to $TargetLength if given.
    param([byte[]]$Bytes, [int]$TargetLength = 0)
    $trimmed = $Bytes
    while ($trimmed.Length -gt 1 -and $trimmed[0] -eq 0) { $trimmed = $trimmed[1..($trimmed.Length - 1)] }
    if ($TargetLength -gt 0 -and $trimmed.Length -lt $TargetLength) {
        $padded = New-Object byte[] $TargetLength
        [Array]::Copy($trimmed, 0, $padded, $TargetLength - $trimmed.Length, $trimmed.Length)
        return $padded
    }
    return $trimmed
}

function Get-RSAFromServiceAccountKey {
    # Builds an RSACryptoServiceProvider from a Google service account key's PKCS#8 PEM.
    # Windows PowerShell runs on .NET Framework, which has no RSA.ImportPkcs8PrivateKey,
    # so this walks the DER structure by hand instead.
    param([string]$Pem)

    $b64 = (($Pem -replace '-----BEGIN PRIVATE KEY-----', '') -replace '-----END PRIVATE KEY-----', '') -replace '\s', ''
    $pkcs8Bytes = [Convert]::FromBase64String($b64)

    $pkcs8Content = Get-DerTlvContent -Bytes $pkcs8Bytes
    $pkcs8Children = Get-DerChildren -Content $pkcs8Content
    $rsaKeyDer = $pkcs8Children[2]                        # privateKey OCTET STRING = inner RSAPrivateKey DER

    $rsaContent = Get-DerTlvContent -Bytes $rsaKeyDer
    $rsaChildren = Get-DerChildren -Content $rsaContent    # version, n, e, d, p, q, dp, dq, qinv

    $modulus = ConvertTo-UnsignedBytes $rsaChildren[1]
    $keyBytes = $modulus.Length
    $halfBytes = [int]($keyBytes / 2)

    $params = New-Object System.Security.Cryptography.RSAParameters
    $params.Modulus  = $modulus
    $params.Exponent = ConvertTo-UnsignedBytes $rsaChildren[2]
    $params.D        = ConvertTo-UnsignedBytes $rsaChildren[3] -TargetLength $keyBytes
    $params.P        = ConvertTo-UnsignedBytes $rsaChildren[4] -TargetLength $halfBytes
    $params.Q        = ConvertTo-UnsignedBytes $rsaChildren[5] -TargetLength $halfBytes
    $params.DP       = ConvertTo-UnsignedBytes $rsaChildren[6] -TargetLength $halfBytes
    $params.DQ       = ConvertTo-UnsignedBytes $rsaChildren[7] -TargetLength $halfBytes
    $params.InverseQ = ConvertTo-UnsignedBytes $rsaChildren[8] -TargetLength $halfBytes

    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
    $rsa.ImportParameters($params)
    return $rsa
}

function Get-HttpErrorDetail {
    # Windows PowerShell's Invoke-RestMethod only surfaces "(403) Forbidden" by default -
    # the actually useful bit is Google's JSON error body inside the response stream.
    param($ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $bodyText = $reader.ReadToEnd()
            if ($bodyText) { return $bodyText.Trim() }
        }
    } catch {}
    return $ErrorRecord.Exception.Message
}

function Get-DirectoryAccessToken {
    # Signs a JWT as the service account (impersonating $ImpersonateEmail) and exchanges
    # it for an access token scoped to read the Workspace directory.
    param([string]$ClientEmail, [string]$PrivateKeyPem, [string]$ImpersonateEmail)

    $rsa = Get-RSAFromServiceAccountKey -Pem $PrivateKeyPem
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $header = '{"alg":"RS256","typ":"JWT"}'
    $claims = @{
        iss   = $ClientEmail
        scope = 'https://www.googleapis.com/auth/admin.directory.user.readonly'
        aud   = 'https://oauth2.googleapis.com/token'
        iat   = $now
        exp   = $now + 3600
        sub   = $ImpersonateEmail
    } | ConvertTo-Json -Compress

    $headerB64 = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))
    $claimsB64 = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($claims))
    $signingInput = "$headerB64.$claimsB64"
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($signingInput), 'SHA256')
    $jwt = "$signingInput.$(ConvertTo-Base64Url $signature)"

    $body = @{
        grant_type = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
        assertion  = $jwt
    }
    try {
        $response = Invoke-RestMethod -Uri 'https://oauth2.googleapis.com/token' -Method Post -Body $body
    } catch {
        throw (Get-HttpErrorDetail -ErrorRecord $_)
    }
    return $response.access_token
}

function Get-DirectoryMailboxes {
    # Pulls every active user's primary email from the Workspace directory.
    param([string]$ClientEmail, [string]$PrivateKeyPem, [string]$ImpersonateEmail)

    $token = Get-DirectoryAccessToken -ClientEmail $ClientEmail -PrivateKeyPem $PrivateKeyPem -ImpersonateEmail $ImpersonateEmail
    $headers = @{ Authorization = "Bearer $token" }

    $emails = New-Object System.Collections.Generic.List[string]
    $pageToken = $null
    do {
        $uri = 'https://admin.googleapis.com/admin/directory/v1/users?customer=my_customer&maxResults=500&orderBy=email'
        if ($pageToken) { $uri += "&pageToken=$pageToken" }
        try {
            $resp = Invoke-RestMethod -Uri $uri -Headers $headers
        } catch {
            throw (Get-HttpErrorDetail -ErrorRecord $_)
        }
        foreach ($u in $resp.users) {
            if (-not $u.suspended) { $emails.Add($u.primaryEmail) }
        }
        $pageToken = $resp.nextPageToken
    } while ($pageToken)

    return $emails
}

function Get-MailboxList {
    param(
        [string[]]$Mailboxes,
        [string]$MailboxListPath,
        [switch]$PullFromDirectory,
        [string]$DirectoryAdmin,
        [string]$ClientEmail,
        [string]$PrivateKeyPem,
        [string]$KeyFolder
    )

    # An explicit -Mailboxes list from the caller is already a final selection
    # (keeps non-interactive/scheduled-task usage prompt-free).
    if ($Mailboxes -and $Mailboxes.Count -gt 0) {
        return $Mailboxes | ForEach-Object { $_.Trim() } | Select-Object -Unique
    }

    $pool = New-Object System.Collections.Generic.List[string]

    if ($MailboxListPath) {
        if (-not (Test-Path $MailboxListPath)) { throw "Mailbox list file not found: $MailboxListPath" }
        Get-Content $MailboxListPath | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith('#')) { $pool.Add($line) }
        }
    } else {
        $useDirectory = [bool]$PullFromDirectory
        if (-not $useDirectory) {
            Write-Host ''
            $choice = Read-Host 'No mailbox list supplied - (1) pull the full list from the Workspace directory, or (2) type addresses in? [1/2]'
            $useDirectory = ($choice -eq '1')
        }

        if ($useDirectory) {
            $adminFile = Join-Path $KeyFolder 'directory-admin.txt'
            if (-not $DirectoryAdmin -and (Test-Path $adminFile)) {
                $DirectoryAdmin = (Get-Content $adminFile -Raw).Trim()
                Write-Status "Using saved directory admin: $DirectoryAdmin" Info
            }
            if (-not $DirectoryAdmin) {
                $DirectoryAdmin = Read-Host '  Workspace admin email to use for the directory lookup'
            }

            Write-Status "Pulling mailbox list from the Workspace directory (as $DirectoryAdmin)..." Info
            try {
                $directoryUsers = Get-DirectoryMailboxes -ClientEmail $ClientEmail -PrivateKeyPem $PrivateKeyPem -ImpersonateEmail $DirectoryAdmin
            } catch {
                Write-Status "Directory pull failed: $($_.Exception.Message)" Error
                Write-Host "  Likely causes:"
                Write-Host "  - Admin SDK API not enabled for this project: https://console.cloud.google.com/apis/library/admin.googleapis.com"
                Write-Host "  - https://www.googleapis.com/auth/admin.directory.user.readonly missing from this"
                Write-Host "    service account's scopes at https://admin.google.com/ac/owl/domainwidedelegation"
                Write-Host "  - $DirectoryAdmin isn't a real super admin (or lacks directory read rights)"
                throw
            }
            Set-Content -Path $adminFile -Value $DirectoryAdmin
            $directoryUsers | ForEach-Object { $pool.Add($_) }
            Write-Status "Found $($pool.Count) mailboxes in the directory" Success
        } else {
            Write-Status 'Enter addresses now (blank line to finish)' Info
            while ($true) {
                $entry = Read-Host '  Mailbox'
                if ([string]::IsNullOrWhiteSpace($entry)) { break }
                $pool.Add($entry.Trim())
            }
        }
    }

    $pool = @($pool | Select-Object -Unique)
    if ($pool.Count -eq 0) { return @() }

    return Select-Mailboxes -Candidates $pool
}

function Write-GYBOutputLine {
    # Collapses GYB's repeating per-batch progress lines ("Got N Message IDs",
    # "backed up N of M messages") into one overwritten status line, while
    # milestone/stage lines ("Using backup folder...", "GYB needs to...") still
    # print normally. $InProgress tracks whether the cursor is mid-overwrite.
    param([string]$Line, [ref]$InProgress)

    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    if ($Line -match '^(Got \d+ Message IDs|back(ed|ing) up \d+ of \d+ messages)$') {
        Write-Host ("`r" + $Line.PadRight(80)) -NoNewline
        $InProgress.Value = $true
    } else {
        if ($InProgress.Value) {
            Write-Host ''
            $InProgress.Value = $false
        }
        Write-Host $Line
    }
}

function Invoke-GYBBackups {
    param([string]$GybExe, [string[]]$MailboxList, [string]$BackupRoot)

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $logDir = Join-Path $BackupRoot '_logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logFile = Join-Path $logDir "backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    $results = @()
    $i = 0
    foreach ($mailbox in $MailboxList) {
        $i++
        Write-Host ''
        Write-Status "[$i/$($MailboxList.Count)] Backing up $mailbox" Info

        $folder = Join-Path $BackupRoot "GYB-GMail-Backup-$mailbox"
        $start = Get-Date
        $inProgress = $false
        & $GybExe --email $mailbox --service-account --action backup --local-folder $folder 2>&1 |
            Tee-Object -FilePath $logFile -Append |
            ForEach-Object {
                $item = $_
                if ($item -is [System.Management.Automation.ErrorRecord]) {
                    # Native stderr comes through as ErrorRecord objects. GYB sometimes writes a
                    # blank stderr line, which shows up with no real message - that's just noise
                    # from the redirect, not an actual error, so skip it on screen.
                    if ([string]::IsNullOrWhiteSpace($item.Exception.Message)) { return }
                    Write-GYBOutputLine -Line $item.Exception.Message -InProgress ([ref]$inProgress)
                } else {
                    Write-GYBOutputLine -Line $item.ToString() -InProgress ([ref]$inProgress)
                }
            }
        if ($inProgress) { Write-Host '' }
        $exitCode = $LASTEXITCODE
        $elapsed = (Get-Date) - $start

        if ($exitCode -eq 0) {
            Write-Status "$mailbox done in $([int]$elapsed.TotalMinutes)m $($elapsed.Seconds)s" Success
            $status = 'OK'
        } else {
            Write-Status "$mailbox failed (exit $exitCode) - see $logFile" Error
            $status = 'FAILED'
        }

        $results += [PSCustomObject]@{
            Mailbox = $mailbox
            Status  = $status
            Elapsed = $elapsed.ToString('hh\:mm\:ss')
            Folder  = $folder
        }
    }

    Write-Host ''
    Write-Status '=== Summary ===' Info
    $results | Format-Table -AutoSize | Out-String | Write-Host

    $failCount = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
    if ($failCount -gt 0) {
        Write-Status "$failCount of $($results.Count) mailboxes failed - just re-run the script, GYB backups are incremental so it'll pick up where it left off" Warn
    } else {
        Write-Status "All $($results.Count) mailboxes backed up successfully" Success
    }
    Write-Status "Full log: $logFile" Info
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$sessionLog = Join-Path $PSScriptRoot "session-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
try {
    Start-Transcript -Path $sessionLog -Append -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
} catch {
    $transcriptStarted = $false
    Write-Status "Could not start session log: $($_.Exception.Message)" Warn
}

Write-Host "Backup-GYBMailboxes.ps1 v$ScriptVersion" -ForegroundColor DarkGray
if ($transcriptStarted) { Write-Status "Session log: $sessionLog" Info }
Write-Host ''

try {
    # Phase 1: GYB binary
    $gybExe = Get-GYBExecutable -InstallDir $InstallDir
    if ($gybExe) {
        $ver = & $gybExe --version 2>&1
        Write-Status "GYB already installed ($ver) - skipping download" Success
    } else {
        $gybExe = Install-GYB -InstallDir $InstallDir
    }

    # Phase 2: service account
    $gybFolder = Split-Path $gybExe -Parent
    $keyFile = Join-Path $gybFolder 'oauth2service.json'

    if ((Test-Path $keyFile) -and (-not $Reauthorize)) {
        $existingKey = Test-ServiceAccountKeyFile -Path $keyFile
        if ($existingKey) {
            Write-Status "Service account already configured ($($existingKey.client_email)) - skipping wizard" Success
            $saJson = $existingKey
        } else {
            Write-Status 'oauth2service.json exists but is not valid JSON - re-run with -Reauthorize' Error
            throw 'Invalid oauth2service.json'
        }
    } else {
        $keyResult = Get-ServiceAccountKey -ScriptDir $PSScriptRoot
        $sourceFull = (Resolve-Path $keyResult.Path).Path
        if (-not (Test-Path $keyFile) -or $sourceFull -ne (Resolve-Path $keyFile).Path) {
            Copy-Item -Path $keyResult.Path -Destination $keyFile -Force
        }
        Write-Status "Key saved as $keyFile" Success
        Invoke-DelegationStep -KeyJson $keyResult.Json
        $saJson = $keyResult.Json
    }

    if ($SkipBackup) {
        # No mailbox list needed for a setup-only run - test whatever address is given/typed.
        if (-not $TestMailbox) {
            $TestMailbox = Read-Host "`nEnter one mailbox address to test the connection with"
        }
        $testResult = Test-GYBAuth -GybExe $gybExe -TestEmail $TestMailbox
        if ($testResult -ne 0) {
            Write-Status "Test failed (exit code $testResult)." Error
            Write-Host '  Common causes: Client ID/scope mismatch, Gmail API not enabled yet, or delegation still propagating (wait 5-10 min).'
            exit 1
        }
        Write-Status "Service account confirmed working (tested against $TestMailbox)" Success
        Write-Status '-SkipBackup set - setup complete, no backups run' Info
        exit 0
    }

    # Phase 3: gather mailboxes (may pull from -MailboxListPath, the Workspace directory, or typing)
    $mailboxList = Get-MailboxList -Mailboxes $Mailboxes -MailboxListPath $MailboxListPath `
        -PullFromDirectory:$PullFromDirectory -DirectoryAdmin $DirectoryAdmin `
        -ClientEmail $saJson.client_email -PrivateKeyPem $saJson.private_key -KeyFolder $gybFolder

    if ($mailboxList.Count -eq 0) {
        Write-Status 'No mailboxes selected - nothing to do' Warn
        exit 0
    }

    # Confirm where backups get saved now that we know what's being backed up (skipped if
    # -BackupRoot was passed explicitly, so scheduled/automated runs stay non-interactive).
    if (-not $PSBoundParameters.ContainsKey('BackupRoot')) {
        Write-Host ''
        $customRoot = Read-Host "Where should backups be saved? [$BackupRoot]"
        if (-not [string]::IsNullOrWhiteSpace($customRoot)) { $BackupRoot = $customRoot.Trim('"') }
    }
    Write-Status "Backups will be saved under: $BackupRoot" Info

    # Phase 4: pre-flight auth check - reuses a mailbox from the list above instead of asking again
    $effectiveTest = if ($TestMailbox) { $TestMailbox } else { $mailboxList[0] }
    $attempt = 0
    do {
        $attempt++
        $testResult = Test-GYBAuth -GybExe $gybExe -TestEmail $effectiveTest
        if ($testResult -ne 0 -and $attempt -eq 1) {
            Write-Status "Test failed (exit code $testResult)." Error
            Write-Host '  Common causes: Client ID/scope mismatch, Gmail API not enabled yet, or delegation still propagating (wait 5-10 min).'
            $retry = Read-Host '  Retry now? (y/n)'
            if ($retry -ne 'y') { exit 1 }
        }
    } while ($testResult -ne 0 -and $attempt -eq 1)

    if ($testResult -ne 0) {
        Write-Status "Still failing after retry (exit code $testResult) - fix the setup above and re-run." Error
        exit 1
    }
    Write-Status "Service account confirmed working (tested against $effectiveTest)" Success

    # Phase 5: run backups
    Invoke-GYBBackups -GybExe $gybExe -MailboxList $mailboxList -BackupRoot $BackupRoot
}
catch {
    Write-Status "Fatal error: $($_.Exception.Message)" Error
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
}
