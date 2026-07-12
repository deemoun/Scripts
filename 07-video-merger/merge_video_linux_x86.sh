#!/usr/bin/env bash

# =========================
# User settings
# =========================

OUTPUT="merged_video.mp4"

WIDTH="1920"
HEIGHT="1080"
FPS="30"

VIDEO_CODEC="libx264"
VIDEO_PRESET="fast"
VIDEO_CRF="18"

AUDIO_CODEC="aac"
AUDIO_BITRATE="192k"
AUDIO_SAMPLE_RATE="48000"

# For archive use this is better: it avoids slow MP4 "faststart" finalization on big files.
# Set to "yes" only if you need faster web playback start in browser.
ENABLE_FASTSTART="no"

# Keep ffmpeg errors in a log file instead of hiding them.
LOG_FILE="ffmpeg_merge.log"

# =========================
# Internal settings
# =========================

LIST_FILE="videos_to_merge_$(date +%Y%m%d_%H%M%S).txt"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is not installed."
  exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is not installed."
  exit 1
fi

if [ -f "$OUTPUT" ]; then
  echo "Error: $OUTPUT already exists."
  echo "Nothing was overwritten or deleted."
  exit 1
fi

echo "Scanning current folder for video files..."

# Supported input formats:
# - MP4/MOV/MKV/WEBM
# - MTS/M2TS/TS, common for AVCHD cameras/camcorders
find . -maxdepth 1 -type f \( \
  -iname "*.mp4" -o \
  -iname "*.mov" -o \
  -iname "*.mkv" -o \
  -iname "*.webm" -o \
  -iname "*.mts" -o \
  -iname "*.m2ts" -o \
  -iname "*.ts" \
\) ! -iname "$OUTPUT" | while IFS= read -r file; do

  base="$(basename "$file")"

  # GoPro main file:
  # GOPR0042.MP4 -> clip 0042, part 00
  if [[ "$base" =~ ^GOPR([0-9]{4})\.[Mm][Pp]4$ ]]; then
    clip="${BASH_REMATCH[1]}"
    part="00"

  # GoPro chapter file:
  # GP010042.MP4 -> clip 0042, part 01
  # GP020042.MP4 -> clip 0042, part 02
  elif [[ "$base" =~ ^GP([0-9]{2})([0-9]{4})\.[Mm][Pp]4$ ]]; then
    part="${BASH_REMATCH[1]}"
    clip="${BASH_REMATCH[2]}"

  # Regular camera files:
  # 00000.MTS, 00001.MTS, 00002.MTS -> sorted naturally
  # Also works with C0001.MP4, clip_01.mov, etc.
  else
    clip="$base"
    part="00"
  fi

  printf "%s_%s\t%s\n" "$clip" "$part" "$file"

done | sort -V | cut -f2- | while IFS= read -r file; do
  # Use absolute paths because the concat demuxer is picky with spaces and relative paths.
  abs_path="$(readlink -f "$file")"
  printf "file '%s'\n" "$abs_path" >> "$LIST_FILE"
done

if [ ! -s "$LIST_FILE" ]; then
  echo "No video files found in this folder."
  echo "Supported formats: mp4, mov, mkv, webm, mts, m2ts, ts"
  echo "Nothing was deleted."
  exit 1
fi

echo
echo "Files to merge:"
cat "$LIST_FILE"

echo
echo "Settings:"
echo "Output: $OUTPUT"
echo "Resolution: ${WIDTH}x${HEIGHT}"
echo "FPS: $FPS"
echo "Video codec: $VIDEO_CODEC"
echo "Preset: $VIDEO_PRESET"
echo "CRF: $VIDEO_CRF"
echo "Audio: $AUDIO_CODEC / $AUDIO_BITRATE / ${AUDIO_SAMPLE_RATE} Hz"
echo "Faststart: $ENABLE_FASTSTART"
echo "Log file: $LOG_FILE"

echo
echo "Calculating total duration..."

TOTAL_DURATION=0

while IFS= read -r line; do
  FILE_PATH="${line#file \'}"
  FILE_PATH="${FILE_PATH%\'}"

  DURATION=$(ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$FILE_PATH")

  # Some MTS/M2TS files can report duration strangely; ignore broken values.
  DURATION_INT=${DURATION%.*}

  if [[ "$DURATION_INT" =~ ^[0-9]+$ ]]; then
    TOTAL_DURATION=$((TOTAL_DURATION + DURATION_INT))
  else
    echo "Warning: could not read duration for: $FILE_PATH"
  fi
done < "$LIST_FILE"

if [ "$TOTAL_DURATION" -le 0 ]; then
  echo "Warning: could not calculate total duration."
  echo "Progress will be shown from ffmpeg output, but percentage may not be accurate."
  TOTAL_DURATION=1
fi

echo "Total duration: ${TOTAL_DURATION} seconds"
echo
echo "Merging and converting..."
echo

show_progress() {
  local current="$1"
  local total="$2"
  local width=40

  if [ "$current" -lt 0 ]; then
    current=0
  fi

  if [ "$current" -gt "$total" ]; then
    current="$total"
  fi

  local percent=$((current * 100 / total))
  local filled=$((percent * width / 100))
  local empty=$((width - filled))

  printf "\r["

  if [ "$filled" -gt 0 ]; then
    printf "%0.s#" $(seq 1 "$filled")
  fi

  if [ "$empty" -gt 0 ]; then
    printf "%0.s-" $(seq 1 "$empty")
  fi

  printf "] %d%%" "$percent"
}

MOVFLAGS_ARGS=()
if [ "$ENABLE_FASTSTART" = "yes" ]; then
  MOVFLAGS_ARGS=(-movflags +faststart)
fi

# Important for MTS/AVCHD:
# -fflags +genpts helps when timestamps are weird.
# aresample=async=1 helps keep audio synced when source timestamps are uneven.
ffmpeg \
  -hide_banner \
  -loglevel error \
  -stats_period 1 \
  -progress pipe:1 \
  -fflags +genpts \
  -f concat -safe 0 -i "$LIST_FILE" \
  -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=${FPS},format=yuv420p" \
  -af "aresample=async=1:first_pts=0" \
  -c:v "$VIDEO_CODEC" -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" \
  -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" -ar "$AUDIO_SAMPLE_RATE" \
  "${MOVFLAGS_ARGS[@]}" \
  "$OUTPUT" 2>"$LOG_FILE" | while IFS='=' read -r key value; do

    if [ "$key" = "out_time_ms" ] && [[ "$value" =~ ^[0-9]+$ ]]; then
      CURRENT_SECONDS=$((value / 1000000))
      show_progress "$CURRENT_SECONDS" "$TOTAL_DURATION"
    fi

    if [ "$key" = "progress" ] && [ "$value" = "end" ]; then
      show_progress "$TOTAL_DURATION" "$TOTAL_DURATION"
      echo
    fi
  done

FFMPEG_EXIT=${PIPESTATUS[0]}

echo

if [ "$FFMPEG_EXIT" -eq 0 ]; then
  echo "Done: $OUTPUT"
  echo "List file was kept: $LIST_FILE"
  echo "Log file was kept: $LOG_FILE"
  echo "Nothing was deleted or modified."
else
  echo "Error: ffmpeg failed."
  echo "Nothing was deleted or modified."
  echo "List file was kept: $LIST_FILE"
  echo "Check the log:"
  echo "tail -50 $LOG_FILE"
  exit 1
fi
