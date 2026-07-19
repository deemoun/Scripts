#!/usr/bin/env bash

# Duplicate-safe chronological video merger for Linux (v10).
#
# Guarantees:
#   - Exact duplicate source files are included only once (SHA-256 deduplication).
#   - Hidden files/folders, macOS metadata, Linux/Windows trash metadata,
#     stale work caches, application-library packages, temporary files,
#     incomplete downloads, and symlinks are ignored before hashing.
#   - Normalized cache files are bound to the source SHA-256 hash and settings.
#   - Normal videos are placed before very short likely Live Photo clips.
#   - Reliable capture timestamps are sorted chronologically.
#   - Files with unclear timestamps are placed last within their video class.
#   - The final concat list is rebuilt from scratch and checked for duplicates.
#   - Original source files are never modified or deleted.
#
# Typical Debian/Ubuntu requirement:
#   sudo apt install ffmpeg coreutils

set -o pipefail

# =========================
# User settings
# =========================

START_DIR=$(pwd -P)
OUTPUT="$START_DIR/merged_video.mp4"
TIMELINE_OUTPUT="$START_DIR/merged_video_timeline.csv"

WIDTH="1920"
HEIGHT="1080"
FPS="30"

# iPhone Live Photo motion clips are normally around 3 seconds.
LIKELY_LIVE_PHOTO_MAX_SECONDS="4.0"

VIDEO_CODEC="libx264"
VIDEO_PRESET="fast"
VIDEO_CRF="18"

AUDIO_CODEC="aac"
AUDIO_BITRATE="192k"
AUDIO_SAMPLE_RATE="48000"

# "yes" moves MP4 metadata to the beginning for faster browser playback.
# For very large archive outputs, "no" avoids the additional finalization pass.
ENABLE_FASTSTART="no"

# Stop a single conversion if its output file does not grow for this long.
STALL_TIMEOUT="120"
CHECK_INTERVAL="5"

# =========================
# Internal paths
# =========================

WORK_DIR="$START_DIR/.merge_video_work"
LOG_DIR="$WORK_DIR/logs"
NORMALIZED_DIR="$WORK_DIR/normalized"
RAW_LIST="$WORK_DIR/source_files.nul"
SOURCE_LIST="$WORK_DIR/source_files.tsv"
CONCAT_LIST="$WORK_DIR/normalized_files.txt"
ORDER_LIST="$WORK_DIR/normalized_order.tsv"
SORTED_ORDER_LIST="$WORK_DIR/normalized_order_sorted.tsv"
SKIPPED_LIST="$WORK_DIR/skipped_files.tsv"
DUPLICATE_LIST="$WORK_DIR/duplicate_sources.tsv"
MANIFEST="$WORK_DIR/manifest.tsv"
HASH_INDEX="$WORK_DIR/hash_index.tsv"
TIMELINE_TMP="$WORK_DIR/merged_video_timeline.csv"
FINAL_LOG="$WORK_DIR/final_concat.log"

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is missing"
}

require_command ffmpeg
require_command ffprobe
require_command sha256sum
require_command find
require_command sort
require_command stat
require_command date
require_command awk
require_command sed
require_command grep
require_command tr

ffmpeg -hide_banner -encoders 2>/dev/null | grep -F " ${VIDEO_CODEC} " >/dev/null || \
  fail "$VIDEO_CODEC is unavailable in this FFmpeg build"

[ ! -e "$OUTPUT" ] || fail "$OUTPUT already exists. Rename or remove it first."
[ ! -e "$TIMELINE_OUTPUT" ] || fail "$TIMELINE_OUTPUT already exists. Rename or remove it first."

mkdir -p "$LOG_DIR" "$NORMALIZED_DIR" || fail "cannot create $WORK_DIR"

: > "$RAW_LIST"
: > "$SOURCE_LIST"
: > "$CONCAT_LIST"
: > "$ORDER_LIST"
: > "$SORTED_ORDER_LIST"
: > "$SKIPPED_LIST"
: > "$DUPLICATE_LIST"
: > "$MANIFEST"
: > "$HASH_INDEX"
: > "$TIMELINE_TMP"

printf '%s\n' \
  'sequence,source_file,source_name,sha256,start_seconds,end_seconds,duration_seconds,source_duration_seconds,creation_time,file_modified_time,location_iso6709,latitude,longitude,altitude_m,width,height,avg_frame_rate,video_codec,audio_codec,has_audio,rotation_degrees,file_size_bytes,export_fps,normalized_file' \
  > "$TIMELINE_TMP"

escape_concat_path() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

csv_quote() {
  local value="$1"
  value=${value//\"/\"\"}
  printf '"%s"' "$value"
}

probe_value() {
  ffprobe -v error \
    -show_entries "$2" \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" </dev/null 2>/dev/null | head -n 1
}

probe_tag() {
  local file="$1"
  local wanted="$2"

  ffprobe -v error \
    -show_entries format_tags \
    -of default=noprint_wrappers=1 \
    "$file" </dev/null 2>/dev/null | \
    awk -F= -v wanted="$wanted" '
      {
        key=$1
        sub(/^TAG:/, "", key)
        if (tolower(key) == tolower(wanted)) {
          sub(/^[^=]*=/, "")
          print
          exit
        }
      }
    '
}

# Output:
#   epoch<TAB>YYYY-MM-DD_HH-MM-SS<TAB>metadata|filename
#
# Embedded recording metadata and recognizable filename timestamps are
# considered reliable. Files without either are deliberately placed later.
extract_capture_timestamp() {
  local file="$1"
  local raw=""
  local base=""
  local epoch=""
  local label=""
  local year month day hour minute second

  raw=$(probe_tag "$file" 'creation_time')
  [ -n "$raw" ] || raw=$(probe_tag "$file" 'com.apple.quicktime.creationdate')
  [ -n "$raw" ] || raw=$(probe_tag "$file" 'date')

  if [ -n "$raw" ]; then
    epoch=$(TZ=UTC date -d "$raw" +%s 2>/dev/null || true)

    if [[ "$raw" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})[T\ ]([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
      label="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}_${BASH_REMATCH[4]}-${BASH_REMATCH[5]}-${BASH_REMATCH[6]}"
    elif [ -n "$epoch" ]; then
      label=$(TZ=UTC date -d "@$epoch" '+%Y-%m-%d_%H-%M-%S' 2>/dev/null || true)
    fi

    if [[ "$epoch" =~ ^-?[0-9]+$ ]] && [ -n "$label" ]; then
      printf '%s\t%s\tmetadata\n' "$epoch" "$label"
      return 0
    fi
  fi

  base=$(basename "$file")

  # Examples handled:
  #   20260718_123456.mp4
  #   2026-07-18 12-34-56.mov
  #   IMG_2026.07.18_12.34.56.mp4
  if [[ "$base" =~ (^|[^0-9])(19[0-9]{2}|20[0-9]{2})[-_.]?([01][0-9])[-_.]?([0-3][0-9])[T\ _.-]?([0-2][0-9])[-_.:]?([0-5][0-9])[-_.:]?([0-5][0-9])([^0-9]|$) ]]; then
    year="${BASH_REMATCH[2]}"
    month="${BASH_REMATCH[3]}"
    day="${BASH_REMATCH[4]}"
    hour="${BASH_REMATCH[5]}"
    minute="${BASH_REMATCH[6]}"
    second="${BASH_REMATCH[7]}"

    epoch=$(TZ=UTC date -d "$year-$month-$day $hour:$minute:$second" +%s 2>/dev/null || true)
    if [[ "$epoch" =~ ^-?[0-9]+$ ]]; then
      printf '%s\t%s-%s-%s_%s-%s-%s\tfilename\n' \
        "$epoch" "$year" "$month" "$day" "$hour" "$minute" "$second"
      return 0
    fi
  fi

  # Date-only filenames are accepted, with midnight used as their sort time.
  if [[ "$base" =~ (^|[^0-9])(19[0-9]{2}|20[0-9]{2})[-_.]([01][0-9])[-_.]([0-3][0-9])([^0-9]|$) ]]; then
    year="${BASH_REMATCH[2]}"
    month="${BASH_REMATCH[3]}"
    day="${BASH_REMATCH[4]}"

    epoch=$(TZ=UTC date -d "$year-$month-$day 00:00:00" +%s 2>/dev/null || true)
    if [[ "$epoch" =~ ^-?[0-9]+$ ]]; then
      printf '%s\t%s-%s-%s_00-00-00\tfilename\n' "$epoch" "$year" "$month" "$day"
      return 0
    fi
  fi

  return 1
}

probe_source_fps() {
  local file="$1"
  local rate

  rate=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=avg_frame_rate,r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 \
    "$file" </dev/null 2>/dev/null | \
    awk '$0 != "0/0" && $0 != "N/A" && NF { print; exit }')

  printf '%s\n' "$rate" | awk -F/ '
    NF == 2 && $2 != 0 { printf "%.6f\n", $1 / $2; next }
    NF == 1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ { printf "%.6f\n", $1 }
  '
}

nominal_fps() {
  awk -v fps="$1" 'BEGIN {
    if (fps == "" || fps <= 0) exit 1
    printf "%d\n", int(fps + 0.5)
  }'
}

parse_iso6709() {
  local location="$1"

  if [[ "$location" =~ ^([+-][0-9]+([.][0-9]+)?)([+-][0-9]+([.][0-9]+)?)([+-][0-9]+([.][0-9]+)?)?/?$ ]]; then
    printf '%s\t%s\t%s\n' \
      "${BASH_REMATCH[1]}" \
      "${BASH_REMATCH[3]}" \
      "${BASH_REMATCH[5]}"
  else
    printf '\t\t\n'
  fi
}

append_timeline_row() {
  local sequence="$1"
  local source="$2"
  local hash="$3"
  local normalized="$4"
  local start_seconds="$5"
  local duration_seconds="$6"

  local end_seconds source_duration creation_time file_modified location
  local latitude longitude altitude width height avg_frame_rate video_codec
  local audio_codec has_audio rotation file_size source_name value field_number

  end_seconds=$(awk -v a="$start_seconds" -v b="$duration_seconds" 'BEGIN { printf "%.6f", a+b }')
  source_name=$(basename "$source")
  source_duration=$(probe_value "$source" 'format=duration')

  creation_time=$(probe_tag "$source" 'creation_time')
  [ -n "$creation_time" ] || creation_time=$(probe_tag "$source" 'com.apple.quicktime.creationdate')
  [ -n "$creation_time" ] || creation_time=$(probe_tag "$source" 'date')

  file_modified=$(stat -c '%y' "$source" 2>/dev/null || true)

  location=$(probe_tag "$source" 'com.apple.quicktime.location.ISO6709')
  [ -n "$location" ] || location=$(probe_tag "$source" 'location')
  [ -n "$location" ] || location=$(probe_tag "$source" 'location-eng')

  IFS=$'\t' read -r latitude longitude altitude <<EOLOC
$(parse_iso6709 "$location")
EOLOC

  width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n 1)
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
    -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n 1)
  avg_frame_rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n 1)
  video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n 1)
  audio_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n 1)

  if [ -n "$audio_codec" ]; then
    has_audio=1
  else
    has_audio=0
  fi

  rotation=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream_tags=rotate:stream_side_data=rotation \
    -of default=noprint_wrappers=1:nokey=1 \
    "$source" </dev/null 2>/dev/null | head -n 1)

  file_size=$(stat -c '%s' "$source" 2>/dev/null || true)

  field_number=0
  for value in \
    "$sequence" "$source" "$source_name" "$hash" \
    "$start_seconds" "$end_seconds" "$duration_seconds" "$source_duration" \
    "$creation_time" "$file_modified" "$location" "$latitude" "$longitude" \
    "$altitude" "$width" "$height" "$avg_frame_rate" "$video_codec" \
    "$audio_codec" "$has_audio" "$rotation" "$file_size" "$FPS" "$normalized"; do

    [ "$field_number" -eq 0 ] || printf ','
    csv_quote "$value"
    field_number=$((field_number + 1))
  done >> "$TIMELINE_TMP"

  printf '\n' >> "$TIMELINE_TMP"
  TIMELINE_CURSOR="$end_seconds"
}

run_with_watchdog() {
  local out="$1"
  local log="$2"
  shift 2

  "$@" </dev/null >/dev/null 2>"$log" &
  local pid=$!
  local last_size=-1
  local unchanged=0
  local size=0

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$CHECK_INTERVAL"

    if [ -f "$out" ]; then
      size=$(stat -c '%s' "$out" 2>/dev/null || echo 0)
    else
      size=0
    fi

    if [ "$size" -gt "$last_size" ]; then
      last_size="$size"
      unchanged=0
    else
      unchanged=$((unchanged + CHECK_INTERVAL))
    fi

    if [ "$unchanged" -ge "$STALL_TIMEOUT" ]; then
      echo "  Stalled for ${STALL_TIMEOUT}s; terminating clip."
      kill "$pid" 2>/dev/null || true
      sleep 2
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
  done

  wait "$pid"
}

is_tsv_safe_path() {
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
    *) return 0 ;;
  esac
}

is_junk_filename() {
  local name="$1"
  local lower
  lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')

  case "$name" in
    .*|~\$*|*~) return 0 ;;
  esac

  case "$lower" in
    thumbs.db|desktop.ini|icon$'\r') return 0 ;;
  esac

  # Catches files such as clip.tmp.mp4 or clip.partial.mov.
  if [[ "$lower" =~ \.(tmp|temp|part|partial|download|crdownload|icloud)\.(mp4|mov|mkv|webm|mts|m2ts|ts|avi|m4v|mpg|mpeg|3gp|vob)$ ]]; then
    return 0
  fi

  return 1
}

# Ask whether source discovery should include subfolders.
while true; do
  printf 'Search subfolders too? [y/n]: '
  IFS= read -r recursive_answer

  case "$recursive_answer" in
    y|Y) RECURSIVE="1"; break ;;
    n|N) RECURSIVE="0"; break ;;
    *) echo "Please enter y or n." ;;
  esac
done

echo
echo "Scanning for source videos..."

# Reject junk directories before file probing or hashing. Hidden directories
# include .git, .cache, .Trash-*, .merge_video_work, and macOS metadata folders.
discover_sources() {
  if [ "$RECURSIVE" = "1" ]; then
    find "$START_DIR" -mindepth 1 \
      \( -type d \( \
        -name '.*' -o \
        -iname '__MACOSX' -o \
        -iname '@eaDir' -o \
        -iname 'lost+found' -o \
        -iname 'System Volume Information' -o \
        -iname '$RECYCLE.BIN' -o \
        -iname 'RECYCLED' -o \
        -iname 'Trash' -o \
        -iname 'Temporary Items' -o \
        -iname 'Network Trash Folder' -o \
        -iname '*.photoslibrary' -o \
        -iname '*.photolibrary' -o \
        -iname '*.imovielibrary' -o \
        -iname '*.fcpbundle' -o \
        -iname '*.fcpevent' -o \
        -iname '*.fcpproject' -o \
        -iname '*.app' -o \
        -iname '*.bundle' -o \
        -iname '*.framework' -o \
        -iname '*.logicx' -o \
        -iname '*.band' \
      \) -prune \) -o \
      \( -type f ! -name '.*' \( \
        -iname '*.mp4' -o \
        -iname '*.mov' -o \
        -iname '*.mkv' -o \
        -iname '*.webm' -o \
        -iname '*.mts' -o \
        -iname '*.m2ts' -o \
        -iname '*.ts' -o \
        -iname '*.avi' -o \
        -iname '*.m4v' -o \
        -iname '*.mpg' -o \
        -iname '*.mpeg' -o \
        -iname '*.3gp' -o \
        -iname '*.vob' \
      \) -print0 \)
  else
    find "$START_DIR" -mindepth 1 -maxdepth 1 \
      -type f ! -name '.*' \( \
        -iname '*.mp4' -o \
        -iname '*.mov' -o \
        -iname '*.mkv' -o \
        -iname '*.webm' -o \
        -iname '*.mts' -o \
        -iname '*.m2ts' -o \
        -iname '*.ts' -o \
        -iname '*.avi' -o \
        -iname '*.m4v' -o \
        -iname '*.mpg' -o \
        -iname '*.mpeg' -o \
        -iname '*.3gp' -o \
        -iname '*.vob' \
      \) -print0
  fi
}

discover_sources | LC_ALL=C sort -zV > "$RAW_LIST"

[ -s "$RAW_LIST" ] || fail "no supported videos found"

TOTAL=$(tr -cd '\000' < "$RAW_LIST" | wc -c | tr -d ' ')
echo "Found $TOTAL candidate video files."
echo "Hashing source files to guarantee exact deduplication..."
echo

unique=0
duplicates=0
index=0

while IFS= read -r -d '' source; do
  index=$((index + 1))
  base=$(basename "$source")

  if [ "$source" = "$OUTPUT" ]; then
    continue
  fi

  if is_junk_filename "$base"; then
    echo "[skip $index/$TOTAL] Junk file: $base"
    printf '%s\t%s\n' "$source" "junk filename" >> "$SKIPPED_LIST"
    continue
  fi

  if ! is_tsv_safe_path "$source"; then
    echo "[skip $index/$TOTAL] Filename contains a tab or newline: $base"
    printf '%q\t%s\n' "$source" "unsupported control character in path" >> "$SKIPPED_LIST"
    continue
  fi

  printf '[hash %d/%d] %s\n' "$index" "$TOTAL" "$base"

  hash=$(sha256sum -- "$source" 2>/dev/null | awk '{ print $1 }')
  if [ -z "$hash" ]; then
    printf '%s\t%s\n' "$source" "hash failed" >> "$SKIPPED_LIST"
    echo "  Hash failed; skipped."
    continue
  fi

  original=$(awk -F '\t' -v h="$hash" '
    $1 == h {
      sub($1 FS, "")
      print
      exit
    }
  ' "$HASH_INDEX")

  if [ -n "$original" ]; then
    printf '%s\t%s\t%s\n' "$source" "$hash" "$original" >> "$DUPLICATE_LIST"
    echo "  Exact duplicate; excluded. Original: $original"
    duplicates=$((duplicates + 1))
    continue
  fi

  printf '%s\t%s\n' "$hash" "$source" >> "$HASH_INDEX"
  printf '%s\t%s\n' "$hash" "$source" >> "$SOURCE_LIST"
  unique=$((unique + 1))
done < "$RAW_LIST"

rm -f "$RAW_LIST"

[ "$unique" -gt 0 ] || fail "no unique readable source files remain"

# Inspect frame rates before normalization. Export FPS is never offered above
# 60, even when a high-speed or slow-motion source reports 120/240/600 fps.
MAX_SOURCE_FPS="0"
MAX_SOURCE_FPS_EXACT="0.000000"
MAX_SOURCE_FPS_FILE=""
FPS_PROBED=0
FPS_UNKNOWN=0

echo
echo "Checking source frame rates..."

while IFS=$'\t' read -r hash source; do
  source_fps=$(probe_source_fps "$source")

  if [ -z "$source_fps" ]; then
    FPS_UNKNOWN=$((FPS_UNKNOWN + 1))
    continue
  fi

  FPS_PROBED=$((FPS_PROBED + 1))
  source_nominal=$(nominal_fps "$source_fps" 2>/dev/null || echo 0)

  if [ "$source_nominal" -gt 60 ]; then
    source_nominal=60
    source_fps="60.000000"
  fi

  if awk -v a="$source_fps" -v b="$MAX_SOURCE_FPS_EXACT" 'BEGIN { exit !(a > b) }'; then
    MAX_SOURCE_FPS_EXACT="$source_fps"
    MAX_SOURCE_FPS="$source_nominal"
    MAX_SOURCE_FPS_FILE="$source"
  fi
done < "$SOURCE_LIST"

if [ "$FPS_PROBED" -gt 0 ]; then
  echo "Highest detected source FPS: ${MAX_SOURCE_FPS_EXACT} (nominal ${MAX_SOURCE_FPS} fps)"
  echo "Current export FPS: ${FPS} fps"

  if [ "$MAX_SOURCE_FPS" -gt "$FPS" ]; then
    echo "Higher-frame-rate source: $(basename "$MAX_SOURCE_FPS_FILE")"

    while true; do
      printf 'Export all clips at %s fps instead of %s fps? [y/n]: ' "$MAX_SOURCE_FPS" "$FPS"
      IFS= read -r fps_answer

      case "$fps_answer" in
        y|Y)
          FPS="$MAX_SOURCE_FPS"
          echo "Export FPS changed to ${FPS} fps."
          break
          ;;
        n|N)
          echo "Export FPS remains ${FPS} fps."
          break
          ;;
        *) echo "Please enter y or n." ;;
      esac
    done
  fi
else
  echo "Warning: frame rate could not be detected for any source; using ${FPS} fps."
fi

if [ "$FPS_UNKNOWN" -gt 0 ]; then
  echo "Warning: FPS could not be read from ${FPS_UNKNOWN} source file(s)."
fi

echo
echo "Unique files: $unique"
echo "Exact duplicates excluded: $duplicates"
echo "Work folder: $WORK_DIR"
echo "Encoder: ${VIDEO_CODEC}, preset ${VIDEO_PRESET}, CRF ${VIDEO_CRF}"
echo "Cache identity: SHA-256 + ${WIDTH}x${HEIGHT} + ${FPS}fps + codec settings"
echo

success=0
skipped=0
index=0

# Phase 1: normalize each unique source. The cache filename includes the source
# hash and all settings that affect stream compatibility.
while IFS=$'\t' read -r hash source; do
  index=$((index + 1))
  base=$(basename "$source")

  timestamp_info=$(extract_capture_timestamp "$source" 2>/dev/null || true)

  if [ -n "$timestamp_info" ]; then
    IFS=$'\t' read -r capture_epoch capture_label timestamp_source <<EOTS
$timestamp_info
EOTS
    timestamp_group="0"
  else
    capture_epoch=$(stat -c '%Y' "$source" 2>/dev/null || echo 0)
    capture_label="UNKNOWN"
    timestamp_source="unclear"
    timestamp_group="1"
  fi

  normalized_name="${capture_label}__${hash}_${WIDTH}x${HEIGHT}_${FPS}fps_${VIDEO_CODEC}_${VIDEO_PRESET}_crf${VIDEO_CRF}.mp4"
  normalized="$NORMALIZED_DIR/$normalized_name"
  log="$LOG_DIR/${hash}_${WIDTH}x${HEIGHT}_${FPS}fps_${VIDEO_CODEC}.log"

  printf '[%d/%d] %s\n' "$index" "$unique" "$base"

  if [ "$timestamp_group" = "0" ]; then
    echo "  Capture time: ${capture_label} (${timestamp_source})"
  else
    echo "  Capture time unclear; placed last within its video class."
  fi

  if [ -s "$normalized" ]; then
    echo "  Hash-matched normalized file exists; safely reusing."
  else
    # Remove obsolete cache variants for this exact source hash only.
    find "$NORMALIZED_DIR" -maxdepth 1 -type f \
      -name "*${hash}_${WIDTH}x${HEIGHT}_${FPS}fps_${VIDEO_CODEC}_*.mp4" \
      ! -path "$normalized" -delete 2>/dev/null || true

    rm -f "$normalized"

    has_audio=0
    if ffprobe -v error -select_streams a:0 \
      -show_entries stream=index -of csv=p=0 \
      "$source" </dev/null 2>/dev/null | grep -q '[0-9]'; then
      has_audio=1
    fi

    common_video=(
      -map_metadata -1
      -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=${FPS},format=yuv420p"
      -c:v "$VIDEO_CODEC"
      -preset "$VIDEO_PRESET"
      -crf "$VIDEO_CRF"
      -pix_fmt yuv420p
      -c:a "$AUDIO_CODEC"
      -b:a "$AUDIO_BITRATE"
      -ar "$AUDIO_SAMPLE_RATE"
      -ac 2
      -y "$normalized"
    )

    if [ "$has_audio" -eq 1 ]; then
      command=(
        ffmpeg -nostdin -hide_banner -loglevel warning
        -fflags +genpts
        -i "$source"
        -map 0:v:0 -map 0:a:0?
        -af "aresample=async=1:first_pts=0"
        "${common_video[@]}"
      )
    else
      command=(
        ffmpeg -nostdin -hide_banner -loglevel warning
        -fflags +genpts
        -i "$source"
        -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=${AUDIO_SAMPLE_RATE}"
        -map 0:v:0 -map 1:a:0
        -shortest
        "${common_video[@]}"
      )
    fi

    run_with_watchdog "$normalized" "$log" "${command[@]}"
    code=$?

    if [ "$code" -ne 0 ]; then
      rm -f "$normalized"
      echo "  Failed or stalled (exit $code); skipped. Log: $log"
      printf '%s\t%s\t%s\t%s\n' "$source" "$hash" "ffmpeg exit" "$code" >> "$SKIPPED_LIST"
      skipped=$((skipped + 1))
      continue
    fi

    if [ ! -s "$normalized" ]; then
      rm -f "$normalized"
      echo "  Empty normalized output; skipped."
      printf '%s\t%s\t%s\n' "$source" "$hash" "normalized output empty" >> "$SKIPPED_LIST"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  normalized_duration=$(probe_value "$normalized" 'format=duration')

  if ! printf '%s' "$normalized_duration" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
    echo "  Could not determine normalized duration; skipped."
    printf '%s\t%s\t%s\n' "$source" "$hash" "normalized duration unavailable" >> "$SKIPPED_LIST"
    skipped=$((skipped + 1))
    continue
  fi

  printf '%s\t%s\t%s\t%sx%s\t%sfps\t%s\t%s\t%s\t%s\n' \
    "$hash" "$source" "$normalized" "$WIDTH" "$HEIGHT" "$FPS" \
    "$capture_label" "$timestamp_source" "$VIDEO_CODEC" "crf${VIDEO_CRF}" \
    >> "$MANIFEST"

  likely_live_photo=$(awk -v d="$normalized_duration" -v limit="$LIKELY_LIVE_PHOTO_MAX_SECONDS" \
    'BEGIN { print (d <= limit) ? 1 : 0 }')

  # Sorting groups:
  #   0 = normal video, reliable timestamp
  #   1 = normal video, unclear timestamp
  #   2 = likely Live Photo clip, reliable timestamp
  #   3 = likely Live Photo clip, unclear timestamp
  if [ "$likely_live_photo" -eq 1 ]; then
    sort_group=$((2 + timestamp_group))
    echo "  Short clip (${normalized_duration}s); placed after normal videos."
  else
    sort_group="$timestamp_group"
  fi

  printf '%s\t%020d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sort_group" "$capture_epoch" "$source" "$hash" "$normalized" \
    "$normalized_duration" "$capture_label" "$timestamp_source" \
    >> "$ORDER_LIST"

  success=$((success + 1))
done < "$SOURCE_LIST"

[ "$success" -gt 0 ] || fail "all clips failed; inspect $LOG_DIR and $SKIPPED_LIST"

# Phase 2: chronological ordering, concat list, and timeline.
LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3 -k4,4 \
  "$ORDER_LIST" > "$SORTED_ORDER_LIST" || fail "could not sort normalized clips"

TIMELINE_CURSOR="0.000000"
sequence=0

while IFS=$'\t' read -r sort_group capture_epoch source hash normalized normalized_duration capture_label timestamp_source; do
  sequence=$((sequence + 1))
  abs_dir=$(cd "$(dirname "$normalized")" && pwd -P)
  abs_path="$abs_dir/$(basename "$normalized")"
  escaped=$(escape_concat_path "$abs_path")

  if grep -Fqx "file '$escaped'" "$CONCAT_LIST"; then
    fail "duplicate normalized path detected while building concat list"
  fi

  printf "file '%s'\n" "$escaped" >> "$CONCAT_LIST"
  append_timeline_row "$sequence" "$source" "$hash" "$normalized" \
    "$TIMELINE_CURSOR" "$normalized_duration"
done < "$SORTED_ORDER_LIST"

# Hard assertion: the final concat list may not contain duplicate lines.
if [ "$(LC_ALL=C sort "$CONCAT_LIST" | uniq -d | wc -l | tr -d ' ')" -ne 0 ]; then
  fail "duplicate entries detected in concat list; refusing to create output"
fi

normal_reliable_count=$(awk -F '\t' '$1 == 0 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
normal_unclear_count=$(awk -F '\t' '$1 == 1 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
live_reliable_count=$(awk -F '\t' '$1 == 2 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
live_unclear_count=$(awk -F '\t' '$1 == 3 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
likely_live_count=$((live_reliable_count + live_unclear_count))
unclear_count=$((normal_unclear_count + live_unclear_count))

echo
echo "Normalized successfully: $success"
echo "Normal videos with reliable timestamps: $normal_reliable_count"
echo "Normal videos with unclear timestamps: $normal_unclear_count"
echo "Likely Live Photo clips (<= ${LIKELY_LIVE_PHOTO_MAX_SECONDS}s): $likely_live_count"
echo "Likely Live Photo clips with unclear timestamps: $live_unclear_count"
echo "Total unclear timestamps: $unclear_count"
echo "Export frame rate: ${FPS} fps"
echo "Skipped: $skipped"
echo "Exact duplicates excluded: $duplicates"
echo "Joining normalized clips without re-encoding..."

MOVFLAGS_ARGS=()
if [ "$ENABLE_FASTSTART" = "yes" ]; then
  MOVFLAGS_ARGS=(-movflags +faststart)
fi

if ffmpeg -nostdin -hide_banner -loglevel warning \
  -f concat -safe 0 -i "$CONCAT_LIST" \
  -c copy "${MOVFLAGS_ARGS[@]}" -y "$OUTPUT" 2>"$FINAL_LOG"; then

  cp "$TIMELINE_TMP" "$TIMELINE_OUTPUT" || fail "could not write timeline CSV"

  echo
  echo "Done: $OUTPUT"
  echo "Timeline CSV: $TIMELINE_OUTPUT"
  echo "Manifest: $MANIFEST"
  echo "Duplicate report: $DUPLICATE_LIST"
  echo "Skipped-file report: $SKIPPED_LIST"
  echo "Final FFmpeg log: $FINAL_LOG"
  echo "Hash-bound normalized cache kept at: $NORMALIZED_DIR"
  echo "Original files were not modified or deleted."
else
  rm -f "$OUTPUT"
  fail "final concatenation failed. Check: $FINAL_LOG"
fi
