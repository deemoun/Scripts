#!/usr/bin/env bash

# Duplicate-safe chronological video merger for macOS / Apple Silicon (v9, Bash 3.2 compatible).
# Guarantees:
#   - Exact duplicate source files are included only once (SHA-256 deduplication).
#   - macOS metadata, hidden files/folders, stale work caches, package contents,
#     temporary downloads, and symlinks are ignored before hashing.
#   - Normalized cache files are named by source content hash, not list position.
#   - Normalized files are renamed with capture timestamps when reliably known.
#   - Normal videos are prioritized over very short likely Live Photo clips.
#   - Within each class, reliable capture times are chronological and unclear timestamps are last.
#   - Resume reuse is allowed only when the hash-bound normalized file exists.
#   - The final concat list is rebuilt from scratch and checked for duplicates.
#
# Requirement:
#   brew install ffmpeg
#
# Important:
#   Old index-based caches from v5 and earlier are NOT trusted or reused.
#   This script uses .merge_video_work_v6.

set -o pipefail

START_DIR=$(pwd -P)
OUTPUT="$START_DIR/merged_video.mp4"
WIDTH="1920"
HEIGHT="1080"
FPS="30"

# iPhone Live Photo motion clips are normally about 3 seconds long.
# Use a slightly tolerant threshold so container/encoding rounding still catches them.
LIKELY_LIVE_PHOTO_MAX_SECONDS="4.0"

VIDEO_CODEC="h264_videotoolbox"
VIDEO_BITRATE="12M"
VIDEO_MAXRATE="18M"
VIDEO_BUFSIZE="24M"

AUDIO_CODEC="aac"
AUDIO_BITRATE="192k"
AUDIO_SAMPLE_RATE="48000"

STALL_TIMEOUT="120"
CHECK_INTERVAL="5"

WORK_DIR="$START_DIR/.merge_video_work"
LOG_DIR="$WORK_DIR/logs"
NORMALIZED_DIR="$WORK_DIR/normalized"
SOURCE_LIST="$WORK_DIR/source_files.tsv"
CONCAT_LIST="$WORK_DIR/normalized_files.txt"
ORDER_LIST="$WORK_DIR/normalized_order.tsv"
SORTED_ORDER_LIST="$WORK_DIR/normalized_order_sorted.tsv"
SKIPPED_LIST="$WORK_DIR/skipped_files.tsv"
DUPLICATE_LIST="$WORK_DIR/duplicate_sources.tsv"
MANIFEST="$WORK_DIR/manifest.tsv"
TIMELINE_TMP="$WORK_DIR/merged_video_timeline.csv"
TIMELINE_OUTPUT="$START_DIR/merged_video_timeline.csv"

fail() {
  echo "Error: $*" >&2
  exit 1
}

command -v ffmpeg >/dev/null 2>&1 || fail "ffmpeg is missing. Install it with: brew install ffmpeg"
command -v ffprobe >/dev/null 2>&1 || fail "ffprobe is missing. Install it with: brew install ffmpeg"
command -v shasum >/dev/null 2>&1 || fail "shasum is missing"

ffmpeg -hide_banner -encoders 2>/dev/null | grep -q 'h264_videotoolbox' || \
  fail "h264_videotoolbox is unavailable in this FFmpeg build"

[ ! -e "$OUTPUT" ] || fail "$OUTPUT already exists. Rename or remove it first."
[ ! -e "$TIMELINE_OUTPUT" ] || fail "$TIMELINE_OUTPUT already exists. Rename or remove it first."

mkdir -p "$LOG_DIR" "$NORMALIZED_DIR" || fail "cannot create $WORK_DIR"
: > "$SOURCE_LIST"
: > "$CONCAT_LIST"
: > "$ORDER_LIST"
: > "$SORTED_ORDER_LIST"
: > "$SKIPPED_LIST"
: > "$DUPLICATE_LIST"
: > "$MANIFEST"
: > "$TIMELINE_TMP"
printf '%s\n' 'sequence,source_file,source_name,sha256,start_seconds,end_seconds,duration_seconds,source_duration_seconds,creation_time,file_modified_time,location_iso6709,latitude,longitude,altitude_m,width,height,avg_frame_rate,video_codec,audio_codec,has_audio,rotation_degrees,file_size_bytes,export_fps,normalized_file' > "$TIMELINE_TMP"

escape_concat_path() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

csv_quote() {
  printf '%s' "$1" | perl -0pe 's/"/""/g; $_ = qq{"$_"}'
}

probe_value() {
  ffprobe -v error -show_entries "$2" -of default=noprint_wrappers=1:nokey=1 "$1" </dev/null 2>/dev/null | head -n 1
}

probe_tag() {
  local file="$1" wanted="$2"
  ffprobe -v error -show_entries format_tags -of default=noprint_wrappers=1 "$file" </dev/null 2>/dev/null | awk -F= -v wanted="$wanted" 'BEGIN{IGNORECASE=1}{key=$1;sub(/^TAG:/,"",key);if(tolower(key)==tolower(wanted)){sub(/^[^=]*=/,"");print;exit}}'
}

# Return: epoch<TAB>YYYY-MM-DD_HH-MM-SS<TAB>timestamp_source
# Only embedded recording metadata and recognizable filename timestamps are
# treated as reliable. Files without either are deliberately placed last.
extract_capture_timestamp() {
  local file="$1" raw base parsed

  raw=$(probe_tag "$file" 'creation_time')
  [ -n "$raw" ] || raw=$(probe_tag "$file" 'com.apple.quicktime.creationdate')
  [ -n "$raw" ] || raw=$(probe_tag "$file" 'date')

  if [ -n "$raw" ]; then
    parsed=$(printf '%s\n' "$raw" | perl -MTime::Local=timegm -ne '
      chomp;
      if (/^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([+-])(\d{2}):?(\d{2}))?/) {
        my ($Y,$m,$d,$H,$M,$S,$sgn,$oh,$om)=($1,$2,$3,$4,$5,$6,$7,$8,$9);
        my $epoch;
        eval { $epoch=timegm($S,$M,$H,$d,$m-1,$Y); };
        if (defined $epoch) {
          if (defined $sgn) {
            my $off=(($oh||0)*3600)+(($om||0)*60);
            $epoch += ($sgn eq "+") ? -$off : $off;
          }
          printf "%d\t%04d-%02d-%02d_%02d-%02d-%02d\tmetadata\n",$epoch,$Y,$m,$d,$H,$M,$S;
        }
      }
    ')
    if [ -n "$parsed" ]; then
      printf '%s\n' "$parsed"
      return 0
    fi
  fi

  base=$(basename "$file")
  parsed=$(printf '%s\n' "$base" | perl -MTime::Local=timegm -ne '
    chomp;
    my ($Y,$m,$d,$H,$M,$S);
    if (/(?:^|[^0-9])((?:19|20)\d{2})[-_.]?([01]\d)[-_.]?([0-3]\d)[T _.-]?([0-2]\d)[-_.:]?([0-5]\d)[-_.:]?([0-5]\d)(?:[^0-9]|$)/) {
      ($Y,$m,$d,$H,$M,$S)=($1,$2,$3,$4,$5,$6);
    } elsif (/(?:^|[^0-9])((?:19|20)\d{2})[-_.]([01]\d)[-_.]([0-3]\d)(?:[^0-9]|$)/) {
      ($Y,$m,$d,$H,$M,$S)=($1,$2,$3,0,0,0);
    }
    if (defined $Y) {
      my $epoch;
      eval { $epoch=timegm($S,$M,$H,$d,$m-1,$Y); };
      if (defined $epoch) {
        printf "%d\t%04d-%02d-%02d_%02d-%02d-%02d\tfilename\n",$epoch,$Y,$m,$d,$H,$M,$S;
      }
    }
  ')
  if [ -n "$parsed" ]; then
    printf '%s\n' "$parsed"
    return 0
  fi

  return 1
}

probe_source_fps() {
  local file="$1" rate
  rate=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=avg_frame_rate,r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$file" </dev/null 2>/dev/null | \
    awk '$0 != "0/0" && $0 != "N/A" && NF { print; exit }')

  printf '%s\n' "$rate" | awk -F/ '
    NF == 2 && $2 != 0 { printf "%.6f\n", $1 / $2; next }
    NF == 1 && $1 ~ /^[0-9]+([.][0-9]+)?$/ { printf "%.6f\n", $1 }
  '
}

nominal_fps() {
  awk -v fps="$1" 'BEGIN {
    if (fps == "" || fps <= 0) exit 1
    # Convert common fractional rates such as 29.97 and 59.94 to 30 and 60.
    printf "%d\n", int(fps + 0.5)
  }'
}

parse_iso6709() {
  printf '%s' "$1" | perl -ne 'chomp; if (/^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)?\/?$/) { print "$1\t$2\t", (defined $3 ? $3 : ""), "\n" } else { print "\t\t\n" }'
}

append_timeline_row() {
  local sequence="$1" source="$2" hash="$3" normalized="$4" start_seconds="$5" duration_seconds="$6"
  local end_seconds source_duration creation_time file_modified location latitude longitude altitude width height avg_frame_rate video_codec audio_codec has_audio rotation file_size source_name
  end_seconds=$(awk -v a="$start_seconds" -v b="$duration_seconds" 'BEGIN{printf "%.6f",a+b}')
  source_name=$(basename "$source")
  source_duration=$(probe_value "$source" 'format=duration')
  creation_time=$(probe_tag "$source" 'creation_time'); [ -n "$creation_time" ] || creation_time=$(probe_tag "$source" 'date')
  file_modified=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$source" 2>/dev/null || true)
  location=$(probe_tag "$source" 'com.apple.quicktime.location.ISO6709'); [ -n "$location" ] || location=$(probe_tag "$source" 'location'); [ -n "$location" ] || location=$(probe_tag "$source" 'location-eng')
  IFS=$'\t' read -r latitude longitude altitude <<EOLOC
$(parse_iso6709 "$location")
EOLOC
  width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n1)
  height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n1)
  avg_frame_rate=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n1)
  video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n1)
  audio_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n1)
  [ -n "$audio_codec" ] && has_audio=1 || has_audio=0
  rotation=$(ffprobe -v error -select_streams v:0 -show_entries stream_tags=rotate:stream_side_data=rotation -of default=noprint_wrappers=1:nokey=1 "$source" </dev/null 2>/dev/null | head -n1)
  file_size=$(stat -f '%z' "$source" 2>/dev/null || true)
  {
    field_number=0
    for value in "$sequence" "$source" "$source_name" "$hash" "$start_seconds" "$end_seconds" "$duration_seconds" "$source_duration" "$creation_time" "$file_modified" "$location" "$latitude" "$longitude" "$altitude" "$width" "$height" "$avg_frame_rate" "$video_codec" "$audio_codec" "$has_audio" "$rotation" "$file_size" "$FPS" "$normalized"; do
      [ "$field_number" -eq 0 ] || printf ','
      csv_quote "$value"
      field_number=$((field_number + 1))
    done
    printf '\n'
  } >> "$TIMELINE_TMP"
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

# Build a natural-sorted, NUL-delimited source list. Junk is rejected here,
# before hashing or probing, so Finder metadata and stale caches never enter
# the expensive part of the pipeline.
RAW_LIST="$WORK_DIR/source_files.nul"
RAW_LIST="$RAW_LIST" OUTPUT="$OUTPUT" WORK_DIR="$WORK_DIR" START_DIR="$START_DIR" RECURSIVE="$RECURSIVE" perl -e '
  use strict;
  use warnings;
  use File::Find;
  use File::Spec;

  my $list = $ENV{"RAW_LIST"};
  my $output = File::Spec->rel2abs($ENV{"OUTPUT"});
  my $work_dir = File::Spec->rel2abs($ENV{"WORK_DIR"});
  my $start_dir = File::Spec->rel2abs($ENV{"START_DIR"});
  my $recursive = $ENV{"RECURSIVE"} eq "1";
  my @files;

  my %junk_dirs = map { lc($_) => 1 } (
    q{__MACOSX},
    q{@eaDir},
    q{lost+found},
    q{System Volume Information},
    q{$RECYCLE.BIN},
    q{Temporary Items},
    q{Network Trash Folder}
  );

  sub path_basename {
    my ($path) = @_;
    my (undef, undef, $name) = File::Spec->splitpath($path);
    return $name;
  }

  sub is_junk_directory {
    my ($path) = @_;
    return 0 if lc($path) eq lc($start_dir);
    return 1 if lc($path) eq lc($work_dir);

    my $name = path_basename($path);
    return 1 if $name =~ /^\./;
    return 1 if $name =~ /^\.merge_video_work/i;
    return 1 if $junk_dirs{lc($name)};

    # Do not descend into macOS/application library packages. Their internal
    # media is managed by the owning app and should not be merged accidentally.
    return 1 if $name =~ /\.(?:photoslibrary|photolibrary|imovielibrary|fcpbundle|fcpevent|fcpproject|app|bundle|framework|logicx|band)$/i;

    return 0;
  }

  sub is_junk_file {
    my ($path) = @_;
    my $name = path_basename($path);

    # Ignore symlinks even when they point to a regular video file.
    return 1 if -l $path;

    # Finder/resource-fork files and all other hidden files. This catches
    # .DS_Store, ._IMG_0001.MOV, Icon\r, and similar metadata.
    return 1 if $name =~ /^\./;
    return 1 if $name =~ /^~\$/;
    return 1 if $name =~ /^(?:Thumbs\.db|desktop\.ini)$/i;

    # Interrupted downloads, editor leftovers, and temporary video copies.
    return 1 if $name =~ /(?:\.tmp|\.temp|\.part|\.partial|\.download|\.crdownload|\.icloud)\.(?:mp4|mov|mkv|webm|mts|m2ts|ts)$/i;
    return 1 if $name =~ /~$/;

    return 0;
  }

  sub is_supported_source {
    my ($path) = @_;
    return 0 unless -f $path;
    return 0 if is_junk_file($path);
    return 0 if lc(File::Spec->rel2abs($path)) eq lc($output);
    return 0 unless $path =~ /\.(?:mp4|mov|mkv|webm|mts|m2ts|ts)$/i;
    return 1;
  }

  if ($recursive) {
    find({
      no_chdir => 1,
      wanted => sub {
        my $path = File::Spec->rel2abs($File::Find::name);

        if (-d $path && is_junk_directory($path)) {
          $File::Find::prune = 1;
          return;
        }

        return unless is_supported_source($path);
        push @files, File::Spec->abs2rel($path, $start_dir);
      }
    }, $start_dir);
  } else {
    opendir(my $dh, $start_dir) or die "Cannot open current directory: $!\n";
    @files = grep {
      my $path = File::Spec->catfile($start_dir, $_);
      is_supported_source($path)
    } readdir($dh);
    closedir($dh);
  }

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
    print {$out} File::Spec->catfile($start_dir, $file), "\0";
  }
  close($out);
'

[ -s "$RAW_LIST" ] || fail "no supported videos found in the current folder"

TOTAL=$(perl -0ne '$n++; END { print $n+0 }' "$RAW_LIST")
echo "Found $TOTAL candidate video files."
echo "Hashing source files to guarantee exact deduplication..."
echo

HASH_INDEX="$WORK_DIR/hash_index.tsv"
: > "$HASH_INDEX"

unique=0
duplicates=0
index=0

while IFS= read -r -d '' source; do
  index=$((index + 1))
  base=$(basename "$source")
  printf '[hash %d/%d] %s\n' "$index" "$TOTAL" "$base"

  hash=$(shasum -a 256 "$source" | awk '{print $1}')
  [ -n "$hash" ] || {
    printf '%s\t%s\n' "$source" "hash failed" >> "$SKIPPED_LIST"
    continue
  }

  original=$(awk -F '\t' -v h="$hash" '$1 == h { sub($1 FS, ""); print; exit }' "$HASH_INDEX")

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

# Inspect source frame rates before normalization. If any source has a higher
# nominal FPS than the configured export FPS, offer to preserve that rate.
MAX_SOURCE_FPS="0"
MAX_SOURCE_FPS_EXACT="0.000000"
MAX_SOURCE_FPS_FILE=""
FPS_PROBED=0
FPS_UNKNOWN=0

printf '\nChecking source frame rates...\n'
while IFS=$'\t' read -r hash source; do
  source_fps=$(probe_source_fps "$source")
  if [ -z "$source_fps" ]; then
    FPS_UNKNOWN=$((FPS_UNKNOWN + 1))
    continue
  fi

  FPS_PROBED=$((FPS_PROBED + 1))
  source_nominal=$(nominal_fps "$source_fps" 2>/dev/null || echo 0)

  # Never offer an export frame rate above 60 fps. High-speed/slow-motion
  # sources such as 120, 240, or 600 fps are treated as 60 fps here.
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
    echo "A higher-frame-rate source was found: $(basename "$MAX_SOURCE_FPS_FILE")"
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
          echo "Export FPS remains ${FPS} fps. Higher-FPS sources will be converted down."
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
echo "Cache identity: SHA-256 source hash + output resolution + export FPS"
echo

success=0
skipped=0
index=0

# Phase 1: normalize every unique source and record its capture-time sort key.
# Final ordering also classifies clips by duration: normal videos first, then
# likely Live Photo motion clips at or below LIKELY_LIVE_PHOTO_MAX_SECONDS.
# No concat order is chosen until all successful clips are known.
while IFS=$'\t' read -r hash source; do
  index=$((index + 1))
  base=$(basename "$source")

  timestamp_info=$(extract_capture_timestamp "$source" 2>/dev/null || true)
  if [ -n "$timestamp_info" ]; then
    IFS=$'\t' read -r capture_epoch capture_label timestamp_source <<EOTS
$timestamp_info
EOTS
    timestamp_group="0"
    normalized_name="${capture_label}__${hash}_${WIDTH}x${HEIGHT}_${FPS}fps.mp4"
  else
    capture_epoch=$(stat -f '%m' "$source" 2>/dev/null || echo 0)
    capture_label="UNKNOWN"
    timestamp_source="unclear"
    timestamp_group="1"
    normalized_name="UNKNOWN__${hash}_${WIDTH}x${HEIGHT}_${FPS}fps.mp4"
  fi

  normalized="$NORMALIZED_DIR/$normalized_name"
  log="$LOG_DIR/${hash}.log"

  printf '[%d/%d] %s\n' "$index" "$unique" "$base"
  if [ "$timestamp_group" = "0" ]; then
    echo "  Capture time: ${capture_label} (${timestamp_source})"
  else
    echo "  Capture time unclear; this clip will be placed at the end."
  fi

  if [ -s "$normalized" ]; then
    echo "  Hash-matched normalized file exists; safely reusing."
  else
    # Remove obsolete same-hash cache names from earlier versions/settings,
    # but never touch another source hash.
    find "$NORMALIZED_DIR" -maxdepth 1 -type f -name "*${hash}_${WIDTH}x${HEIGHT}_${FPS}fps.mp4" ! -path "$normalized" -delete 2>/dev/null || true
    rm -f "$normalized"

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

  printf '%s\t%s\t%s\t%sx%s\t%sfps\t%s\t%s\n' "$hash" "$source" "$normalized" "$WIDTH" "$HEIGHT" "$FPS" "$capture_label" "$timestamp_source" >> "$MANIFEST"

  likely_live_photo=$(awk -v d="$normalized_duration" -v limit="$LIKELY_LIVE_PHOTO_MAX_SECONDS" 'BEGIN { print (d <= limit) ? 1 : 0 }')

  # Primary priority: normal videos first, likely Live Photo motion clips later.
  # Secondary priority inside each class: reliable timestamps first, unclear last.
  #   group 0 = normal video, reliable timestamp
  #   group 1 = normal video, unclear timestamp
  #   group 2 = likely Live Photo clip, reliable timestamp
  #   group 3 = likely Live Photo clip, unclear timestamp
  if [ "$likely_live_photo" -eq 1 ]; then
    sort_group=$((2 + timestamp_group))
    echo "  Short clip (${normalized_duration}s); likely Live Photo motion, placed after normal videos."
  else
    sort_group="$timestamp_group"
  fi

  # Epoch/mtime, source path and hash provide deterministic tie-breaking.
  printf '%s\t%020d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$sort_group" "$capture_epoch" "$source" "$hash" "$normalized" "$normalized_duration" "$capture_label" "$timestamp_source" >> "$ORDER_LIST"
  success=$((success + 1))
done < "$SOURCE_LIST"

# Phase 2: sort chronologically, then build concat and timeline in that order.
LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3 -k4,4 "$ORDER_LIST" > "$SORTED_ORDER_LIST" || fail "could not sort normalized clips"

TIMELINE_CURSOR="0.000000"
sequence=0
while IFS=$'\t' read -r sort_group capture_epoch source hash normalized normalized_duration capture_label timestamp_source; do
  sequence=$((sequence + 1))
  abs_dir=$(cd "$(dirname "$normalized")" && pwd -P)
  abs_path="$abs_dir/$(basename "$normalized")"
  escaped=$(escape_concat_path "$abs_path")

  if grep -Fqx "file '$escaped'" "$CONCAT_LIST"; then
    fail "duplicate normalized path detected while building chronological concat list"
  fi

  printf "file '%s'\n" "$escaped" >> "$CONCAT_LIST"
  append_timeline_row "$sequence" "$source" "$hash" "$normalized" "$TIMELINE_CURSOR" "$normalized_duration"
done < "$SORTED_ORDER_LIST"

echo
[ "$success" -gt 0 ] || fail "all clips failed; inspect $LOG_DIR and $SKIPPED_LIST"

# Final hard assertion: concat list must contain no duplicate lines.
if [ "$(sort "$CONCAT_LIST" | uniq -d | wc -l | tr -d ' ')" -ne 0 ]; then
  fail "duplicate entries detected in concat list; refusing to create output"
fi

normal_reliable_count=$(awk -F '\t' '$1 == 0 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
normal_unclear_count=$(awk -F '\t' '$1 == 1 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
live_reliable_count=$(awk -F '\t' '$1 == 2 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
live_unclear_count=$(awk -F '\t' '$1 == 3 { n++ } END { print n+0 }' "$SORTED_ORDER_LIST")
likely_live_count=$((live_reliable_count + live_unclear_count))
unclear_count=$((normal_unclear_count + live_unclear_count))

echo "Normalized successfully: $success"
echo "Normal videos with reliable timestamps: $normal_reliable_count"
echo "Normal videos with unclear timestamps: $normal_unclear_count"
echo "Likely Live Photo clips (<= ${LIKELY_LIVE_PHOTO_MAX_SECONDS}s) moved after normal videos: $likely_live_count"
echo "Likely Live Photo clips with unclear timestamps: $live_unclear_count"
echo "Total unclear timestamps placed last within their video class: $unclear_count"
echo "Export frame rate: ${FPS} fps"
echo "Skipped: $skipped"
echo "Exact duplicates excluded: $duplicates"
echo "Joining normalized clips without re-encoding..."

FINAL_LOG="$WORK_DIR/final_concat.log"
if ffmpeg -nostdin -hide_banner -loglevel warning \
    -f concat -safe 0 -i "$CONCAT_LIST" \
    -c copy -movflags +faststart -y "$OUTPUT" 2>"$FINAL_LOG"; then
  echo
  echo "Done: $OUTPUT"
  echo "Duplicate report: $DUPLICATE_LIST"
  echo "Skipped-file report: $SKIPPED_LIST"
  cp "$TIMELINE_TMP" "$TIMELINE_OUTPUT" || fail "could not write timeline CSV"
  echo "Manifest: $MANIFEST"
  echo "Timeline CSV: $TIMELINE_OUTPUT"
  echo "Hash-bound normalized cache kept at: $NORMALIZED_DIR"
else
  rm -f "$OUTPUT"
  fail "final concatenation failed. Check: $FINAL_LOG"
fi
