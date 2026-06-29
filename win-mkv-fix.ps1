param(
    [string]$Path = $PSScriptRoot,
    [switch]$Test,
    [switch]$Clean,
    [switch]$Help
)

# --- CONFIGURATION ---
$mkvmergePath = "C:\Program Files\MKVToolNix\mkvmerge.exe"
# ---------------------

# 1. HELP
if ($Help) {
    Write-Host ""
    Write-Host "  Convert-ToMKV.ps1 - Batch MKV Processor" -ForegroundColor Cyan
    Write-Host "  -------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  USAGE" -ForegroundColor Yellow
    Write-Host "    .\Convert-ToMKV.ps1 [options]"
    Write-Host ""
    Write-Host "  OPTIONS" -ForegroundColor Yellow
    Write-Host "    -Path <folder>    Folder to scan. Defaults to the script's own directory."
    Write-Host "                      Accepts local paths, mapped drives (Z:\Movies),"
    Write-Host "                      and UNC paths (\\server\share\Movies)."
    Write-Host "                      Folder names with brackets [ ] are supported."
    Write-Host "    -Test             Process only the first file found, then stop."
    Write-Host "    -Clean            Delete source files where a processed output already exists."
    Write-Host "    -Help             Show this help message."
    Write-Host ""
    Write-Host "  WHAT IT DOES" -ForegroundColor Yellow
    Write-Host "    - .mp4 files     Remuxed to .mkv, video+audio tracks tagged as English"
    Write-Host "    - .mkv files     Reprocessed to .BaseName.en.mkv (skips files already ending in .en.mkv)"
    Write-Host "    - Subtitles      Searched alongside the video first, then recursively under"
    Write-Host "                     -Path in any subfolder. SDH subs are flagged hearing-impaired."
    Write-Host "                     Non-SDH always comes before SDH in track order."
    Write-Host ""
    Write-Host "  SUBTITLE SEARCH" -ForegroundColor Yellow
    Write-Host "    Two strategies are tried in order; first match wins:"
    Write-Host ""
    Write-Host "    1. Sibling files - SRTs in the same folder as the video, named:"
    Write-Host "         video.srt"
    Write-Host "         video.en.srt"
    Write-Host "         video.eng.srt"
    Write-Host "         video.en.SDH.srt   <- flagged hearing-impaired"
    Write-Host "         video.fra.srt       <- ignored (not en/eng)"
    Write-Host ""
    Write-Host "    2. Recursive search - looks anywhere under -Path for SRT files"
    Write-Host "       starting with the video's BaseName. Subfolder name doesn't matter."
    Write-Host "         D:\Movies\Subs\MovieName.eng.srt"
    Write-Host "         D:\Movies\Subs\SomeFolder\MovieName.eng.SDH.srt"
    Write-Host ""
    Write-Host "    In both cases: non-SDH tracks always come before SDH in the output."
    Write-Host ""
    Write-Host "  CLEAN MODE" -ForegroundColor Yellow
    Write-Host "    Deletes the original source file only if the expected output already exists."
    Write-Host "    Safe to combine with -Test to preview on one file first."
    Write-Host "    Will never delete a file if source and output path are identical."
    Write-Host ""
    Write-Host "  EXIT CODES (mkvmerge)" -ForegroundColor Yellow
    Write-Host "    0 = Success   1 = Success with warnings   2+ = Failure"
    Write-Host ""
    Write-Host "  EXAMPLES" -ForegroundColor Yellow
    Write-Host "    .\Convert-ToMKV.ps1"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Test"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Clean"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Clean -Test"
    Write-Host "    .\Convert-ToMKV.ps1 -Path Z:\Movies              <- mapped drive"
    Write-Host "    .\Convert-ToMKV.ps1 -Path \\server\share\Movies  <- UNC path"
    Write-Host "    .\Convert-ToMKV.ps1 -Path 'X:\TV\Show [2024]'   <- brackets in name"
    Write-Host ""
    Exit
}

# 2. SETUP
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

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "Error: The folder '$Path' does not exist." -ForegroundColor Red
    Exit
}

Write-Host "Scanning folder: $Path" -ForegroundColor Cyan
$files = Get-ChildItem -LiteralPath $Path -Recurse -Include *.mp4, *.mkv | Sort-Object FullName

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
        if (Test-Path -LiteralPath $outputFile) {
            if ($file.FullName -eq $outputFile) {
                Write-Host "Safety Check: Source and Output are identical. Skipping delete." -ForegroundColor Red
            } else {
                Remove-Item -LiteralPath $file.FullName -Force
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
    # Strategy 1: SRT files sitting alongside the video in the same directory.
    # Accept: <BaseName>.srt, <BaseName>.en.srt, <BaseName>.eng.srt, <BaseName>.en.SDH.srt, etc.
    # Reject: any other language tag (e.g. .fra. .spa.)
    # Note: Get-ChildItem -Filter does not support wildcards in LiteralPath mode, so we
    # use -LiteralPath with -Filter for the directory, then match filenames manually.
    $srtArgs = @()

    $srtSource = Get-ChildItem -LiteralPath $file.DirectoryName -Filter "*.srt" |
        Where-Object { $_.BaseName -like "$($file.BaseName)*" } |
        Where-Object { $_.Name -eq "$($file.BaseName).srt" -or $_.Name -match '\.(eng|en)[\.\-]' } |
        Sort-Object @{ Expression = { $_.Name -match 'SDH' }; Ascending = $true }, Name

    if ($srtSource.Count -gt 0) {
        Write-Host "  Subs: found alongside video" -ForegroundColor DarkGray
    }
    else {
        # Strategy 2: recursive search anywhere under $Path for SRTs starting with the
        # video's BaseName. Subfolder name doesn't matter.
        $srtSource = Get-ChildItem -LiteralPath $Path -Recurse -Filter "*.srt" |
            Where-Object { $_.BaseName -like "$($file.BaseName)*" } |
            Where-Object { $_.Name -eq "$($file.BaseName).srt" -or $_.Name -match '\.(eng|en)[\.\-]' } |
            Sort-Object @{ Expression = { $_.Name -match 'SDH' }; Ascending = $true }, Name

        if ($srtSource.Count -gt 0) {
            Write-Host "  Subs: found in $($srtSource[0].DirectoryName)" -ForegroundColor DarkGray
        }
    }

    foreach ($srt in $srtSource) {
        Write-Host "  + Found Subtitle: $($srt.Name)" -ForegroundColor Cyan

        $srtArgs += "--language"
        $srtArgs += "0:eng"

        if ($srt.Name -match "SDH") {
            Write-Host "    (Marking as SDH)" -ForegroundColor DarkCyan
            $srtArgs += "--hearing-impaired-flag"
            $srtArgs += "0:1"
        }

        $srtArgs += "$($srt.FullName)"
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
