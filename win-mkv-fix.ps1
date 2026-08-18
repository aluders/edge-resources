param(
    [string]$Path = $PSScriptRoot,
    [string]$Remove = "",
    [switch]$Test,
    [string]$CleanSearch = "",
    [switch]$Clean,
    [switch]$Strip,
    [switch]$Help
)

# Convert-ToMKV.ps1 - v1.3
#
# Batch remuxes .mp4 and .mkv files into language-tagged MKVs using mkvmerge.
# Picks up external SRT subtitle files automatically.
#
# WHAT IT DOES:
#   - .mp4 files: remuxed to .mkv, video and audio tracks tagged as English
#   - .mkv files: reprocessed to .BaseName.en.mkv (skips files already ending in .en.mkv)
#   - Subtitles: searched alongside the video first, then recursively anywhere
#     under -Path. Folder name doesn't matter. SDH subs are flagged hearing-impaired.
#     Non-SDH always comes before SDH in track order.
#   - Subtitle language filter: only .en. or .eng. SRT files are included.
#     Others (e.g. .fra. .spa.) are ignored.
#   - Strip mode: remuxes .mkv files keeping only English (and untagged) audio
#     and subtitle tracks. Outputs as .BaseName.en.mkv. Skips .en.mkv files.
#     Skips with a warning if the output already exists.
#   - Remove: strips literal strings from the output filename before writing.
#     Comma-separated.
#   - CleanSearch: deletes source files whose name contains a given string, if a
#     corresponding output (with that string removed) exists in the same folder.
#
# USAGE:
#   .\Convert-ToMKV.ps1 [-Path <folder>] [-Remove <string>] [-CleanSearch <string>] [-Test] [-Clean] [-Strip] [-Help]
#
#   -Path      Folder to scan. Defaults to the script's own directory.
#              Accepts local paths, mapped drives (Z:\Movies), UNC paths,
#              and paths with special characters like brackets [ ].
#   -Remove    Comma-separated literal strings to strip from output filenames.
#              Spaces are preserved inside quoted values.
#              Example: -Remove ".Rus.Eng"
#              Example: -Remove ".Rus.Eng,.REPACK,.PROPER"
#              Example: -Remove '.Rus.Eng'  (include leading dot to avoid double-dot)
#   -Test      Process only the first file found, then stop.
#   -Clean        Delete source files where a processed output already exists.
#   -CleanSearch  Delete source files containing a given string, if the expected
#                 output (with that string removed) exists alongside it.
#                 Example: -CleanSearch '.Rus.Eng'
#   -Strip     Strip non-English audio and subtitle tracks from MKV files.
#              Outputs as .BaseName.en.mkv. Skips files already ending in .en.mkv.
#              Untagged tracks are kept. Run -Clean afterward to remove originals.
#   -Help      Show the built-in help screen.
#
# DEPLOY:
#   irm https://scripts.vcc.net/Convert-ToMKV.ps1 | iex
#
# NOTES:
#   Requires MKVToolNix installed at the default path or available in system PATH.
#   All path handling uses -LiteralPath to safely support brackets and other
#   special characters in folder/file names.
#   -Strip and -Clean work well together: strip first, verify output, then clean.
#   -Remove can be combined with any mode including -Strip.
#
# CHANGELOG (newest first):
#   1.3 - Added -CleanSearch flag: deletes source files by search string match
#         Looks for matching output (string removed) in the same folder
#         Same safety check as -Clean (never deletes if source equals output)
#   1.2 - Added -Remove flag: strips literal strings from output filenames
#         Supports comma-separated list and quoted strings with spaces
#         No automatic cleanup - removals are applied exactly as specified
#   1.1 - Added -Strip mode: removes non-English audio and subtitle tracks from MKVs
#         Outputs as .BaseName.en.mkv, skips .en.mkv inputs, skips if output exists
#         Untagged tracks are preserved
#         Version number shown in -Help banner
#         Moved param block to line 1 (required by PowerShell)
#   1.0 - Initial release
#         Remux mp4 to mkv, retag mkv as .en.mkv
#         English track tagging for video and audio
#         External SRT pickup: sibling files first, recursive fallback
#         SDH detection and hearing-impaired flagging
#         -Test, -Clean, -Help flags
#         -LiteralPath throughout for bracket-safe path handling

$VERSION = "1.3"

# --- CONFIGURATION ---
$mkvmergePath = "C:\Program Files\MKVToolNix\mkvmerge.exe"
# ---------------------

# --- HELPER: Apply -Remove to a basename ---
function Invoke-RemoveStrings {
    param([string]$BaseName, [string[]]$Removals)
    $result = $BaseName
    foreach ($r in $Removals) {
        $result = $result.Replace($r, "")
    }
    return $result
}

# 1. HELP
if ($Help) {
    Write-Host ""
    Write-Host "  Convert-ToMKV.ps1 v$VERSION - Batch MKV Processor" -ForegroundColor Cyan
    Write-Host "  -------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  USAGE" -ForegroundColor Yellow
    Write-Host "    .\Convert-ToMKV.ps1 [options]"
    Write-Host ""
    Write-Host "  OPTIONS" -ForegroundColor Yellow
    Write-Host "    -Path <folder>      Folder to scan. Defaults to the script's own directory."
    Write-Host "                        Accepts local paths, mapped drives (Z:\Movies),"
    Write-Host "                        UNC paths, and names with brackets [ ]."
    Write-Host "    -Remove <string>    Comma-separated literal strings to strip from output"
    Write-Host "                        filenames. Quotes preserve spaces."
    Write-Host "    -Test               Process only the first file found, then stop."
    Write-Host "    -Clean              Delete source files where a processed output already exists."
    Write-Host "    -CleanSearch <str>  Delete source files whose name contains <str>, if the"
    Write-Host "                        expected output (with <str> removed) exists alongside it."
    Write-Host "                        Example: -CleanSearch '.Rus.Eng'"
    Write-Host "    -Strip              Strip non-English audio and subtitle tracks from MKV files."
    Write-Host "                        Outputs as .BaseName.en.mkv. Skips .en.mkv inputs."
    Write-Host "                        Skips with a warning if output already exists."
    Write-Host "                        Untagged tracks are preserved."
    Write-Host "    -Help               Show this help message."
    Write-Host ""
    Write-Host "  REMOVE EXAMPLES" -ForegroundColor Yellow
    Write-Host "    -Remove '.Rus.Eng'"
    Write-Host "      The.IT.Crowd.S01E01.1080p.Rus.Eng.mkv -> The.IT.Crowd.S01E01.1080p.en.mkv"
    Write-Host ""
    Write-Host "    -Remove '.Rus.Eng,.REPACK'"
    Write-Host "      Show.S01E01.REPACK.1080p.Rus.Eng.mkv  -> Show.S01E01.1080p.en.mkv"
    Write-Host ""
    Write-Host "    -Remove '.Rus.Eng'  (include leading dot to avoid double-dot in output)"
    Write-Host "      Show.S01E01.1080p.Rus.Eng .mkv        -> Show.S01E01.1080p.en.mkv"
    Write-Host ""
    Write-Host "  WHAT IT DOES" -ForegroundColor Yellow
    Write-Host "    - .mp4 files     Remuxed to .mkv, video+audio tracks tagged as English"
    Write-Host "    - .mkv files     Reprocessed to .BaseName.en.mkv (skips *.en.mkv files)"
    Write-Host "    - Subtitles      Searched alongside the video first, then recursively"
    Write-Host "                     under -Path in any subfolder. Folder name doesn't matter."
    Write-Host "                     SDH subs are flagged hearing-impaired."
    Write-Host "                     Non-SDH always comes before SDH in track order."
    Write-Host ""
    Write-Host "  STRIP MODE" -ForegroundColor Yellow
    Write-Host "    Scans MKV files and drops any audio or subtitle track not tagged as"
    Write-Host "    English (eng). Untagged tracks are kept. Video tracks are always kept."
    Write-Host "    Input .en.mkv files are skipped (assumed already processed)."
    Write-Host "    If the output .en.mkv already exists, the file is skipped with a warning."
    Write-Host "    Recommended workflow:"
    Write-Host "      1. .\Convert-ToMKV.ps1 -Path D:\Movies -Strip"
    Write-Host "      2. Verify the .en.mkv outputs look correct"
    Write-Host "      3. .\Convert-ToMKV.ps1 -Path D:\Movies -Clean"
    Write-Host ""
    Write-Host "  SUBTITLE SEARCH (normal mode)" -ForegroundColor Yellow
    Write-Host "    Two strategies tried in order; first match wins:"
    Write-Host ""
    Write-Host "    1. Sibling files - SRTs in the same folder as the video:"
    Write-Host "         video.srt"
    Write-Host "         video.en.srt / video.eng.srt"
    Write-Host "         video.en.SDH.srt   <- flagged hearing-impaired"
    Write-Host "         video.fra.srt       <- ignored (not en/eng)"
    Write-Host ""
    Write-Host "    2. Recursive search - any SRT starting with the video's BaseName,"
    Write-Host "       anywhere under -Path. Subfolder name doesn't matter."
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
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Remove '.Rus.Eng'"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Remove '.Rus.Eng,.REPACK,.PROPER'"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Strip -Remove '.Rus.Eng'"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Test"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Strip"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Strip -Test"
    Write-Host "    .\Convert-ToMKV.ps1 -Path D:\Movies -Clean"
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

# Parse -Remove into an array of literal strings
$removeList = @()
if ($Remove -ne "") {
    $removeList = $Remove -split "," | ForEach-Object { $_ }
    Write-Host "Remove strings: $($removeList -join ' | ')" -ForegroundColor DarkGray
}

Write-Host "Scanning folder: $Path" -ForegroundColor Cyan
$files = Get-ChildItem -LiteralPath $Path -Recurse -Include *.mp4, *.mkv | Sort-Object FullName

if ($files.Count -eq 0) {
    Write-Host "No .mp4 or .mkv files found." -ForegroundColor Yellow
    Exit
}

# --- MODE ANNOUNCEMENTS ---
if ($Strip) {
    Write-Host "--- STRIP MODE ACTIVE ---" -ForegroundColor Magenta
    Write-Host "Removing non-English audio and subtitle tracks from MKV files." -ForegroundColor Magenta
}
elseif ($CleanSearch -ne "") {
    Write-Host "--- CLEANSEARCH MODE ACTIVE ---" -ForegroundColor Magenta
    Write-Host "Deleting source files containing: $CleanSearch" -ForegroundColor Magenta
}
elseif ($Clean) {
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
    # --- DETERMINE OUTPUT BASENAME (apply -Remove if set) ---
    $outBaseName = $file.BaseName
    if ($removeList.Count -gt 0) {
        $outBaseName = Invoke-RemoveStrings -BaseName $outBaseName -Removals $removeList
    }

    # --- DETERMINE OUTPUT FILENAME ---
    if ($file.Extension -eq ".mp4") {
        $outputFile = Join-Path -Path $file.DirectoryName -ChildPath ($outBaseName + ".mkv")
    }
    elseif ($file.Extension -eq ".mkv") {
        if ($file.Name -like "*.en.mkv") { continue }
        $outputFile = Join-Path -Path $file.DirectoryName -ChildPath ($outBaseName + ".en.mkv")
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

    # --- CLEANSEARCH LOGIC ---
    if ($CleanSearch -ne "") {
        # Only process files whose name contains the search string
        if ($file.Name -notlike "*$CleanSearch*") { continue }

        # Build the expected output name by removing the search string from the basename
        $searchOutBase = $file.BaseName.Replace($CleanSearch, "")
        $searchOutFile = Join-Path -Path $file.DirectoryName -ChildPath ($searchOutBase + ".en.mkv")

        Write-Host "CleanSearch: $($file.Name)" -ForegroundColor Yellow
        Write-Host "  Looking for: $($searchOutBase).en.mkv" -ForegroundColor DarkGray

        if (Test-Path -LiteralPath $searchOutFile) {
            if ($file.FullName -eq $searchOutFile) {
                Write-Host "  Safety Check: Source and Output are identical. Skipping delete." -ForegroundColor Red
            } else {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-Host "  Deleted: $($file.Name)" -ForegroundColor Green
            }
        } else {
            Write-Host "  Skipped: output not found ($($searchOutBase).en.mkv)" -ForegroundColor Red
        }
        if ($Test) { break }
        continue
    }

    # --- STRIP LOGIC ---
    if ($Strip) {
        if ($file.Extension -ne ".mkv") { continue }

        Write-Host "Stripping: $($file.Name)" -ForegroundColor Yellow
        if ($outBaseName -ne $file.BaseName) {
            Write-Host "  Output name: $outBaseName.en.mkv" -ForegroundColor DarkGray
        }

        # Skip if output already exists
        if (Test-Path -LiteralPath $outputFile) {
            Write-Host "  Skipped: $($outBaseName).en.mkv already exists." -ForegroundColor DarkYellow
            if ($Test) { break }
            continue
        }

        # Inspect the file
        try {
            $jsonOutput = & $mkvmergePath -J $file.FullName
            $fileInfo = $jsonOutput | ConvertFrom-Json
        }
        catch {
            Write-Host "  Error reading file info. Skipping." -ForegroundColor Red
            continue
        }

        $audioKeep = @()
        $subsKeep = @()
        $audioDropped = 0
        $subsDropped = 0

        foreach ($track in $fileInfo.tracks) {
            $lang = $track.properties.language
            $isEnglish = ($lang -eq "eng" -or $lang -eq "en")
            $isUntagged = ([string]::IsNullOrWhiteSpace($lang) -or $lang -eq "und")

            if ($track.type -eq "audio") {
                if ($isEnglish -or $isUntagged) {
                    $audioKeep += $track.id
                } else {
                    Write-Host "  - Dropping audio track $($track.id): $lang" -ForegroundColor DarkGray
                    $audioDropped++
                }
            }
            elseif ($track.type -eq "subtitles") {
                if ($isEnglish -or $isUntagged) {
                    $subsKeep += $track.id
                } else {
                    Write-Host "  - Dropping subtitle track $($track.id): $lang" -ForegroundColor DarkGray
                    $subsDropped++
                }
            }
        }

        $stripArgs = @("-o", "$outputFile")

        if ($audioKeep.Count -gt 0) {
            $stripArgs += "--audio-tracks"
            $stripArgs += ($audioKeep -join ",")
        } else {
            $stripArgs += "--no-audio"
        }

        if ($subsKeep.Count -gt 0) {
            $stripArgs += "--subtitle-tracks"
            $stripArgs += ($subsKeep -join ",")
        } else {
            $stripArgs += "--no-subtitles"
        }

        $stripArgs += "$($file.FullName)"

        $mergeResult = & $mkvmergePath $stripArgs 2>&1

        if ($LASTEXITCODE -le 1) {
            $summary = "  Done: dropped $audioDropped audio, $subsDropped subtitle track(s)"
            if ($LASTEXITCODE -eq 1) {
                Write-Host "$summary (with warnings)" -ForegroundColor Green
            } else {
                Write-Host "$summary" -ForegroundColor Green
            }
        } else {
            Write-Host "  Failed (Exit Code $LASTEXITCODE)" -ForegroundColor Red
            $mergeResult | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        }

        if ($Test) {
            Write-Host "Test complete. Stopping." -ForegroundColor Magenta
            break
        }
        continue
    }

    # --- NORMAL PROCESSING ---
    Write-Host "Processing: $($file.Name)" -ForegroundColor Yellow
    if ($outBaseName -ne $file.BaseName) {
        Write-Host "  Output name: $outBaseName.en.mkv" -ForegroundColor DarkGray
    }

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
    $srtArgs = @()

    $srtSource = Get-ChildItem -LiteralPath $file.DirectoryName -Filter "*.srt" |
        Where-Object { $_.BaseName -like "$($file.BaseName)*" } |
        Where-Object { $_.Name -eq "$($file.BaseName).srt" -or $_.Name -match '\.(eng|en)[\.\-]' } |
        Sort-Object @{ Expression = { $_.Name -match 'SDH' }; Ascending = $true }, Name

    if ($srtSource.Count -gt 0) {
        Write-Host "  Subs: found alongside video" -ForegroundColor DarkGray
    }
    else {
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

    $mergeResult = & $mkvmergePath $argumentList 2>&1

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
