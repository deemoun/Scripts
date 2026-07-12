# Fast, reliable video merger for Windows 10/11 (PowerShell).
# Each source clip is normalized separately, then concatenated without re-encoding.
# Requirement: ffmpeg.exe and ffprobe.exe must be available in PATH.
# Install: winget install Gyan.FFmpeg

$ErrorActionPreference = "Stop"

$Output = "merged_video.mp4"
$Width = 1920
$Height = 1080
$Fps = 30
$VideoBitrate = "12M"
$VideoMaxrate = "18M"
$VideoBufsize = "24M"
$AudioBitrate = "192k"
$AudioSampleRate = 48000
$StallTimeout = 120
$CheckInterval = 5

$WorkDir = ".merge_video_work"
$LogDir = Join-Path $WorkDir "logs"
$NormalizedDir = Join-Path $WorkDir "normalized"
$ConcatList = Join-Path $WorkDir "normalized_files.txt"
$SkippedList = Join-Path $WorkDir "skipped_files.txt"

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Command-Exists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-NaturalSortKey([string]$Text) {
    return [regex]::Replace($Text.ToLowerInvariant(), '\d+', {
        param($m)
        $m.Value.PadLeft(20, '0')
    })
}

function Escape-ConcatPath([string]$Path) {
    return $Path.Replace("'", "'\''")
}

function Get-EncoderChoice {
    $encoders = (& ffmpeg.exe -hide_banner -encoders 2>&1 | Out-String)
    $choices = @(
        @{ Name = "h264_nvenc"; Extra = @("-preset", "p4", "-rc", "vbr") },
        @{ Name = "h264_qsv";   Extra = @() },
        @{ Name = "h264_amf";   Extra = @("-quality", "balanced") },
        @{ Name = "h264_mf";    Extra = @() },
        @{ Name = "libx264";    Extra = @("-preset", "veryfast") }
    )

    foreach ($choice in $choices) {
        if ($encoders -match "(?m)^\s*[A-Z\.]{6}\s+$([regex]::Escape($choice.Name))\s") {
            return $choice
        }
    }

    Fail "No usable H.264 encoder found in this FFmpeg build."
}

function Test-HasAudio([string]$Path) {
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = "ffprobe.exe"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        foreach ($arg in @(
            "-v", "error",
            "-select_streams", "a:0",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            $Path
        )) {
            [void]$psi.ArgumentList.Add($arg)
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        $text = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        return ($p.ExitCode -eq 0 -and $text -match '\d')
    }
    catch {
        return $false
    }
}

function Run-WithWatchdog {
    param(
        [string]$OutputFile,
        [string]$LogFile,
        [string[]]$Arguments
    )

    $stdoutLog = "$LogFile.stdout"
    $p = Start-Process -FilePath "ffmpeg.exe" `
        -ArgumentList $Arguments `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $LogFile

    $lastSize = -1L
    $unchanged = 0

    while (-not $p.HasExited) {
        Start-Sleep -Seconds $CheckInterval
        $p.Refresh()

        if (Test-Path -LiteralPath $OutputFile) {
            try { $size = (Get-Item -LiteralPath $OutputFile).Length }
            catch { $size = 0L }
        }
        else {
            $size = 0L
        }

        if ($size -gt $lastSize) {
            $lastSize = $size
            $unchanged = 0
        }
        else {
            $unchanged += $CheckInterval
        }

        if ($unchanged -ge $StallTimeout) {
            Write-Host "  Stalled for ${StallTimeout}s; terminating clip."
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            try { & taskkill.exe /PID $p.Id /T /F | Out-Null } catch {}
            return 124
        }
    }

    return $p.ExitCode
}

if (-not (Command-Exists "ffmpeg.exe")) {
    Fail "ffmpeg.exe is missing. Install it with: winget install Gyan.FFmpeg"
}
if (-not (Command-Exists "ffprobe.exe")) {
    Fail "ffprobe.exe is missing. Install it with: winget install Gyan.FFmpeg"
}
if (Test-Path -LiteralPath $Output) {
    Fail "$Output already exists. Rename or remove it first."
}

$encoder = Get-EncoderChoice
$VideoCodec = $encoder.Name
$EncoderExtra = [string[]]$encoder.Extra

New-Item -ItemType Directory -Force -Path $LogDir, $NormalizedDir | Out-Null
Set-Content -LiteralPath $ConcatList -Value "" -Encoding utf8
Set-Content -LiteralPath $SkippedList -Value "" -Encoding utf8

$supported = @(".mp4", ".mov", ".mkv", ".webm", ".mts", ".m2ts", ".ts")
$files = Get-ChildItem -LiteralPath "." -File |
    Where-Object {
        $supported -contains $_.Extension.ToLowerInvariant() -and $_.Name -ne $Output
    } |
    Sort-Object @{ Expression = { Get-NaturalSortKey $_.Name } }, Name

if (-not $files -or $files.Count -eq 0) {
    Fail "No supported videos found in the current folder."
}

Write-Host "Found $($files.Count) video files."
Write-Host "Work folder: $WorkDir"
Write-Host "Selected encoder: $VideoCodec"
Write-Host "Each clip is normalized separately before final merge."
Write-Host "A clip will be skipped if output does not grow for ${StallTimeout}s."
Write-Host ""

$success = 0
$skipped = 0
$index = 0

foreach ($source in $files) {
    $index++
    $stem = "{0:D6}" -f $index
    $normalized = Join-Path $NormalizedDir "$stem.mp4"
    $log = Join-Path $LogDir "$stem.log"

    Write-Host "[$index/$($files.Count)] $($source.Name)"

    if ((Test-Path -LiteralPath $normalized) -and (Get-Item -LiteralPath $normalized).Length -gt 0) {
        Write-Host "  Already normalized; reusing."
    }
    else {
        Remove-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue
        $hasAudio = Test-HasAudio $source.FullName

        $args = [System.Collections.Generic.List[string]]::new()
        foreach ($arg in @("-nostdin", "-hide_banner", "-loglevel", "warning", "-fflags", "+genpts", "-i", $source.FullName)) {
            $args.Add($arg)
        }

        if (-not $hasAudio) {
            foreach ($arg in @("-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=$AudioSampleRate")) {
                $args.Add($arg)
            }
        }

        if ($hasAudio) {
            foreach ($arg in @("-map", "0:v:0", "-map", "0:a:0?", "-af", "aresample=async=1:first_pts=0")) {
                $args.Add($arg)
            }
        }
        else {
            foreach ($arg in @("-map", "0:v:0", "-map", "1:a:0", "-shortest")) {
                $args.Add($arg)
            }
        }

        foreach ($arg in @(
            "-map_metadata", "-1",
            "-vf", "scale=${Width}:${Height}:force_original_aspect_ratio=decrease,pad=${Width}:${Height}:(ow-iw)/2:(oh-ih)/2,fps=${Fps},format=nv12",
            "-c:v", $VideoCodec
        )) {
            $args.Add($arg)
        }

        foreach ($arg in $EncoderExtra) { $args.Add($arg) }

        foreach ($arg in @(
            "-b:v", $VideoBitrate,
            "-maxrate", $VideoMaxrate,
            "-bufsize", $VideoBufsize,
            "-pix_fmt", "yuv420p",
            "-c:a", "aac",
            "-b:a", $AudioBitrate,
            "-ar", "$AudioSampleRate",
            "-ac", "2",
            "-movflags", "+faststart",
            "-y", $normalized
        )) {
            $args.Add($arg)
        }

        $code = Run-WithWatchdog -OutputFile $normalized -LogFile $log -Arguments $args.ToArray()

        if ($code -ne 0) {
            Remove-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue
            Write-Host "  Failed or stalled (exit $code); skipped. Log: $log"
            Add-Content -LiteralPath $SkippedList -Value "$($source.FullName)`tffmpeg exit`t$code"
            $skipped++
            continue
        }

        if (-not (Test-Path -LiteralPath $normalized) -or (Get-Item -LiteralPath $normalized).Length -eq 0) {
            Remove-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue
            Write-Host "  Empty normalized output; skipped."
            Add-Content -LiteralPath $SkippedList -Value "$($source.FullName)`tnormalized output empty"
            $skipped++
            continue
        }
    }

    $absolute = (Resolve-Path -LiteralPath $normalized).Path
    $escaped = Escape-ConcatPath $absolute
    Add-Content -LiteralPath $ConcatList -Value "file '$escaped'" -Encoding utf8
    $success++
}

Write-Host ""
if ($success -le 0) {
    Fail "All clips failed. Inspect $LogDir and $SkippedList."
}

Write-Host "Normalized successfully: $success"
Write-Host "Skipped: $skipped"
Write-Host "Joining normalized clips without re-encoding..."

$finalLog = Join-Path $WorkDir "final_concat.log"
$finalArgs = @(
    "-nostdin", "-hide_banner", "-loglevel", "warning",
    "-f", "concat", "-safe", "0", "-i", $ConcatList,
    "-c", "copy", "-movflags", "+faststart", "-y", $Output
)

$final = Start-Process -FilePath "ffmpeg.exe" -ArgumentList $finalArgs `
    -NoNewWindow -PassThru -Wait `
    -RedirectStandardError $finalLog `
    -RedirectStandardOutput "$finalLog.stdout"

if ($final.ExitCode -eq 0) {
    Write-Host ""
    Write-Host "Done: $Output"
    Write-Host "Skipped-file report: $SkippedList"
    Write-Host "Per-clip logs: $LogDir"
    Write-Host "Normalized clips kept for resume: $NormalizedDir"
}
else {
    Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
    Fail "Final concatenation failed. Check: $finalLog"
}
