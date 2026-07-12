#!/usr/bin/env bash

# Fast, reliable video merger for macOS / Apple Silicon (v5).
# Each source clip is normalized separately. Broken or stalled clips are skipped,
# then normalized clips are concatenated without another video re-encode.
# Requirement: Homebrew FFmpeg (`brew install ffmpeg`).

set -o pipefail

OUTPUT="merged_video.mp4"
WIDTH="1920"
HEIGHT="1080"
FPS="30"

VIDEO_CODEC="h264_videotoolbox"
VIDEO_BITRATE="12M"
VIDEO_MAXRATE="18M"
VIDEO_BUFSIZE="24M"

AUDIO_CODEC="aac"
AUDIO_BITRATE="192k"
AUDIO_SAMPLE_RATE="48000"

# Kill one clip if its temporary output does not grow for this many seconds.
STALL_TIMEOUT="120"
CHECK_INTERVAL="5"

# Keep normalized clips after completion so an interrupted run can resume.
WORK_DIR=".merge_video_work"
LOG_DIR="$WORK_DIR/logs"
NORMALIZED_DIR="$WORK_DIR/normalized"
SOURCE_LIST="$WORK_DIR/source_files.txt"
CONCAT_LIST="$WORK_DIR/normalized_files.txt"
SKIPPED_LIST="$WORK_DIR/skipped_files.txt"

fail() {
  echo "Error: $*" >&2
  exit 1
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is missing. Install it with: brew install ffmpeg"
command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is missing. Install it with: brew install ffmpeg"

ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'h264_videotoolbox' || \
  fail "h264_videotoolbox is unavailable in this FFmpeg build"

[ ! -e "$OUTPUT" ] || fail "$OUTPUT already exists. Rename or remove it first."

mkdir -p "$LOG_DIR" "$NORMALIZED_DIR" || fail "cannot create $WORK_DIR"
: > "$SOURCE_LIST"
: > "$CONCAT_LIST"
: > "$SKIPPED_LIST"

escape_concat_path() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

human_time() {
  local s="$1"
  printf '%02d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

# Natural, case-insensitive filename sorting without GNU sort -V.
# Current directory only; filenames are written as NUL-delimited records.
SOURCE_LIST="$SOURCE_LIST" OUTPUT="$OUTPUT" perl -e '
  use strict;
  use warnings;
  use File::Spec;

  my $list = $ENV{"SOURCE_LIST"};
  my $output = lc($ENV{"OUTPUT"});
  opendir(my $dh, ".") or die "Cannot open current directory: $!\n";
  my @files = grep {
    -f $_ &&
    lc($_) ne $output &&
    /\.(?:mp4|mov|mkv|webm|mts|m2ts|ts)$/i
  } readdir($dh);
  closedir($dh);

  sub natural_parts {
    my ($name) = @_;
    return map { /^\d+$/ ? [0, 0 + $_] : [1, lc($_)] } split /(\d+)/, $name;
  }

  @files = sort {
    my @a = natural_parts($a);
    my @b = natural_parts($b);
    my $n = @a > @b ? scalar(@a) : scalar(@b);
    for my $i (0 .. $n - 1) {
      return -1 if $i >= @a;
      return 1  if $i >= @b;
      my ($ta, $va) = @{$a[$i]};
      my ($tb, $vb) = @{$b[$i]};
      my $cmp = $ta <=> $tb;
      $cmp ||= $ta == 0 ? ($va <=> $vb) : ($va cmp $vb);
      return $cmp if $cmp;
    }
    return lc($a) cmp lc($b);
  } @files;

  open(my $out, ">:raw", $list) or die "Cannot write $list: $!\n";
  for my $file (@files) {
    print {$out} File::Spec->catfile(".", $file), "\0";
  }
  close($out);
'

[ -s "$SOURCE_LIST" ] || fail "no supported videos found in the current folder"

FILE_COUNT=$(perl -0ne '$n++; END { print $n+0 }' "$SOURCE_LIST")
echo "Found $FILE_COUNT video files."
echo "Work folder: $WORK_DIR"
echo "Fast mode v5: FFmpeg stdin is isolated so filenames cannot be corrupted."
echo "A clip will be skipped if output does not grow for ${STALL_TIMEOUT}s."
echo

run_with_watchdog() {
  local out="$1"
  local log="$2"
  shift 2

  "$@" </dev/null > /dev/null 2>"$log" &
  local pid=$!
  local last_size=-1
  local unchanged=0
  local size=0

  while kill -0 "$pid" 2>/dev/null; do
    sleep "$CHECK_INTERVAL"
    if [ -f "$out" ]; then
      size=$(stat -f '%z' "$out" 2>/dev/null || echo 0)
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

index=0
success=0
skipped=0

while IFS= read -r -d '' source; do
  index=$((index + 1))
  base=$(basename "$source")
  stem=$(printf '%06d' "$index")
  normalized="$NORMALIZED_DIR/${stem}.mp4"
  log="$LOG_DIR/${stem}.log"

  printf '[%d/%d] %s\n' "$index" "$FILE_COUNT" "$base"

  # Fast resume: a non-empty normalized file is reused without probing it again.
  # If it was incomplete, the final concat will report it; delete that one file and rerun.
  if [ -s "$normalized" ]; then
    echo "  Already normalized; reusing."
  else
    rm -f "$normalized"

    # Do not pre-reject video files with ffprobe. Some QuickTime/iPhone MOV files
    # report unusual stream metadata even though FFmpeg can decode them normally.
    # Probe only whether an audio stream exists; FFmpeg itself validates the video.
    has_audio=0
    if ffprobe -v error -select_streams a:0 \
        -show_entries stream=index -of csv=p=0 "$source" </dev/null 2>/dev/null | grep -q '[0-9]'; then
      has_audio=1
    fi

    common_video=(
      -map_metadata -1
      -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2,fps=${FPS},format=nv12"
      -c:v "$VIDEO_CODEC"
      -b:v "$VIDEO_BITRATE"
      -maxrate "$VIDEO_MAXRATE"
      -bufsize "$VIDEO_BUFSIZE"
      -allow_sw 1
      -pix_fmt yuv420p
      -c:a "$AUDIO_CODEC"
      -b:a "$AUDIO_BITRATE"
      -ar "$AUDIO_SAMPLE_RATE"
      -ac 2
      -movflags +faststart
      -y "$normalized"
    )

    if [ "$has_audio" -eq 1 ]; then
      command=(ffmpeg -nostdin -hide_banner -loglevel warning -fflags +genpts -i "$source"
        -map 0:v:0 -map 0:a:0?
        -af "aresample=async=1:first_pts=0"
        "${common_video[@]}")
    else
      command=(ffmpeg -nostdin -hide_banner -loglevel warning -fflags +genpts -i "$source"
        -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=${AUDIO_SAMPLE_RATE}"
        -map 0:v:0 -map 1:a:0
        -shortest
        "${common_video[@]}")
    fi

    run_with_watchdog "$normalized" "$log" "${command[@]}"
    code=$?
    if [ "$code" -ne 0 ]; then
      rm -f "$normalized"
      echo "  Failed or stalled (exit $code); skipped. Log: $log"
      printf '%s\t%s\t%s\n' "$source" "ffmpeg exit" "$code" >> "$SKIPPED_LIST"
      skipped=$((skipped + 1))
      continue
    fi

    # Successful ffmpeg exit plus a non-empty file is enough here.
    # Avoid another ffprobe pass for speed.
    if [ ! -s "$normalized" ]; then
      rm -f "$normalized"
      echo "  Empty normalized output; skipped."
      printf '%s\t%s\n' "$source" "normalized output empty" >> "$SKIPPED_LIST"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  abs_dir=$(cd "$(dirname "$normalized")" && pwd -P)
  abs_path="$abs_dir/$(basename "$normalized")"
  escaped=$(escape_concat_path "$abs_path")
  printf "file '%s'\n" "$escaped" >> "$CONCAT_LIST"
  success=$((success + 1))
done < "$SOURCE_LIST"

echo
[ "$success" -gt 0 ] || fail "all clips failed; inspect $LOG_DIR and $SKIPPED_LIST"

echo "Normalized successfully: $success"
echo "Skipped: $skipped"
echo "Joining normalized clips without re-encoding..."

FINAL_LOG="$WORK_DIR/final_concat.log"
if ffmpeg -hide_banner -loglevel warning \
    -f concat -safe 0 -i "$CONCAT_LIST" \
    -c copy -movflags +faststart -y "$OUTPUT" 2>"$FINAL_LOG"; then
  echo
  echo "Done: $OUTPUT"
  echo "Skipped-file report: $SKIPPED_LIST"
  echo "Per-clip logs: $LOG_DIR"
  echo "Normalized clips kept for resume: $NORMALIZED_DIR"
else
  rm -f "$OUTPUT"
  fail "final concatenation failed. Check: $FINAL_LOG"
fi
