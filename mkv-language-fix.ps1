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

# --- CHANGED: Filter for both .mp4 and .mkv ---
$files = Get-ChildItem -Path $Path -Recurse -Include *.mp4, *.mkv | Sort-Object FullName

if ($files.Count -eq 0) {
    Write-Host "No .mp4 or .mkv files found." -ForegroundColor Yellow
    Exit
}

# --- MODE ANNOUNCEMENTS ---
if ($Clean) {
    Write-Host "--- CLEAN MODE ACTIVE ---" -ForegroundColor Magenta
    Write-Host "Deleting source files ONLY if a processed version exists." -ForegroundColor Magenta
}
elseif ($Test) {
    Write-Host "--- TEST MODE ACTIVE ---" -ForegroundColor Magenta
    Write-Host "Processing only the first file found." -ForegroundColor Magenta
}
else {
    Write-Host "Found $($files.Count) files to process..." -ForegroundColor Cyan
}

foreach ($file in $files) {
    # --- DETERMINE OUTPUT FILENAME ---
    if ($file.Extension -eq ".mp4") {
        # MP4 -> MKV
        $outputFile = Join-Path -Path $file.DirectoryName -ChildPath ($file.BaseName + ".mkv")
    }
    elseif ($file.Extension -eq ".mkv") {
        # Skip if this is already an output file (prevents processing .en.mkv files)
        if ($file.Name -like "*.en.mkv") {
            Write-Host "Skipping output file: $($file.Name)" -ForegroundColor DarkGray
            continue
        }
        # MKV -> .en.MKV
        $outputFile = Join-Path -Path $file.DirectoryName -ChildPath ($file.BaseName + ".en.mkv")
    }

    # --- CLEAN LOGIC ---
    if ($Clean) {
        if (Test-Path $outputFile) {
            # Double check we aren't deleting the output file by mistake
            if ($file.FullName -eq $outputFile) {
                Write-Host "Safety Check: Source and Output are identical. Skipping delete." -ForegroundColor Red
            } else {
                Remove-Item $file.FullName -Force
                Write-Host "Deleted source: $($file.Name) (Processed version verified)" -ForegroundColor Green
            }
        } else {
            Write-Host "Skipped delete: $($file.Name) (No processed version found)" -ForegroundColor Red
        }

        if ($Test) { break }
        continue
    }

    # --- CONVERSION LOGIC ---
    Write-Host "Processing: $($file.Name)" -ForegroundColor Yellow

    try {
        $jsonOutput = & $mkvmergePath -J $file.FullName
        $fileInfo = $jsonOutput | ConvertFrom-Json
    }
    catch {
        Write-Host "  Error reading file info. Skipping." -ForegroundColor Red
        continue
    }

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
