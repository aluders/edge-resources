param(
    [string]$Path = $PSScriptRoot,
    [switch]$Test,
    [switch]$Clean
)

# --- CONFIGURATION ---
$mkvmergePath = "C:\Program Files\MKVToolNix\mkvmerge.exe"
# ---------------------

# 1. SETUP
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
        $outputFile = Join-Path -Path $file.DirectoryName -ChildPath ($file.BaseName + ".mkv")
    }
    elseif ($file.Extension -eq ".mkv") {
        if ($file.Name -like "*.en.mkv") { continue }
        $outputFile = Join-Path -Path $file.DirectoryName -ChildPath ($file.BaseName + ".en.mkv")
    }

    # --- CLEAN LOGIC ---
    if ($Clean) {
        if (Test-Path $outputFile) {
            if ($file.FullName -eq $outputFile) {
                Write-Host "Safety Check: Source and Output are identical. Skipping delete." -ForegroundColor Red
            } else {
                Remove-Item $file.FullName -Force
                Write-Host "Deleted source: $($file.Name)" -ForegroundColor Green
            }
        } else {
            Write-Host "Skipped delete: $($file.Name) (No processed version found)" -ForegroundColor Red
        }
        if ($Test) { break }
        continue
    }

    Write-Host "Processing: $($file.Name)" -ForegroundColor Yellow

    # --- STEP A: INSPECT VIDEO FILE ---
    try {
        $jsonOutput = & $mkvmergePath -J $file.FullName
        $fileInfo = $jsonOutput | ConvertFrom-Json
    }
    catch {
        Write-Host "  Error reading file info. Skipping." -ForegroundColor Red
        continue
    }

    $videoArgs = @()
    if ($fileInfo.tracks) {
        foreach ($track in $fileInfo.tracks) {
            if ($track.type -eq "video") {
                $videoArgs += "--language"
                $videoArgs += "$($track.id):eng"
            }
            elseif ($track.type -eq "audio") {
                $videoArgs += "--language"
                $videoArgs += "$($track.id):eng"
            }
        }
    }

    # --- STEP B: LOOK FOR EXTERNAL SUBS ---
    $subDir = Join-Path -Path $file.DirectoryName -ChildPath "Subs"
    $specificSubFolder = Join-Path -Path $subDir -ChildPath $file.BaseName

    $srtArgs = @()

    if (Test-Path $specificSubFolder) {
        # Loop through ALL .srt files found, but FORCE deterministic ordering:
        # non-SDH first, SDH second (then by name)
        $srtFiles = Get-ChildItem -Path $specificSubFolder -Filter *.srt |
            Sort-Object @{ Expression = { $_.Name -match 'SDH' }; Ascending = $true }, Name

        foreach ($srt in $srtFiles) {
            Write-Host "  + Found Subtitle: $($srt.Name)" -ForegroundColor Cyan

            # Use 0:eng for language (track 0 of the upcoming subtitle file)
            $srtArgs += "--language"
            $srtArgs += "0:eng"

            # Check for SDH
            if ($srt.Name -match "SDH") {
                Write-Host "    (Marking as SDH)" -ForegroundColor DarkCyan

                # Correct mkvmerge option name
                $srtArgs += "--hearing-impaired-flag"
                $srtArgs += "0:1"
            }

            $srtArgs += "$($srt.FullName)"
        }
    }

    # --- STEP C: EXECUTE MERGE ---
    $argumentList = @("-o", "$outputFile") + $videoArgs + @("$($file.FullName)") + $srtArgs

    # Run command and capture output
    $mergeResult = & $mkvmergePath $argumentList 2>&1

    # Check for Success (0) or Warning (1)
    if ($LASTEXITCODE -le 1) {
        if ($LASTEXITCODE -eq 1) {
            Write-Host "  Success (with Warnings): $outputFile" -ForegroundColor Green
        } else {
            Write-Host "  Success: $outputFile" -ForegroundColor Green
        }
    } else {
        Write-Host "  Failed to convert (Exit Code $LASTEXITCODE)" -ForegroundColor Red
        Write-Host "  --- ERROR OUTPUT ---" -ForegroundColor Red
        $mergeResult | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Write-Host "  --------------------" -ForegroundColor Red
    }

    if ($Test) {
        Write-Host "Test complete. Stopping." -ForegroundColor Magenta
        break
    }
}

if (-not $Test) {
    Write-Host "Batch processing complete." -ForegroundColor Cyan
}
