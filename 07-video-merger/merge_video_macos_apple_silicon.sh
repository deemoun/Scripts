#!/usr/bin/env bash

# Merge and normalize video clips on macOS / Apple Silicon.
# Requirements: Homebrew FFmpeg (brew install ffmpeg)

set -o pipefail

# =========================
# User settings
# =========================

OUTPUT="merged_video.mp4"

WIDTH="1920"
HEIGHT="1080"
FPS="30"

# Apple Silicon hardware encoder.
VIDEO_CODEC="h264_videotoolbox"
VIDEO_BITRATE="12M"
VIDEO_MAXRATE="18M"
VIDEO_BUFSIZE="24M"

AUDIO_CODEC="aac"
AUDIO_BITRATE="192k"
AUDIO_SAMPLE_RATE="48000"

# yes = optimize MP4 for web playback; no = faster finalization for large files.
ENABLE_FASTSTART="no"

LOG_FILE="ffmpeg_merge.log"

# =========================
# Internal settings
# =========================

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LIST_FILE="videos_to_merge_${TIMESTAMP}.txt"
SORT_FILE="${TMPDIR:-/tmp}/merge_video_sort_${TIMESTAMP}_$$.txt"

cleanup() {
  rm -f "$SORT_FILE"
}
trap cleanup EXIT INT TERM

fail() {
  echo "Error: $*" >&2
  exit 1
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is not installed. Install it with: brew install ffmpeg"
command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is not installed. Install it with: brew install ffmpeg"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Warning: this version is intended for macOS."
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "Warning: Apple Silicon was not detected; h264_videotoolbox may still work on some Intel Macs."
fi

ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'h264_videotoolbox' || \
  fail "this FFmpeg build does not provide h264_videotoolbox. Install Homebrew FFmpeg: brew install ffmpeg"

[ ! -e "$OUTPUT" ] || fail "$OUTPUT already exists. Nothing was overwritten."

: > "$LIST_FILE" || fail "cannot create $LIST_FILE"
: > "$SORT_FILE" || fail "cannot create temporary sorting file"

echo "Scanning current folder for video files..."

# BSD find on macOS has no GNU -maxdepth. -depth 1 limits results to this folder.
while IFS= read -r file; do
  base="$(basename "$file")"

  # GoPro main file: GOPR0042.MP4 -> clip 0042, part 00
  if [[ "$base" =~ ^GOPR([0-9]{4})\.[Mm][Pp]4$ ]]; then
    clip="${BASH_REMATCH[1]}"
    part="00"
    sort_key="0_${clip}_${part}"

  # GoPro chapter: GP010042.MP4 -> clip 0042, part 01
  elif [[ "$base" =~ ^GP([0-9]{2})([0-9]{4})\.[Mm][Pp]4$ ]]; then
    part="${BASH_REMATCH[1]}"
    clip="${BASH_REMATCH[2]}"
    sort_key="0_${clip}_${part}"

  # Other camera filenames. Case-insensitive byte sorting is predictable on macOS.
  else
    sort_key="1_$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  fi

  # Tab is used only as an internal separator. Tabs in filenames are unsupported.
  printf '%s\t%s\n' "$sort_key" "$file" >> "$SORT_FILE"
done < <(
  find . -depth 1 -type f \( \
    -iname "*.mp4" -o \
    -iname "*.mov" -o \
    -iname "*.mkv" -o \
    -iname "*.webm" -o \
    -iname "*.mts" -o \
    -iname "*.m2ts" -o \
    -iname "*.ts" \
  \) ! -iname "$OUTPUT"
)

[ -s "$SORT_FILE" ] || {
  rm -f "$LIST_FILE"
  fail "no supported video files found (mp4, mov, mkv, webm, mts, m2ts, ts)"
}

# Fixed-width GoPro keys sort correctly with standard BSD sort; no GNU sort -V needed.
LC_ALL=C sort -f "$SORT_FILE" -o "$SORT_FILE"

TOTAL_DURATION=0
FILE_COUNT=0

while IFS=$'\t' read -r _sort_key file; do
  [ -n "$file" ] || continue

  # Portable absolute path replacement for GNU readlink -f.
  dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || fail "cannot resolve path: $file"
  abs_path="$dir/$(basename "$file")"

  # FFmpeg concat files escape a single quote as: '\''
  escaped_path=$(printf '%s' "$abs_path" | sed "s/'/'\\\\''/g")
  printf "file '%s'\n" "$escaped_path" >> "$LIST_FILE"

  duration="$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$abs_path" 2>/dev/null || true)"
  duration_int="${duration%.*}"

  if [[ "$duration_int" =~ ^[0-9]+$ ]]; then
    TOTAL_DURATION=$((TOTAL_DURATION + duration_int))
  else
    echo "Warning: could not read duration for: $abs_path"
  fi

  FILE_COUNT=$((FILE_COUNT + 1))
done < "$SORT_FILE"

[ "$FILE_COUNT" -gt 0 ] || fail "no usable video files found"

if [ "$TOTAL_DURATION" -le 0 ]; then
  echo "Warning: total duration could not be calculated; percentage will be approximate."
  TOTAL_DURATION=1
fi

echo
echo "Files to merge ($FILE_COUNT):"
cat "$LIST_FILE"

echo
echo "Settings:"
echo "Output: $OUTPUT"
echo "Resolution: ${WIDTH}x${HEIGHT}"
echo "FPS: $FPS"
echo "Video: $VIDEO_CODEC / $VIDEO_BITRATE"
echo "Audio: $AUDIO_CODEC / $AUDIO_BITRATE / ${AUDIO_SAMPLE_RATE} Hz"
echo "Faststart: $ENABLE_FASTSTART"
echo "Total duration: approximately ${TOTAL_DURATION} seconds"
echo "Log: $LOG_FILE"
echo
echo "Merging and converting..."

show_progress() {
  local current="$1"
  local total="$2"
  local bar_width=40
  local percent filled empty

  [ "$current" -ge 0 ] || current=0
  [ "$current" -le "$total" ] || current="$total"

  percent=$((current * 100 / total))
  filled=$((percent * bar_width / 100))
  empty=$((bar_width - filled))

  printf '\r['
  [ "$filled" -eq 0 ] || printf '%*s' "$filled" '' | tr ' ' '#'
  [ "$empty" -eq 0 ] || printf '%*s' "$empty" '' | tr ' ' '-'
  printf '] %d%%' "$percent"
}

MOVFLAGS_ARGS=()
if [ "$ENABLE_FASTSTART" = "yes" ]; then
  MOVFLAGS_ARGS=(-movflags +faststart)
fi

# concat demuxer is best for clips from the same camera/source family.
# genpts and async resampling help with uneven AVCHD timestamps.
ffmpeg \
  -hide_banner \
  -loglevel error \
  -stats_period 1 \
  -progress pipe:1 \
  -fflags +genpts \
  -f concat -safe 0 -i "$LIST_FILE" \
  -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=${FPS},format=nv12" \
  -af "aresample=async=1:first_pts=0" \
  -c:v "$VIDEO_CODEC" \
  -b:v "$VIDEO_BITRATE" \
  -maxrate "$VIDEO_MAXRATE" \
  -bufsize "$VIDEO_BUFSIZE" \
  -allow_sw 1 \
  -c:a "$AUDIO_CODEC" \
  -b:a "$AUDIO_BITRATE" \
  -ar "$AUDIO_SAMPLE_RATE" \
  "${MOVFLAGS_ARGS[@]}" \
  "$OUTPUT" 2>"$LOG_FILE" | while IFS='=' read -r key value; do
    if [ "$key" = "out_time_ms" ] && [[ "$value" =~ ^[0-9]+$ ]]; then
      show_progress "$((value / 1000000))" "$TOTAL_DURATION"
    elif [ "$key" = "progress" ] && [ "$value" = "end" ]; then
      show_progress "$TOTAL_DURATION" "$TOTAL_DURATION"
      echo
    fi
  done

FFMPEG_EXIT=${PIPESTATUS[0]}
echo

if [ "$FFMPEG_EXIT" -eq 0 ]; then
  echo "Done: $OUTPUT"
  echo "Input list kept: $LIST_FILE"
  echo "Log kept: $LOG_FILE"
  echo "Original files were not changed or deleted."
else
  rm -f "$OUTPUT"
  echo "Error: ffmpeg failed (exit code $FFMPEG_EXIT)." >&2
  echo "Any incomplete output was removed; original files were not changed." >&2
  echo "Check the log with: tail -50 '$LOG_FILE'" >&2
  exit "$FFMPEG_EXIT"
fi
