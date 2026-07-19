# Duplicate-safe chronological video merger for Windows 10/11.
#
# Each unique source clip is normalized separately and then concatenated
# without re-encoding. Original source files are never modified or deleted.
#
# Main protections and behavior:
#   - SHA-256 exact deduplication.
#   - Hidden/system files, AppleDouble files, macOS metadata, recycle bins,
#     stale work caches, package/library folders, temporary downloads,
#     symlinks, and junctions are ignored before hashing.
#   - The normalized cache is bound to source SHA-256 + export settings.
#   - Normal videos are placed before very short likely Live Photo clips.
#   - Reliable capture timestamps are sorted chronologically.
#   - Files with unclear timestamps are placed last within their video class.
#   - The final concat list is rebuilt and checked for duplicate entries.
#   - A CSV timeline records source metadata, timing, GPS, codecs, and hashes.
#
# Requirement:
#   ffmpeg.exe and ffprobe.exe must be available in PATH.
#
# Install with Windows Package Manager:
#   winget install Gyan.FFmpeg

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# =========================
# User settings
# =========================

$OutputName = "merged_video.mp4"
$TimelineName = "merged_video_timeline.csv"

$Width = 1920
$Height = 1080
$Fps = 30

# iPhone Live Photo motion clips are normally around three seconds.
$LikelyLivePhotoMaxSeconds = 4.0

# Hardware encoding is tested before it is selected. If no hardware encoder
# works, the script falls back to libx264.
$PreferHardwareEncoding = $true

$VideoBitrate = "12M"
$VideoMaxrate = "18M"
$VideoBufsize = "24M"
$VideoPreset = "fast"
$VideoCrf = 18

$AudioCodec = "aac"
$AudioBitrate = "192k"
$AudioSampleRate = 48000

# For very large archive outputs, false avoids an additional MP4 finalization
# pass. Set to true if faster browser playback startup is important.
$EnableFaststart = $false

# Stop one conversion when its output file does not grow for this long.
$StallTimeout = 120
$CheckInterval = 5

# =========================
# Internal paths
# =========================

$StartDir = (Get-Location).Path
$Output = Join-Path $StartDir $OutputName
$TimelineOutput = Join-Path $StartDir $TimelineName

$WorkDir = Join-Path $StartDir ".merge_video_work"
$LogDir = Join-Path $WorkDir "logs"
$NormalizedDir = Join-Path $WorkDir "normalized"
$ConcatList = Join-Path $WorkDir "normalized_files.txt"
$SkippedReport = Join-Path $WorkDir "skipped_files.csv"
$DuplicateReport = Join-Path $WorkDir "duplicate_sources.csv"
$ManifestReport = Join-Path $WorkDir "manifest.csv"
$OrderReport = Join-Path $WorkDir "normalized_order.csv"
$FinalLog = Join-Path $WorkDir "final_concat.log"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$FloatStyles = [System.Globalization.NumberStyles]::Float
$DateStyles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [System.Globalization.DateTimeStyles]::AssumeUniversal

function Fail([string]$Message) {
    Write-Error $Message
    exit 1
}

function Command-Exists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Write-Utf8NoBomLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines
    )

    [System.IO.File]::WriteAllLines($Path, $Lines, $script:Utf8NoBom)
}

function Write-Utf8NoBomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

# Build a Windows command line that preserves spaces, quotes, trailing
# backslashes, Unicode paths, and empty arguments in Windows PowerShell 5.1
# as well as modern PowerShell.
function Quote-NativeArgument([AllowEmptyString()][string]$Argument) {
    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            if ($backslashes -gt 0) {
                [void]$builder.Append(('\' * ($backslashes * 2)))
            }
            [void]$builder.Append('\')
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }

        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-NativeArguments([string[]]$Arguments) {
    return (($Arguments | ForEach-Object { Quote-NativeArgument ([string]$_) }) -join ' ')
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = $script:StartDir
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-NativeArguments $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderrTask.Result
    }
}

function Run-WithWatchdog {
    param(
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [Parameter(Mandatory = $true)][string]$LogFile,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $stdoutLog = "$LogFile.stdout"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ffmpeg.exe"
    $psi.Arguments = Join-NativeArguments $Arguments
    $psi.WorkingDirectory = $script:StartDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $lastSize = -1L
    $unchangedSeconds = 0
    $timedOut = $false

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $script:CheckInterval
        $process.Refresh()

        if (Test-Path -LiteralPath $OutputFile) {
            try {
                $size = (Get-Item -LiteralPath $OutputFile -Force).Length
            }
            catch {
                $size = 0L
            }
        }
        else {
            $size = 0L
        }

        if ($size -gt $lastSize) {
            $lastSize = $size
            $unchangedSeconds = 0
        }
        else {
            $unchangedSeconds += $script:CheckInterval
        }

        if ($unchangedSeconds -ge $script:StallTimeout) {
            Write-Host "  Stalled for $($script:StallTimeout)s; terminating clip."
            $timedOut = $true

            try {
                $taskkill = New-Object System.Diagnostics.ProcessStartInfo
                $taskkill.FileName = "taskkill.exe"
                $taskkill.Arguments = "/PID $($process.Id) /T /F"
                $taskkill.UseShellExecute = $false
                $taskkill.CreateNoWindow = $true
                $killer = [System.Diagnostics.Process]::Start($taskkill)
                $killer.WaitForExit()
            }
            catch {}

            try { $process.Kill() } catch {}
            break
        }
    }

    try { $process.WaitForExit() } catch {}

    try { $stdout = $stdoutTask.Result } catch { $stdout = "" }
    try { $stderr = $stderrTask.Result } catch { $stderr = "" }

    Write-Utf8NoBomText -Path $stdoutLog -Text $stdout
    Write-Utf8NoBomText -Path $LogFile -Text $stderr

    if ($timedOut) {
        return 124
    }

    return $process.ExitCode
}

function Csv-Quote([AllowEmptyString()][string]$Value) {
    if ($null -eq $Value) { $Value = "" }
    return '"' + $Value.Replace('"', '""') + '"'
}

function Export-ObjectsCsv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [AllowEmptyCollection()][object[]]$Objects
    )

    $items = @($Objects)

    if ($items.Count -gt 0) {
        $lines = @($items | Select-Object -Property $Headers | ConvertTo-Csv -NoTypeInformation)
    }
    else {
        $lines = @(($Headers | ForEach-Object { Csv-Quote $_ }) -join ',')
    }

    Write-Utf8NoBomLines -Path $Path -Lines $lines
}

function Convert-ToInvariantDouble([object]$Value) {
    if ($null -eq $Value) { return $null }

    [double]$number = 0.0
    if ([double]::TryParse([string]$Value, $script:FloatStyles, $script:InvariantCulture, [ref]$number)) {
        return $number
    }

    return $null
}

function Format-InvariantNumber([double]$Value, [string]$Format = "0.######") {
    return $Value.ToString($Format, $script:InvariantCulture)
}

function Convert-FrameRate([AllowEmptyString()][string]$Rate) {
    if ([string]::IsNullOrWhiteSpace($Rate) -or $Rate -eq "0/0" -or $Rate -eq "N/A") {
        return $null
    }

    if ($Rate -match '^\s*(?<n>-?\d+(?:\.\d+)?)\s*/\s*(?<d>-?\d+(?:\.\d+)?)\s*$') {
        $numerator = Convert-ToInvariantDouble $Matches.n
        $denominator = Convert-ToInvariantDouble $Matches.d
        if ($null -ne $numerator -and $null -ne $denominator -and $denominator -ne 0) {
            return ($numerator / $denominator)
        }
        return $null
    }

    return Convert-ToInvariantDouble $Rate
}

function Get-NaturalSortKey([string]$Text) {
    return [regex]::Replace($Text.ToLowerInvariant(), '\d+', {
        param($match)
        $match.Value.PadLeft(20, '0')
    })
}

function Get-TagValue {
    param(
        [object]$Tags,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    if ($null -eq $Tags) { return "" }

    foreach ($name in $Names) {
        foreach ($property in $Tags.PSObject.Properties) {
            if ($property.Name -ieq $name) {
                return [string]$property.Value
            }
        }
    }

    return ""
}

function Invoke-FFprobeJson([string]$Path) {
    $arguments = @(
        "-v", "error",
        "-show_entries", "format=duration,size:format_tags:stream=index,codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate:stream_tags=rotate:stream_side_data=rotation",
        "-of", "json",
        $Path
    )

    try {
        $result = Invoke-NativeProcess -FilePath "ffprobe.exe" -Arguments $arguments
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            return $null
        }

        return ($result.StdOut | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-MediaDuration([string]$Path) {
    try {
        $result = Invoke-NativeProcess -FilePath "ffprobe.exe" -Arguments @(
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            $Path
        )

        if ($result.ExitCode -ne 0) { return $null }
        $firstLine = (($result.StdOut -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
        return Convert-ToInvariantDouble $firstLine
    }
    catch {
        return $null
    }
}

function Get-CaptureTimestamp {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$Source,
        [object]$Tags
    )

    $raw = Get-TagValue -Tags $Tags -Names @(
        "creation_time",
        "com.apple.quicktime.creationdate",
        "date"
    )

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        [DateTimeOffset]$parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($raw, $script:InvariantCulture, $script:DateStyles, [ref]$parsed)) {
            if ($raw -match '(?<y>19\d{2}|20\d{2})-(?<m>\d{2})-(?<d>\d{2})[T ](?<hh>\d{2}):(?<mm>\d{2}):(?<ss>\d{2})') {
                $label = "$($Matches.y)-$($Matches.m)-$($Matches.d)_$($Matches.hh)-$($Matches.mm)-$($Matches.ss)"
            }
            else {
                $label = $parsed.UtcDateTime.ToString("yyyy-MM-dd_HH-mm-ss", $script:InvariantCulture)
            }

            return [pscustomobject]@{
                Reliable = $true
                Epoch = $parsed.ToUnixTimeSeconds()
                Label = $label
                Source = "metadata"
                Raw = $raw
            }
        }
    }

    $name = $Source.Name

    $fullPattern = '(?<!\d)(?<y>19\d{2}|20\d{2})[-_.]?(?<m>[01]\d)[-_.]?(?<d>[0-3]\d)[T _.-]?(?<hh>[0-2]\d)[-_.:]?(?<mm>[0-5]\d)[-_.:]?(?<ss>[0-5]\d)(?!\d)'
    if ($name -match $fullPattern) {
        try {
            $date = [DateTime]::new(
                [int]$Matches.y,
                [int]$Matches.m,
                [int]$Matches.d,
                [int]$Matches.hh,
                [int]$Matches.mm,
                [int]$Matches.ss,
                [DateTimeKind]::Utc
            )

            return [pscustomobject]@{
                Reliable = $true
                Epoch = ([DateTimeOffset]::new($date)).ToUnixTimeSeconds()
                Label = $date.ToString("yyyy-MM-dd_HH-mm-ss", $script:InvariantCulture)
                Source = "filename"
                Raw = ""
            }
        }
        catch {}
    }

    $datePattern = '(?<!\d)(?<y>19\d{2}|20\d{2})[-_.](?<m>[01]\d)[-_.](?<d>[0-3]\d)(?!\d)'
    if ($name -match $datePattern) {
        try {
            $date = [DateTime]::new(
                [int]$Matches.y,
                [int]$Matches.m,
                [int]$Matches.d,
                0, 0, 0,
                [DateTimeKind]::Utc
            )

            return [pscustomobject]@{
                Reliable = $true
                Epoch = ([DateTimeOffset]::new($date)).ToUnixTimeSeconds()
                Label = $date.ToString("yyyy-MM-dd_00-00-00", $script:InvariantCulture)
                Source = "filename"
                Raw = ""
            }
        }
        catch {}
    }

    return [pscustomobject]@{
        Reliable = $false
        Epoch = ([DateTimeOffset]::new($Source.LastWriteTimeUtc)).ToUnixTimeSeconds()
        Label = "UNKNOWN"
        Source = "unclear"
        Raw = ""
    }
}

function Parse-Iso6709([AllowEmptyString()][string]$Location) {
    if (-not [string]::IsNullOrWhiteSpace($Location) -and
        $Location -match '^(?<lat>[+-]\d+(?:\.\d+)?)(?<lon>[+-]\d+(?:\.\d+)?)(?<alt>[+-]\d+(?:\.\d+)?)?/?$') {

        return [pscustomobject]@{
            Latitude = $Matches.lat
            Longitude = $Matches.lon
            Altitude = if ($Matches.alt) { $Matches.alt } else { "" }
        }
    }

    return [pscustomobject]@{
        Latitude = ""
        Longitude = ""
        Altitude = ""
    }
}

function Get-SourceInfo {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileInfo]$Source,
        [Parameter(Mandatory = $true)][string]$Hash
    )

    $probe = Invoke-FFprobeJson $Source.FullName
    if ($null -eq $probe) { return $null }

    $streams = @($probe.streams | Where-Object { $null -ne $_ })
    $video = $streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $audio = $streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    if ($null -eq $video) { return $null }

    $tags = $probe.format.tags
    $creationTime = Get-TagValue -Tags $tags -Names @(
        "creation_time",
        "com.apple.quicktime.creationdate",
        "date"
    )

    $location = Get-TagValue -Tags $tags -Names @(
        "com.apple.quicktime.location.ISO6709",
        "location",
        "location-eng"
    )

    $gps = Parse-Iso6709 $location
    $capture = Get-CaptureTimestamp -Source $Source -Tags $tags

    $sourceDuration = Convert-ToInvariantDouble $probe.format.duration
    $fps = Convert-FrameRate ([string]$video.avg_frame_rate)
    if ($null -eq $fps -or $fps -le 0) {
        $fps = Convert-FrameRate ([string]$video.r_frame_rate)
    }

    $rotation = ""
    $videoTags = $video.tags
    $rotation = Get-TagValue -Tags $videoTags -Names @("rotate")

    if ([string]::IsNullOrWhiteSpace($rotation) -and $null -ne $video.side_data_list) {
        foreach ($sideData in @($video.side_data_list)) {
            if ($null -ne $sideData.rotation) {
                $rotation = [string]$sideData.rotation
                break
            }
        }
    }

    return [pscustomobject]@{
        FileInfo = $Source
        SourceFile = $Source.FullName
        SourceName = $Source.Name
        Sha256 = $Hash
        SourceDuration = $sourceDuration
        CreationTime = $creationTime
        FileModifiedTime = $Source.LastWriteTimeUtc.ToString("o", $script:InvariantCulture)
        LocationIso6709 = $location
        Latitude = $gps.Latitude
        Longitude = $gps.Longitude
        Altitude = $gps.Altitude
        Width = [string]$video.width
        Height = [string]$video.height
        AvgFrameRate = [string]$video.avg_frame_rate
        SourceFps = $fps
        VideoCodec = [string]$video.codec_name
        AudioCodec = if ($null -ne $audio) { [string]$audio.codec_name } else { "" }
        HasAudio = ($null -ne $audio)
        Rotation = $rotation
        FileSize = $Source.Length
        CaptureReliable = $capture.Reliable
        CaptureEpoch = [int64]$capture.Epoch
        CaptureLabel = $capture.Label
        TimestampSource = $capture.Source
    }
}

function Test-IsJunkDirectory([System.IO.DirectoryInfo]$Directory) {
    $attributes = $Directory.Attributes

    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    if (($attributes -band [System.IO.FileAttributes]::Hidden) -ne 0) { return $true }
    if (($attributes -band [System.IO.FileAttributes]::System) -ne 0) { return $true }
    if ($Directory.Name.StartsWith('.')) { return $true }

    $lower = $Directory.Name.ToLowerInvariant()

    $exactNames = @(
        "__macosx",
        "@eadir",
        "lost+found",
        "system volume information",
        '$recycle.bin',
        "recycled",
        "trash",
        "temporary items",
        "network trash folder",
        "recovery",
        "config.msi",
        "msocache",
        "onedrivetemp",
        '$winreagent',
        "windows.old",
        "wpsystem"
    )

    if ($exactNames -contains $lower) { return $true }

    $packageSuffixes = @(
        ".photoslibrary",
        ".photolibrary",
        ".imovielibrary",
        ".fcpbundle",
        ".fcpevent",
        ".fcpproject",
        ".app",
        ".bundle",
        ".framework",
        ".logicx",
        ".band"
    )

    foreach ($suffix in $packageSuffixes) {
        if ($lower.EndsWith($suffix)) { return $true }
    }

    return $false
}

function Test-IsJunkFile([System.IO.FileInfo]$File) {
    $attributes = $File.Attributes

    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    if (($attributes -band [System.IO.FileAttributes]::Hidden) -ne 0) { return $true }
    if (($attributes -band [System.IO.FileAttributes]::System) -ne 0) { return $true }

    $name = $File.Name
    $lower = $name.ToLowerInvariant()

    if ($name.StartsWith('.')) { return $true }
    if ($name.StartsWith('~$')) { return $true }
    if ($name.EndsWith('~')) { return $true }

    if (@("thumbs.db", "desktop.ini", "icon`r", ".ds_store") -contains $lower) {
        return $true
    }

    if ($lower -match '\.(tmp|temp|part|partial|download|crdownload|icloud)\.(mp4|mov|mkv|webm|mts|m2ts|ts|avi|m4v|mpg|mpeg|3gp|vob)$') {
        return $true
    }

    return $false
}

function Get-SourceFiles([bool]$Recursive) {
    $supported = @(
        ".mp4", ".mov", ".mkv", ".webm", ".mts", ".m2ts", ".ts",
        ".avi", ".m4v", ".mpg", ".mpeg", ".3gp", ".vob"
    )

    $results = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    $root = Get-Item -LiteralPath $script:StartDir -Force
    $stack.Push($root)

    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()

        try {
            $entries = $directory.GetFileSystemInfos()
        }
        catch {
            Write-Host "Skipping unreadable folder: $($directory.FullName)"
            continue
        }

        foreach ($entry in $entries) {
            if ($entry -is [System.IO.DirectoryInfo]) {
                if ($Recursive -and -not (Test-IsJunkDirectory $entry)) {
                    $stack.Push($entry)
                }
                continue
            }

            if (-not ($entry -is [System.IO.FileInfo])) { continue }
            if (Test-IsJunkFile $entry) { continue }
            if (-not ($supported -contains $entry.Extension.ToLowerInvariant())) { continue }
            if ([string]::Equals($entry.FullName, $script:Output, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            $results.Add($entry)
        }

        if (-not $Recursive) {
            break
        }
    }

    $sortedResults = $results | Sort-Object @{ Expression = { Get-NaturalSortKey $_.FullName } }, @{ Expression = { $_.FullName.ToLowerInvariant() } }
    return @($sortedResults)
}

function Escape-ConcatPath([string]$Path) {
    $forwardSlashes = $Path.Replace('\', '/')
    return $forwardSlashes.Replace("'", "'\''")
}

function Test-Encoder {
    param([Parameter(Mandatory = $true)][object]$Encoder)

    $testOutput = Join-Path $script:WorkDir ("encoder_test_{0}.mp4" -f $Encoder.Name)
    Remove-Item -LiteralPath $testOutput -Force -ErrorAction SilentlyContinue

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($arg in @(
        "-nostdin", "-hide_banner", "-loglevel", "error",
        "-f", "lavfi", "-i", "color=c=black:s=128x72:r=30:d=0.2",
        "-frames:v", "1",
        "-vf", "format=$($Encoder.FilterFormat)",
        "-c:v", $Encoder.Name
    )) {
        $arguments.Add([string]$arg)
    }

    foreach ($arg in @($Encoder.ExtraArgs)) { $arguments.Add([string]$arg) }
    foreach ($arg in @($Encoder.RateArgs)) { $arguments.Add([string]$arg) }

    foreach ($arg in @("-an", "-y", $testOutput)) {
        $arguments.Add([string]$arg)
    }

    try {
        $result = Invoke-NativeProcess -FilePath "ffmpeg.exe" -Arguments $arguments.ToArray()
        $valid = ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $testOutput) -and (Get-Item -LiteralPath $testOutput).Length -gt 0)
    }
    catch {
        $valid = $false
    }

    Remove-Item -LiteralPath $testOutput -Force -ErrorAction SilentlyContinue
    return $valid
}

function Get-EncoderChoice {
    $encoderOutput = Invoke-NativeProcess -FilePath "ffmpeg.exe" -Arguments @("-hide_banner", "-encoders")
    if ($encoderOutput.ExitCode -ne 0) {
        Fail "Could not read FFmpeg encoder list."
    }

    $choices = [System.Collections.Generic.List[object]]::new()

    if ($script:PreferHardwareEncoding) {
        $choices.Add([pscustomobject]@{
            Name = "h264_nvenc"
            ExtraArgs = @("-preset", "p4", "-rc", "vbr")
            RateArgs = @("-b:v", $script:VideoBitrate, "-maxrate", $script:VideoMaxrate, "-bufsize", $script:VideoBufsize)
            FilterFormat = "nv12"
            CacheLabel = "nvenc_p4_vbr_$($script:VideoBitrate)"
        })
        $choices.Add([pscustomobject]@{
            Name = "h264_qsv"
            ExtraArgs = @()
            RateArgs = @("-b:v", $script:VideoBitrate, "-maxrate", $script:VideoMaxrate, "-bufsize", $script:VideoBufsize)
            FilterFormat = "nv12"
            CacheLabel = "qsv_vbr_$($script:VideoBitrate)"
        })
        $choices.Add([pscustomobject]@{
            Name = "h264_amf"
            ExtraArgs = @("-quality", "balanced")
            RateArgs = @("-b:v", $script:VideoBitrate, "-maxrate", $script:VideoMaxrate, "-bufsize", $script:VideoBufsize)
            FilterFormat = "nv12"
            CacheLabel = "amf_balanced_$($script:VideoBitrate)"
        })
        $choices.Add([pscustomobject]@{
            Name = "h264_mf"
            ExtraArgs = @()
            RateArgs = @("-b:v", $script:VideoBitrate)
            FilterFormat = "nv12"
            CacheLabel = "mf_$($script:VideoBitrate)"
        })
    }

    $choices.Add([pscustomobject]@{
        Name = "libx264"
        ExtraArgs = @("-preset", $script:VideoPreset, "-crf", [string]$script:VideoCrf)
        RateArgs = @()
        FilterFormat = "yuv420p"
        CacheLabel = "x264_$($script:VideoPreset)_crf$($script:VideoCrf)"
    })

    foreach ($choice in $choices) {
        $pattern = "(?m)^\s*[A-Z\.]{6}\s+$([regex]::Escape($choice.Name))\s"
        if (($encoderOutput.StdOut + $encoderOutput.StdErr) -notmatch $pattern) {
            continue
        }

        Write-Host "Testing encoder: $($choice.Name)..."
        if (Test-Encoder $choice) {
            return $choice
        }

        Write-Host "  Encoder is listed but failed its test; trying the next one."
    }

    Fail "No usable H.264 encoder found in this FFmpeg installation."
}

if (-not (Command-Exists "ffmpeg.exe")) {
    Fail "ffmpeg.exe is missing. Install it with: winget install Gyan.FFmpeg"
}
if (-not (Command-Exists "ffprobe.exe")) {
    Fail "ffprobe.exe is missing. Install it with: winget install Gyan.FFmpeg"
}
if (Test-Path -LiteralPath $Output) {
    Fail "$OutputName already exists. Rename or remove it first."
}
if (Test-Path -LiteralPath $TimelineOutput) {
    Fail "$TimelineName already exists. Rename or remove it first."
}

New-Item -ItemType Directory -Force -Path $LogDir, $NormalizedDir | Out-Null
Write-Utf8NoBomLines -Path $ConcatList -Lines @()

$encoder = Get-EncoderChoice
$VideoCodec = $encoder.Name

while ($true) {
    $recursiveAnswer = Read-Host "Search subfolders too? [y/n]"
    if ($recursiveAnswer -match '^[yY]$') {
        $Recursive = $true
        break
    }
    if ($recursiveAnswer -match '^[nN]$') {
        $Recursive = $false
        break
    }
    Write-Host "Please enter y or n."
}

Write-Host ""
Write-Host "Scanning for source videos..."
$files = @(Get-SourceFiles -Recursive $Recursive)

if ($files.Count -eq 0) {
    Fail "No supported videos found."
}

Write-Host "Found $($files.Count) candidate video files."
Write-Host "Hashing source files to guarantee exact deduplication..."
Write-Host ""

$hashIndex = @{}
$uniqueFiles = [System.Collections.Generic.List[object]]::new()
$duplicates = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()
$manifest = [System.Collections.Generic.List[object]]::new()
$orderRows = [System.Collections.Generic.List[object]]::new()

$hashIndexNumber = 0
foreach ($source in $files) {
    $hashIndexNumber++

    if ($source.FullName -match "[`t`r`n]") {
        Write-Host "[skip $hashIndexNumber/$($files.Count)] Unsupported control character in path: $($source.Name)"
        $skipped.Add([pscustomobject]@{
            source_file = $source.FullName
            sha256 = ""
            reason = "unsupported control character in path"
            detail = "tab or newline"
        })
        continue
    }

    Write-Host "[hash $hashIndexNumber/$($files.Count)] $($source.Name)"

    try {
        $hash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch {
        Write-Host "  Hash failed; skipped."
        $skipped.Add([pscustomobject]@{
            source_file = $source.FullName
            sha256 = ""
            reason = "hash failed"
            detail = $_.Exception.Message
        })
        continue
    }

    if ($hashIndex.ContainsKey($hash)) {
        $original = [string]$hashIndex[$hash]
        Write-Host "  Exact duplicate; excluded. Original: $original"
        $duplicates.Add([pscustomobject]@{
            duplicate_file = $source.FullName
            sha256 = $hash
            original_file = $original
        })
        continue
    }

    $hashIndex[$hash] = $source.FullName
    $uniqueFiles.Add([pscustomobject]@{
        FileInfo = $source
        Hash = $hash
    })
}

if ($uniqueFiles.Count -eq 0) {
    Export-ObjectsCsv -Path $SkippedReport -Headers @("source_file", "sha256", "reason", "detail") -Objects $skipped.ToArray()
    Export-ObjectsCsv -Path $DuplicateReport -Headers @("duplicate_file", "sha256", "original_file") -Objects $duplicates.ToArray()
    Fail "No unique readable source files remain."
}

Write-Host ""
Write-Host "Reading video metadata and frame rates..."

$sourceInfos = [System.Collections.Generic.List[object]]::new()
$metadataIndex = 0
$maxSourceFps = 0.0
$maxSourceFpsFile = ""
$unknownFps = 0

foreach ($item in $uniqueFiles) {
    $metadataIndex++
    Write-Host "[probe $metadataIndex/$($uniqueFiles.Count)] $($item.FileInfo.Name)"

    $info = Get-SourceInfo -Source $item.FileInfo -Hash $item.Hash
    if ($null -eq $info) {
        Write-Host "  No readable video stream; skipped."
        $skipped.Add([pscustomobject]@{
            source_file = $item.FileInfo.FullName
            sha256 = $item.Hash
            reason = "ffprobe failed"
            detail = "no readable video stream"
        })
        continue
    }

    $sourceInfos.Add($info)

    if ($null -eq $info.SourceFps -or $info.SourceFps -le 0) {
        $unknownFps++
    }
    elseif ($info.SourceFps -gt $maxSourceFps) {
        $maxSourceFps = $info.SourceFps
        $maxSourceFpsFile = $info.SourceFile
    }
}

if ($sourceInfos.Count -eq 0) {
    Export-ObjectsCsv -Path $SkippedReport -Headers @("source_file", "sha256", "reason", "detail") -Objects $skipped.ToArray()
    Export-ObjectsCsv -Path $DuplicateReport -Headers @("duplicate_file", "sha256", "original_file") -Objects $duplicates.ToArray()
    Fail "No readable videos remain after probing."
}

if ($maxSourceFps -gt 0) {
    $suggestedFps = [int][Math]::Round($maxSourceFps)
    if ($suggestedFps -gt 60) { $suggestedFps = 60 }
    if ($suggestedFps -lt 1) { $suggestedFps = 1 }

    Write-Host ""
    Write-Host "Highest detected source FPS: $(Format-InvariantNumber $maxSourceFps)"
    if ($maxSourceFps -gt 60) {
        Write-Host "Export FPS is capped at 60."
    }
    Write-Host "Current export FPS: $Fps"

    if ($suggestedFps -gt $Fps) {
        Write-Host "Higher-frame-rate source: $([System.IO.Path]::GetFileName($maxSourceFpsFile))"
        while ($true) {
            $fpsAnswer = Read-Host "Export all clips at $suggestedFps fps instead of $Fps fps? [y/n]"
            if ($fpsAnswer -match '^[yY]$') {
                $Fps = $suggestedFps
                Write-Host "Export FPS changed to $Fps."
                break
            }
            if ($fpsAnswer -match '^[nN]$') {
                Write-Host "Export FPS remains $Fps."
                break
            }
            Write-Host "Please enter y or n."
        }
    }
}
else {
    Write-Host "Warning: frame rate could not be detected for any source; using $Fps fps."
}

if ($unknownFps -gt 0) {
    Write-Host "Warning: FPS could not be read from $unknownFps source file(s)."
}

Write-Host ""
Write-Host "Unique files: $($sourceInfos.Count)"
Write-Host "Exact duplicates excluded: $($duplicates.Count)"
Write-Host "Work folder: $WorkDir"
Write-Host "Selected and tested encoder: $VideoCodec"
Write-Host "Cache identity: SHA-256 + video settings + audio settings"
Write-Host "Each clip is normalized separately before final merge."
Write-Host "A clip is skipped if its output does not grow for ${StallTimeout}s."
Write-Host ""

$success = 0
$failedCount = 0
$conversionIndex = 0

foreach ($info in $sourceInfos) {
    $conversionIndex++

    $timestampGroup = if ($info.CaptureReliable) { 0 } else { 1 }
    $captureLabel = $info.CaptureLabel
    $cacheIdentity = "$($info.Sha256)_${Width}x${Height}_${Fps}fps_$($encoder.CacheLabel)_${AudioCodec}_${AudioBitrate}_${AudioSampleRate}hz"
    $normalizedName = "${captureLabel}__${cacheIdentity}.mp4"
    $normalized = Join-Path $NormalizedDir $normalizedName
    $log = Join-Path $LogDir ("{0}_{1}x{2}_{3}fps_{4}.log" -f $info.Sha256, $Width, $Height, $Fps, $VideoCodec)

    Write-Host "[$conversionIndex/$($sourceInfos.Count)] $($info.SourceName)"

    if ($info.CaptureReliable) {
        Write-Host "  Capture time: $captureLabel ($($info.TimestampSource))"
    }
    else {
        Write-Host "  Capture time unclear; placed last within its video class."
    }

    $reuse = $false
    if ((Test-Path -LiteralPath $normalized) -and (Get-Item -LiteralPath $normalized -Force).Length -gt 0) {
        $cachedDuration = Get-MediaDuration $normalized
        if ($null -ne $cachedDuration -and $cachedDuration -gt 0) {
            Write-Host "  Hash-matched normalized file exists; safely reusing."
            $reuse = $true
        }
        else {
            Remove-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $reuse) {
        # Remove obsolete cache variants only for this exact source hash.
        Get-ChildItem -LiteralPath $NormalizedDir -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like "*$($info.Sha256)*.mp4" -and
                -not [string]::Equals($_.FullName, $normalized, [System.StringComparison]::OrdinalIgnoreCase)
            } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Remove-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue

        $arguments = [System.Collections.Generic.List[string]]::new()
        foreach ($arg in @(
            "-nostdin", "-hide_banner", "-loglevel", "warning",
            "-fflags", "+genpts",
            "-i", $info.SourceFile
        )) {
            $arguments.Add([string]$arg)
        }

        if (-not $info.HasAudio) {
            foreach ($arg in @(
                "-f", "lavfi",
                "-i", "anullsrc=channel_layout=stereo:sample_rate=$AudioSampleRate"
            )) {
                $arguments.Add([string]$arg)
            }
        }

        if ($info.HasAudio) {
            foreach ($arg in @(
                "-map", "0:v:0",
                "-map", "0:a:0?",
                "-af", "aresample=async=1:first_pts=0,apad",
                "-shortest"
            )) {
                $arguments.Add([string]$arg)
            }
        }
        else {
            foreach ($arg in @(
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-shortest"
            )) {
                $arguments.Add([string]$arg)
            }
        }

        foreach ($arg in @(
            "-map_metadata", "-1",
            "-vf", "scale=${Width}:${Height}:force_original_aspect_ratio=decrease,pad=${Width}:${Height}:(ow-iw)/2:(oh-ih)/2,fps=${Fps},format=$($encoder.FilterFormat)",
            "-c:v", $VideoCodec
        )) {
            $arguments.Add([string]$arg)
        }

        foreach ($arg in @($encoder.ExtraArgs)) { $arguments.Add([string]$arg) }
        foreach ($arg in @($encoder.RateArgs)) { $arguments.Add([string]$arg) }

        if ($encoder.FilterFormat -eq "yuv420p") {
            foreach ($arg in @("-pix_fmt", "yuv420p")) { $arguments.Add([string]$arg) }
        }

        foreach ($arg in @(
            "-c:a", $AudioCodec,
            "-b:a", $AudioBitrate,
            "-ar", [string]$AudioSampleRate,
            "-ac", "2",
            "-y", $normalized
        )) {
            $arguments.Add([string]$arg)
        }

        $code = Run-WithWatchdog -OutputFile $normalized -LogFile $log -Arguments $arguments.ToArray()

        if ($code -ne 0) {
            Remove-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue
            Write-Host "  Failed or stalled (exit $code); skipped. Log: $log"
            $skipped.Add([pscustomobject]@{
                source_file = $info.SourceFile
                sha256 = $info.Sha256
                reason = "ffmpeg exit"
                detail = [string]$code
            })
            $failedCount++
            continue
        }
    }

    $normalizedDuration = Get-MediaDuration $normalized
    if ($null -eq $normalizedDuration -or $normalizedDuration -le 0) {
        Remove-Item -LiteralPath $normalized -Force -ErrorAction SilentlyContinue
        Write-Host "  Normalized duration unavailable; skipped."
        $skipped.Add([pscustomobject]@{
            source_file = $info.SourceFile
            sha256 = $info.Sha256
            reason = "normalized duration unavailable"
            detail = ""
        })
        $failedCount++
        continue
    }

    $likelyLivePhoto = ($normalizedDuration -le $LikelyLivePhotoMaxSeconds)
    if ($likelyLivePhoto) {
        $sortGroup = 2 + $timestampGroup
        Write-Host "  Short clip ($(Format-InvariantNumber $normalizedDuration)s); placed after normal videos."
    }
    else {
        $sortGroup = $timestampGroup
    }

    $manifest.Add([pscustomobject]@{
        sha256 = $info.Sha256
        source_file = $info.SourceFile
        normalized_file = $normalized
        width = $Width
        height = $Height
        export_fps = $Fps
        capture_label = $captureLabel
        timestamp_source = $info.TimestampSource
        video_encoder = $VideoCodec
        encoder_settings = $encoder.CacheLabel
        normalized_duration_seconds = Format-InvariantNumber $normalizedDuration
    })

    $orderRows.Add([pscustomobject]@{
        sort_group = $sortGroup
        capture_epoch = $info.CaptureEpoch
        source_file = $info.SourceFile
        sha256 = $info.Sha256
        normalized_file = $normalized
        normalized_duration_seconds = $normalizedDuration
        capture_label = $captureLabel
        timestamp_source = $info.TimestampSource
        likely_live_photo = if ($likelyLivePhoto) { 1 } else { 0 }
        source_info = $info
    })

    $success++
}

Export-ObjectsCsv -Path $SkippedReport -Headers @("source_file", "sha256", "reason", "detail") -Objects $skipped.ToArray()
Export-ObjectsCsv -Path $DuplicateReport -Headers @("duplicate_file", "sha256", "original_file") -Objects $duplicates.ToArray()
Export-ObjectsCsv -Path $ManifestReport -Headers @(
    "sha256", "source_file", "normalized_file", "width", "height", "export_fps",
    "capture_label", "timestamp_source", "video_encoder", "encoder_settings",
    "normalized_duration_seconds"
) -Objects $manifest.ToArray()

if ($success -le 0) {
    Fail "All clips failed. Inspect $LogDir and $SkippedReport."
}

$sortedOrder = @($orderRows | Sort-Object @{ Expression = { [int]$_.sort_group } }, @{ Expression = { [int64]$_.capture_epoch } }, @{ Expression = { $_.source_file.ToLowerInvariant() } }, @{ Expression = { $_.sha256 } })

Export-ObjectsCsv -Path $OrderReport -Headers @(
    "sort_group", "capture_epoch", "source_file", "sha256", "normalized_file",
    "normalized_duration_seconds", "capture_label", "timestamp_source", "likely_live_photo"
) -Objects $sortedOrder

$concatLines = [System.Collections.Generic.List[string]]::new()
$seenNormalized = @{}
$timelineRows = [System.Collections.Generic.List[object]]::new()
$timelineCursor = 0.0
$sequence = 0

foreach ($row in $sortedOrder) {
    $sequence++
    $absolute = [System.IO.Path]::GetFullPath($row.normalized_file)
    $escaped = Escape-ConcatPath $absolute
    $concatLine = "file '$escaped'"

    $normalizedKey = $absolute.ToLowerInvariant()
    if ($seenNormalized.ContainsKey($normalizedKey)) {
        Fail "Duplicate normalized path detected while building concat list: $absolute"
    }
    $seenNormalized[$normalizedKey] = $true
    $concatLines.Add($concatLine)

    $duration = [double]$row.normalized_duration_seconds
    $startSeconds = $timelineCursor
    $endSeconds = $startSeconds + $duration
    $info = $row.source_info

    $timelineRows.Add([pscustomobject]@{
        sequence = $sequence
        source_file = $info.SourceFile
        source_name = $info.SourceName
        sha256 = $info.Sha256
        start_seconds = Format-InvariantNumber $startSeconds
        end_seconds = Format-InvariantNumber $endSeconds
        duration_seconds = Format-InvariantNumber $duration
        source_duration_seconds = if ($null -ne $info.SourceDuration) { Format-InvariantNumber $info.SourceDuration } else { "" }
        creation_time = $info.CreationTime
        file_modified_time = $info.FileModifiedTime
        location_iso6709 = $info.LocationIso6709
        latitude = $info.Latitude
        longitude = $info.Longitude
        altitude_m = $info.Altitude
        width = $info.Width
        height = $info.Height
        avg_frame_rate = $info.AvgFrameRate
        video_codec = $info.VideoCodec
        audio_codec = $info.AudioCodec
        has_audio = if ($info.HasAudio) { 1 } else { 0 }
        rotation_degrees = $info.Rotation
        file_size_bytes = $info.FileSize
        export_fps = $Fps
        normalized_file = $absolute
    })

    $timelineCursor = $endSeconds
}

if (($concatLines | Sort-Object -Unique).Count -ne $concatLines.Count) {
    Fail "Duplicate entries detected in concat list; refusing to create output."
}

Write-Utf8NoBomLines -Path $ConcatList -Lines $concatLines.ToArray()

$normalReliableCount = @($sortedOrder | Where-Object { $_.sort_group -eq 0 }).Count
$normalUnclearCount = @($sortedOrder | Where-Object { $_.sort_group -eq 1 }).Count
$liveReliableCount = @($sortedOrder | Where-Object { $_.sort_group -eq 2 }).Count
$liveUnclearCount = @($sortedOrder | Where-Object { $_.sort_group -eq 3 }).Count
$likelyLiveCount = $liveReliableCount + $liveUnclearCount
$unclearCount = $normalUnclearCount + $liveUnclearCount

Write-Host ""
Write-Host "Normalized successfully: $success"
Write-Host "Normal videos with reliable timestamps: $normalReliableCount"
Write-Host "Normal videos with unclear timestamps: $normalUnclearCount"
Write-Host "Likely Live Photo clips (<= ${LikelyLivePhotoMaxSeconds}s): $likelyLiveCount"
Write-Host "Likely Live Photo clips with unclear timestamps: $liveUnclearCount"
Write-Host "Total unclear timestamps: $unclearCount"
Write-Host "Export frame rate: $Fps fps"
Write-Host "Skipped: $($skipped.Count)"
Write-Host "Exact duplicates excluded: $($duplicates.Count)"
Write-Host "Joining normalized clips without re-encoding..."

$finalArguments = [System.Collections.Generic.List[string]]::new()
foreach ($arg in @(
    "-nostdin", "-hide_banner", "-loglevel", "warning",
    "-f", "concat", "-safe", "0", "-i", $ConcatList,
    "-c", "copy"
)) {
    $finalArguments.Add([string]$arg)
}

if ($EnableFaststart) {
    foreach ($arg in @("-movflags", "+faststart")) { $finalArguments.Add([string]$arg) }
}

foreach ($arg in @("-y", $Output)) { $finalArguments.Add([string]$arg) }

$finalResult = Invoke-NativeProcess -FilePath "ffmpeg.exe" -Arguments $finalArguments.ToArray()
Write-Utf8NoBomText -Path "$FinalLog.stdout" -Text $finalResult.StdOut
Write-Utf8NoBomText -Path $FinalLog -Text $finalResult.StdErr

if ($finalResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $Output) -and (Get-Item -LiteralPath $Output).Length -gt 0) {
    Export-ObjectsCsv -Path $TimelineOutput -Headers @(
        "sequence", "source_file", "source_name", "sha256", "start_seconds",
        "end_seconds", "duration_seconds", "source_duration_seconds", "creation_time",
        "file_modified_time", "location_iso6709", "latitude", "longitude",
        "altitude_m", "width", "height", "avg_frame_rate", "video_codec",
        "audio_codec", "has_audio", "rotation_degrees", "file_size_bytes",
        "export_fps", "normalized_file"
    ) -Objects $timelineRows.ToArray()

    Write-Host ""
    Write-Host "Done: $Output"
    Write-Host "Timeline CSV: $TimelineOutput"
    Write-Host "Manifest: $ManifestReport"
    Write-Host "Ordering report: $OrderReport"
    Write-Host "Duplicate report: $DuplicateReport"
    Write-Host "Skipped-file report: $SkippedReport"
    Write-Host "Final FFmpeg log: $FinalLog"
    Write-Host "Hash-bound normalized cache kept at: $NormalizedDir"
    Write-Host "Original files were not modified or deleted."
}
else {
    Remove-Item -LiteralPath $Output -Force -ErrorAction SilentlyContinue
    Fail "Final concatenation failed. Check: $FinalLog"
}
