# ============================================================
# CLEAR-PDFMETADATA.PS1
# ============================================================
# Strips metadata (Title, Author, Producer, etc.) from PDF files
# using exiftool. Clears standard /Info dict + embedded XMP.
#
# CHANGELOG (newest first):
#   v3.0 - Added a qpdf rewrite pass after the exiftool strip.
#          exiftool's PDF edits are incremental (it appends a new
#          xref saying "ignore the old /Info object" but leaves the
#          old object's bytes in the file) - so a blanked Title can
#          still be recovered by anything reading the raw file, and
#          was still showing up as the Chrome tab title. qpdf does a
#          full rewrite from the current object tree, so anything
#          exiftool marked as superseded is actually dropped, not
#          just unreferenced. exiftool still owns the actual
#          metadata editing (it understands Title/XMP/etc. - qpdf
#          doesn't); qpdf just does the garbage-collection pass
#          exiftool doesn't do on its own.
#   v2.3 - Stopped leaving a duplicate copy behind: after
#          normalizing the exe + exiftool_files up into $exifDir,
#          the extracted versioned subfolder (e.g. exiftool-13.59_64)
#          still sat there with its own full copy of everything.
#          Now removed once the normalized copy is confirmed in place.
#   v2.2 - Fixed "Could not find ...\exiftool_files\perl5*.dll":
#          the exe is a launcher stub that requires its
#          exiftool_files folder (Perl runtime + DLLs) in the SAME
#          directory as the exe. Normalize step was copying the
#          exe up a level but leaving exiftool_files behind in the
#          versioned subfolder - now copies both together.
#   v2.1 - Switched to the zip package (files.edgeintegrated.net
#          now hosts exiftool-13.59_64.zip, not a bare exe) - back
#          to extract + normalize, same as the SourceForge version,
#          just pointed at our own server.
#   v2.0 - Replaced exiftool.org/SourceForge bootstrap entirely -
#          both kept breaking (404s, HTML landing pages instead of
#          the zip). Now pulls from files.edgeintegrated.net,
#          which is ours and stable.
#   v1.4 - Fixed "End of Central Directory record could not be
#          found" on extraction: sourceforge.net/.../download
#          returns an HTML landing page ("Your download will
#          start shortly...") rather than the zip itself, since
#          it redirects via JS/meta-refresh, not a real HTTP
#          redirect Invoke-WebRequest follows. Switched to
#          downloads.sourceforge.net, which serves the actual
#          binary via a proper redirect.
#   v1.3 - Fixed 404 on exiftool.org zip links: exiftool.org no
#          longer hosts the zips directly (DreamHost throttling
#          forced them to point downloads at SourceForge instead).
#          Now reads the version number from exiftool.org/ver.txt
#          and builds the SourceForge download URL from that.
#   v1.2 - Fixed false failures: exiftool writes routine warnings
#          (e.g. "PDF edits are reversible") to stderr, and
#          $ErrorActionPreference = Stop was treating that as a
#          terminating error even on success. Scoped EAP to
#          Continue around the exiftool call and judge success
#          by $LASTEXITCODE instead.
#   v1.1 - Fixed exiftool bootstrap: scrape current release filename
#          from exiftool.org instead of hardcoding a version
#          (hardcoded 13.10 404'd once exiftool.org moved to 13.59)
#   v1.0 - Initial release: exiftool bootstrap, recursive strip,
#          before/after summary
# ============================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [switch]$Recurse,

    [switch]$KeepDates  # preserve CreationDate/ModifyDate, strip everything else
)

$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    switch ($Type) {
        "Success" { Write-Host "[+] $Message" -ForegroundColor Green }
        "Info"    { Write-Host "[*] $Message" -ForegroundColor Cyan }
        "Warn"    { Write-Host "[!] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "[x] $Message" -ForegroundColor Red }
    }
}

function Write-Section {
    param([string]$Label)
    $bar = "=" * 60
    Write-Host ""
    Write-Host $bar -ForegroundColor DarkGray
    Write-Host $Label.ToUpper() -ForegroundColor White
    Write-Host $bar -ForegroundColor DarkGray
}

# ============================================================
# EXIFTOOL BOOTSTRAP
# ============================================================
Write-Section "Exiftool Bootstrap"

$toolsDir  = Join-Path $env:LOCALAPPDATA "edge-tools"
$exifDir   = Join-Path $toolsDir "exiftool"
$exifPath  = Join-Path $exifDir "exiftool.exe"

if (Test-Path $exifPath) {
    Write-Status "exiftool already present at $exifPath" "Success"
}
else {
    Write-Status "exiftool not found, downloading..." "Info"
    New-Item -ItemType Directory -Path $exifDir -Force | Out-Null

    try {
        # Hosted on our own file server - no dependency on exiftool.org or
        # SourceForge, both of which have proven unreliable for scripted downloads.
        $zipUrl  = "https://files.edgeintegrated.net/exiftool-13.59_64.zip"
        $zipPath = Join-Path $exifDir "exiftool.zip"

        Write-Status "Downloading exiftool-13.59_64.zip from files.edgeintegrated.net..." "Info"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        # Sanity check: a real zip starts with "PK". Fail clearly here rather than
        # letting Expand-Archive throw a cryptic "End of Central Directory" error.
        $sig = [System.IO.File]::ReadAllBytes($zipPath) | Select-Object -First 2
        if (-not ($sig[0] -eq 0x50 -and $sig[1] -eq 0x4B)) {
            throw "Downloaded file is not a valid zip - URL: $zipUrl"
        }

        Expand-Archive -Path $zipPath -DestinationPath $exifDir -Force

        # zip extracts as exiftool(-k).exe or exiftool.exe depending on build - normalize
        $found = Get-ChildItem -Path $exifDir -Recurse -Filter "exiftool*.exe" | Select-Object -First 1
        if (-not $found) { throw "exiftool.exe not found after extraction" }
        if ($found.FullName -ne $exifPath) {
            $extractedSubdir = $found.DirectoryName

            Copy-Item $found.FullName $exifPath -Force

            # The exe is just a launcher - it requires its "exiftool_files" folder
            # (Perl runtime + DLLs) to sit in the SAME directory as the exe itself.
            # Moving/copying the exe alone (as above) leaves that folder behind.
            $srcFilesFolder = Join-Path $extractedSubdir "exiftool_files"
            $dstFilesFolder = Join-Path $exifDir "exiftool_files"
            if ((Test-Path $srcFilesFolder) -and ($srcFilesFolder -ne $dstFilesFolder)) {
                Copy-Item $srcFilesFolder $dstFilesFolder -Recurse -Force
            }

            # Clean up the versioned subfolder (e.g. exiftool-13.59_64) now that
            # its contents have been copied up - otherwise it sits there as a
            # duplicate full copy of the exe + runtime, wasting space.
            if ((Test-Path $exifPath) -and (Test-Path $dstFilesFolder) -and ($extractedSubdir -ne $exifDir)) {
                Remove-Item $extractedSubdir -Recurse -Force
            }
        }

        Remove-Item $zipPath -Force
        Write-Status "exiftool installed to $exifPath" "Success"
    }
    catch {
        Write-Status "Failed to bootstrap exiftool: $($_.Exception.Message)" "Error"
        Write-Status "Manual fallback: download from https://files.edgeintegrated.net/exiftool-13.59_64.zip and extract to $exifDir" "Warn"
        exit 1
    }
}

# ============================================================
# QPDF BOOTSTRAP
# ============================================================
Write-Section "Qpdf Bootstrap"

$qpdfDir  = Join-Path $toolsDir "qpdf"
$qpdfPath = Join-Path $qpdfDir "qpdf.exe"

if (Test-Path $qpdfPath) {
    Write-Status "qpdf already present at $qpdfPath" "Success"
}
else {
    Write-Status "qpdf not found, downloading..." "Info"
    New-Item -ItemType Directory -Path $qpdfDir -Force | Out-Null

    try {
        # Pulled directly from qpdf's official GitHub releases - release assets are
        # served as real binaries via a proper redirect (unlike SourceForge's
        # JS/landing-page download links, which broke the exiftool bootstrap above).
        $qpdfVersion = "12.3.2"
        $zipName = "qpdf-${qpdfVersion}-msvc64.zip"
        $zipUrl  = "https://github.com/qpdf/qpdf/releases/download/v${qpdfVersion}/$zipName"
        $zipPath = Join-Path $qpdfDir "qpdf.zip"

        Write-Status "Downloading $zipName from GitHub..." "Info"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        # Sanity check: a real zip starts with "PK".
        $sig = [System.IO.File]::ReadAllBytes($zipPath) | Select-Object -First 2
        if (-not ($sig[0] -eq 0x50 -and $sig[1] -eq 0x4B)) {
            throw "Downloaded file is not a valid zip - URL: $zipUrl"
        }

        Expand-Archive -Path $zipPath -DestinationPath $qpdfDir -Force

        # qpdf.exe ships inside a bin/ folder alongside its DLLs - copy the whole
        # bin/ contents up to $qpdfDir so qpdf.exe finds its DLLs next to it.
        $foundExe = Get-ChildItem -Path $qpdfDir -Recurse -Filter "qpdf.exe" | Select-Object -First 1
        if (-not $foundExe) { throw "qpdf.exe not found after extraction" }
        $binDir = $foundExe.DirectoryName

        if ($binDir -ne $qpdfDir) {
            Get-ChildItem -Path $binDir -File | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $qpdfDir $_.Name) -Force
            }

            # Clean up the versioned extraction subfolder (e.g. qpdf-12.3.2-msvc64)
            # now that its bin/ contents have been copied up - avoids leaving a
            # duplicate full copy sitting around.
            $extractedRoot = (Get-Item $binDir).Parent.FullName
            if ((Test-Path $qpdfPath) -and ($extractedRoot -ne $qpdfDir)) {
                Remove-Item $extractedRoot -Recurse -Force
            }
        }

        Remove-Item $zipPath -Force
        Write-Status "qpdf installed to $qpdfPath" "Success"
    }
    catch {
        Write-Status "Failed to bootstrap qpdf: $($_.Exception.Message)" "Error"
        Write-Status "Manual fallback: download from https://github.com/qpdf/qpdf/releases and extract qpdf.exe + its DLLs to $qpdfDir" "Warn"
        exit 1
    }
}

# ============================================================
# TARGET RESOLUTION
# ============================================================
Write-Section "Target Resolution"

if (-not (Test-Path $Path)) {
    Write-Status "Path not found: $Path" "Error"
    exit 1
}

$item = Get-Item $Path
if ($item.PSIsContainer) {
    $searchParams = @{ Path = $Path; Filter = "*.pdf" }
    if ($Recurse) { $searchParams["Recurse"] = $true }
    $files = Get-ChildItem @searchParams
}
else {
    $files = @($item)
}

if ($files.Count -eq 0) {
    Write-Status "No PDF files found at $Path" "Warn"
    exit 0
}

Write-Status "Found $($files.Count) PDF file(s) to process" "Info"

# ============================================================
# METADATA STRIP
# ============================================================
Write-Section "Stripping Metadata"

$processed = 0
$failed = 0

foreach ($file in $files) {
    Write-Status "Processing: $($file.Name)" "Info"

    # -all= clears standard Info dict AND XMP; -overwrite_original avoids _original backup copies
    $exifArgs = @("-all=", "-overwrite_original")

    if ($KeepDates) {
        # re-apply original dates after the blanket clear
        $exifArgs = @("-all=", "-tagsFromFile", "@", "-CreateDate", "-ModifyDate", "-overwrite_original")
    }

    $exifArgs += $file.FullName

    # exiftool writes routine warnings (e.g. "PDF edits are reversible") to stderr.
    # PowerShell's $ErrorActionPreference = Stop treats ANY stderr line from a native
    # exe as terminating, even on success - so drop to Continue just for this call
    # and judge success by $LASTEXITCODE instead.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $result = & $exifPath @exifArgs 2>&1
    $ErrorActionPreference = $prevEAP

    if ($LASTEXITCODE -ne 0) {
        Write-Status "  Failed (exiftool): $($file.Name) - $result" "Error"
        $failed++
        continue
    }

    # exiftool's clear is incremental - the old /Info object's bytes are still in
    # the file, just unreferenced. Rewrite through qpdf so the file is regenerated
    # from the current object tree only, actually dropping what exiftool blanked.
    # qpdf exit codes: 0 = clean, 3 = completed with warnings (file still written
    # fine - e.g. minor structural quirks in the source PDF), 2 = actual failure.
    $tempPath = "$($file.FullName).qpdf_tmp"
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $qpdfResult = & $qpdfPath "--object-streams=generate" $file.FullName $tempPath 2>&1
    $ErrorActionPreference = $prevEAP

    if (($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) -and (Test-Path $tempPath)) {
        Move-Item $tempPath $file.FullName -Force
        Write-Status "  Cleared: $($file.Name)" "Success"
        $processed++
    }
    else {
        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
        Write-Status "  Failed (qpdf rewrite): $($file.Name) - $qpdfResult" "Error"
        $failed++
    }
}

# ============================================================
# SUMMARY
# ============================================================
Write-Section "Summary"

Write-Status "Cleared: $processed" "Success"
if ($failed -gt 0) {
    Write-Status "Failed: $failed" "Error"
}
Write-Status "Done." "Success"
