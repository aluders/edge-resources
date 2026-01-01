param(
    [string]$Path = $PSScriptRoot,
    [switch]$Test,
    [switch]$Clean
)

# --- CONFIGURATION ---
$mkvmergePath = "C:\Program Files\MKVToolNix\mkvmerge.exe"
# ---------------------

# 1. SETUP: Verify mkvmerge exists (skip check if just cleaning)
if (-not $Clean) {
    if (-not (Test-Path $mkvmergePath)) {
        if (Get-Command "mkvmerge" -ErrorAction SilentlyContinue) {
            $mkvmergePath = "mkvmerge"
        } else {
            Write-Host "Error: mkvmerge not found at '$mkvmergePath' or in system PATH." -ForegroundColor Red
            Exit
        }
    }
}

if (-not (Test-Path $Path)) {
    Write-Host "Error: The folder '$Path' does not exist." -ForegroundColor Red
    Exit
}

Write-Host "Scanning folder: $Path" -ForegroundColor Cyan
$files = Get-ChildItem -Path $Path -Recurse -Filter *.mp4

if ($files.Count -eq 0) {
    Write-Host "No .mp4 files found." -ForegroundColor Yellow
    Exit
}

# --- MODE ANNOUNCEMENTS ---
if ($Clean) {
    Write-Host "--- CLEAN MODE ACTIVE ---" -ForegroundColor Magenta
    Write-Host "Deleting .mp4 files ONLY if a matching .mkv exists." -ForegroundColor Magenta
}
elseif ($Test) {
    Write-Host "--- TEST MODE ACTIVE ---" -ForegroundColor Magenta
    Write-Host "Processing only the first file found." -ForegroundColor Magenta
}
else {
    Write-Host "Found $($files.Count) files to process..." -ForegroundColor Cyan
}

foreach ($file in $files) {
    $outputFile = Join-Path -Path $file.DirectoryName -ChildPath ($file.BaseName + ".mkv")

    # --- CLEAN LOGIC ---
    if ($Clean) {
        if (Test-Path $outputFile) {
            Remove-Item $file.FullName -Force
            Write-Host "Deleted: $($file.Name) (MKV verified)" -ForegroundColor Green
        } else {
            Write-Host "Skipped: $($file.Name) (No matching MKV found)" -ForegroundColor Red
        }

        # If testing clean mode, stop after one
        if ($Test) { break }
        continue
    }

    # --- CONVERSION LOGIC ---
    Write-Host "Processing: $($file.Name)" -ForegroundColor Yellow

    try {
        # Inspect file for tracks
        $jsonOutput = & $mkvmergePath -J $file.FullName
        $fileInfo = $jsonOutput | ConvertFrom-Json
    }
    catch {
        Write-Host "  Error reading file info. Skipping." -ForegroundColor Red
        continue
    }

    # Build Arguments
    $langArgs = @()
    if ($fileInfo.tracks) {
        foreach ($track in $fileInfo.tracks) {
            if ($track.type -eq "video") {
                $langArgs += "--language"
                $langArgs += "$($track.id):eng"
            }
            elseif ($track.type -eq "audio") {
                $langArgs += "--language"
                $langArgs += "$($track.id):eng"
            }
        }
    }

    # Execute mkvmerge
    $argumentList = @("-o", "$outputFile") + $langArgs + @("$($file.FullName)")

    & $mkvmergePath $argumentList | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Success: $outputFile" -ForegroundColor Green
    } else {
        Write-Host "  Failed to convert." -ForegroundColor Red
    }

    if ($Test) {
        Write-Host "Test complete. Stopping." -ForegroundColor Magenta
        break
    }
}

if (-not $Test) {
    Write-Host "Batch processing complete." -ForegroundColor Cyan
}
