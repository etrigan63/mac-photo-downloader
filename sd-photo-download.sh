#!/bin/bash
# sd-photo-download.sh
#
# Download photos/videos from a mounted SD card into a photo library.
#
#   * Locates the card automatically (config SD_CARD=auto or --card PATH)
#   * Reads EXIF date + camera model with exiftool
#   * Copies originals to BACKUP_DIR (original names) and renamed files to
#     TARGET_DIR, both under date subfolders like 2026/2026-08-29
#   * Renames to:  <camera-model>-<YYYYMMDD>-<image number>.<ext>
#   * Image numbers are sequential, tracked per camera model in a state dir
#
# Usage:  sd-photo-download.sh [--config FILE] [--card PATH] [--dry-run]
#   Folders dropped on an Automator action are read as --card arguments too.
#
# Config search order:
#   1. --config FILE
#   2. $SD_CARD_DOWNLOADER_CONFIG
#   3. ./config (next to this script)
#   4. ~/Library/Application Support/SD Photo Downloader/config

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"


# ---------------------------------------------------------------------------
# Defaults (overridden by the config file)
# ---------------------------------------------------------------------------
CONFIG_FILE="${SD_CARD_DOWNLOADER_CONFIG:-}"
[ -z "$CONFIG_FILE" ] && [ -f "$SCRIPT_DIR/config" ] && CONFIG_FILE="$SCRIPT_DIR/config"
[ -z "$CONFIG_FILE" ] && CONFIG_FILE="$HOME/Library/Application Support/SD Photo Downloader/config"

TARGET_DIR=""
BACKUP_DIR=""
EXIFTOOL=""
STATE_DIR=""
FOLDER_PATTERN="%Y/%Y-%m-%d"
COUNTER_DIGITS=4
COUNTER_START=1
COUNTER_PER_MODEL=yes
PHOTO_EXTS="jpg jpeg jpe tif tiff nef cr2 cr3 arw dng orf rw2 raf pef srf sr2 rwl raw heic heif png gif bmp"
VIDEO_EXTS="mp4 mov m4v avi mts m2ts 3gp mod"
SD_CARD="auto"
LOG_FILE=""

DRY_RUN=no
ARG_CARD=""
ARG_CARDS=()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; [ -z "$LOG_FILE" ] || printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null; }

die() { log "ERROR: $*" >&2; exit 1; }

expand_home() { case "$1" in "~/"*) printf '%s/%s' "$HOME" "${1#\~/}";; *) printf '%s' "$1";; esac; }

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Options:"
  echo "  -c, --config FILE   use FILE instead of the default config"
  echo "  --card PATH         import from PATH (repeatable, or Automator folder input)"
  echo "  --dry-run           preview actions (renames/copies) without writing files"
  echo "  -h, --help          show this help"
}

# Sanitize a camera model into a filename-safe token, e.g. "Canon EOS R5" -> "Canon-EOS-R5"
sanitize_token() {
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"           # trim leading whitespace
  s="${s%"${s##*[![:space:]]}"}"           # trim trailing whitespace
  s="$(printf '%s' "$s" | tr -c '[:alnum:]' '-')"
  while [[ "$s" == *"--"* ]]; do s="${s//--/-}"; done
  s="${s#-}"; s="${s%-}"
  [ -z "$s" ] && s="UNKNOWN"
  printf '%s' "$s"
}

# Format FOLDER_PATTERN for a date. Accepts both exiftool style (%Y) and
# brace style ({YYYY}) tokens.
fmt_subdir() {
  local pattern="$1" year="$2" month="$3" day="$4" hh="$5" min="$6" ss="$7"
  local y2="${year:2:2}" head rest group seg s

  # Expand brace groups like {YYYY-MM-DD} directly to date parts.
  while [[ "$pattern" == *"{"* ]]; do
    head="${pattern%%\{*}"
    rest="${pattern#*\{}"
    [ "$rest" != "$pattern" ] || break
    group="${rest%%\}*}"
    pattern="${rest#*\}}"
    group="${group//YYYY/$year}"
    group="${group//YY/$y2}"
    group="${group//MM/$month}"
    group="${group//DD/$day}"
    group="${group//HH/$hh}"
    group="${group//MI/$min}"
    group="${group//SS/$ss}"
    pattern="${head}${group}${pattern}"
  done

  # Apply exiftool-style %-tokens per path segment.
  local IFS='/'
  for seg in $pattern; do
    s="${seg//%Y/$year}"
    s="${s//%y/$y2}"
    s="${s//%m/$month}"
    s="${s//%d/$day}"
    s="${s//%H/$hh}"
    s="${s//%M/$min}"
    s="${s//%S/$ss}"
    [ -z "$s" ] && continue
    SUBDIR="${SUBDIR}${SUBDIR:+/}$s"
  done
}


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
load_config() {
  [ -f "$CONFIG_FILE" ] || die "config not found: $CONFIG_FILE"
  local line key val
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" == *"="* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    case "$key" in
      TARGET_DIR)         TARGET_DIR="$(expand_home "$val")";;
      BACKUP_DIR)         BACKUP_DIR="$(expand_home "$val")";;
      EXIFTOOL)           EXIFTOOL="$(expand_home "$val")";;
      STATE_DIR)          STATE_DIR="$(expand_home "$val")";;
      FOLDER_PATTERN)     FOLDER_PATTERN="$val";;
      COUNTER_DIGITS)     COUNTER_DIGITS=$val;;
      COUNTER_START)      COUNTER_START=$val;;
      COUNTER_PER_MODEL)  COUNTER_PER_MODEL="$val";;
      PHOTO_EXTS)         PHOTO_EXTS="$val";;
      VIDEO_EXTS)         VIDEO_EXTS="$val";;
      SD_CARD)            SD_CARD="$val";;
      LOG_FILE)           LOG_FILE="$(expand_home "$val")";;
    esac
  done <"$CONFIG_FILE"

  [ -n "$TARGET_DIR" ] || die "TARGET_DIR is not set in config: $CONFIG_FILE"
  [ -n "$EXIFTOOL" ] || {
    if command -v exiftool >/dev/null 2>&1; then EXIFTOOL="$(command -v exiftool)";
    elif [ -x /opt/homebrew/bin/exiftool ]; then EXIFTOOL=/opt/homebrew/bin/exiftool;
    elif [ -x /usr/local/bin/exiftool ]; then EXIFTOOL=/usr/local/bin/exiftool;
    else die "exiftool not found. Install it: brew install exiftool"; fi
  }
  [ -x "$EXIFTOOL" ] || die "exiftool not executable: $EXIFTOOL"
  [ -n "$STATE_DIR" ] || STATE_DIR="$HOME/Library/Application Support/SD Photo Downloader"
  [ -n "$LOG_FILE" ] || LOG_FILE="$STATE_DIR/run.log"
  [ "$COUNTER_DIGITS" -ge 1 ] 2>/dev/null || die "COUNTER_DIGITS must be >= 1"
  [ "$COUNTER_START" -ge 0 ] 2>/dev/null || die "COUNTER_START must be >= 0"
}


# ---------------------------------------------------------------------------
# Locate the SD card
# ---------------------------------------------------------------------------
detect_card() {
  local vol name count v found

  [ -n "$ARG_CARD" ] && { SD_PATH="$ARG_CARD"; return 0; }

  if [ "$SD_CARD" != "auto" ]; then
    SD_PATH="$(expand_home "$SD_CARD")"
    [ -d "$SD_PATH" ] || die "configured SD_CARD is not a directory: $SD_PATH"
    return 0
  fi

  count=0; found=""
  for v in /Volumes/*; do
    [ -d "$v" ] || continue
    name="$(basename -- "$v")"
    [ "$name" = "Macintosh HD" ] && continue
    [ -L "$v" ] && continue
    if find "$v" -maxdepth 2 -type d -iname DCIM -print -quit 2>/dev/null | grep -q .; then
      count=$((count + 1)); found="$v"
    fi
  done

  [ "$count" -eq 0 ] && die "no SD card found: no volume under /Volumes has a DCIM folder"
  [ "$count" -gt 1 ] && die "multiple SD cards found; pass one explicitly with --card (or drop it on the Automator action)"
  SD_PATH="$found"
}


# ---------------------------------------------------------------------------
# EXIF helpers
# ---------------------------------------------------------------------------
exif_field() { # tag file  -- prints first line, whitespace-trimmed
  "$EXIFTOOL" -s -s -s -"$1" "$2" 2>/dev/null | head -n 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

exif_datetime() { # file -> outputs "YYYY:MM:DD HH:MM:SS" or empty
  local d
  d="$(exif_field DateTimeOriginal "$1")"
  [ -n "$d" ] || d="$(exif_field CreateDate "$1")"
  [ -n "$d" ] || d="$(exif_field ModifyDate "$1")"
  case "$d" in
    [0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) printf '%s' "${d:0:19}";;
    *) return 1;;
  esac
}

mtime_datetime() { # file -> "YYYY:MM:DD HH:MM:SS" from fs metadata
  stat -f '%Sm' -t '%Y:%m:%d %H:%M:%S' "$1"
}


# ---------------------------------------------------------------------------
# Image number (counter) bookkeeping
# ---------------------------------------------------------------------------
num_glob() { printf '%.0s[0-9]' $(seq 1 "$COUNTER_DIGITS"); }

scan_max_number() { # full-model-token -> highest existing image number in TARGET
  local model="$1" pat numglob best=0 line
  numglob="$(num_glob)"
  if [ "$COUNTER_PER_MODEL" = "yes" ]; then
    pat="$model-????????-$numglob.*"
  else
    pat="*-????????-$numglob.*"
  fi
  while IFS= read -r line; do
    num="$(printf '%s\n' "$line" | sed 's/.*-\([0-9][0-9]*\)\.[^.]*$/\1/')"
    [ -n "$num" ] && [ "$num" -gt "$best" ] 2>/dev/null && best=$num
  done < <(find "$TARGET_DIR" -type f -name "$pat" 2>/dev/null)
  printf '%s' "$best"
}

# next_number <model> <counter-key>  -> value to use for the next file
next_number() {
  local model="$1" key="$2" f n maxn
  f="$WORK_STATE/counters/$key.txt"
  if [ -f "$f" ]; then
    n="$(cat "$f")"; n="${n//[^0-9]/}"
    if [ -n "$n" ]; then printf '%s' "$n"; return; fi
  fi
  maxn="$(scan_max_number "$model")"
  [ -z "$maxn" ] && maxn=$((COUNTER_START - 1))
  printf '%s' "$((maxn + 1))"
}

# bump_counter <counter-key> <new-next>
bump_counter() {
  mkdir -p "$WORK_STATE/counters"
  printf '%s\n' "$2" >"$WORK_STATE/counters/$1.txt"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local f ext h exif_dt year month day hh min ss model
  local token key num numpad name target backup copy_count skip_count notify
  copy_count=0; skip_count=0

  cd "$HOME" || true   # cd out of /Volumes so the card can be unmounted

  mkdir -p "$STATE_DIR" "$TARGET_DIR" 2>/dev/null
  mkdir -p "${LOG_FILE%/*}" 2>/dev/null
  [ -n "$BACKUP_DIR" ] && mkdir -p "$BACKUP_DIR"

  if [ "$DRY_RUN" = yes ]; then
    WORK_STATE="$(mktemp -d -t sd-downloader)"
    mkdir -p "$WORK_STATE/counters"
    cp -f "$STATE_DIR"/counters/* "$WORK_STATE/counters"/ 2>/dev/null
    cp -f "$STATE_DIR/imported.txt" "$WORK_STATE/imported.txt" 2>/dev/null
    WORK_LEDGER="$WORK_STATE/imported.txt"
  else
    WORK_STATE="$STATE_DIR"
    WORK_LEDGER="$STATE_DIR/imported.txt"
  fi

  detect_card

  # Build find expression from extension lists.
  local name_args=() e
  for e in $PHOTO_EXTS $VIDEO_EXTS; do
    if [ "${#name_args[@]}" -eq 0 ]; then name_args+=(-iname "*.$e"); else name_args+=(-o -iname "*.$e"); fi
  done
  [ "${#name_args[@]}" -gt 0 ] || die "no file extensions configured"

  log "SD card:   $SD_PATH"
  log "Target:    $TARGET_DIR"
  [ -n "$BACKUP_DIR" ] && log "Backup:    $BACKUP_DIR"
  log "Scanning for photos/videos..."

  while IFS= read -r f; do
    ext="${f##*.}"; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

    h="$(md5 -q "$f" 2>/dev/null)"
    [ -z "$h" ] && h="$(shasum "$f" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$h" ] && grep -Fxq "$h" "$WORK_LEDGER" 2>/dev/null; then
      skip_count=$((skip_count + 1))
      log "skip     (already imported): $(basename -- "$f")"
      continue
    fi

    exif_dt="$(exif_datetime "$f" || mtime_datetime "$f")"

    year="${exif_dt:0:4}"; month="${exif_dt:5:2}"; day="${exif_dt:8:2}"
    hh="${exif_dt:11:2}"; min="${exif_dt:14:2}"; ss="${exif_dt:17:2}"

    SUBDIR=""; fmt_subdir "$FOLDER_PATTERN" "$year" "$month" "$day" "$hh" "$min" "$ss"

    model="$(exif_field Model "$f")"
    [ -n "$model" ] || model="$(exif_field Make "$f")"
    token="$(sanitize_token "$model")"

    if [ "$COUNTER_PER_MODEL" = "yes" ]; then key="$token"; else key="ALL"; fi
    num="$(next_number "$token" "$key")"
    numpad="$(printf "%0*d" "$COUNTER_DIGITS" "$num")"
    name="${token}-${year}${month}${day}-${numpad}.${ext}"

    target="$TARGET_DIR/$SUBDIR/$name"
    backup="$BACKUP_DIR/$SUBDIR/$name"

    if [ -e "$target" ]; then
      skip_count=$((skip_count + 1))
      log "skip     (already imported): $name"
      continue
    fi

    log "import   $name"
    log "         from: $f"
    [ -n "$BACKUP_DIR" ] && log "         backup to: $BACKUP_DIR/$SUBDIR"

    if [ "$DRY_RUN" != yes ]; then
      mkdir -p "$(dirname -- "$target")"
      cp -p "$f" "$target"         || log "WARN: copy to target failed for $name"
      if [ -n "$BACKUP_DIR" ]; then
        mkdir -p "$(dirname -- "$backup")"
        [ -e "$backup" ] || cp -p "$f" "$backup" || log "WARN: backup copy failed for $name"
      fi
      bump_counter "$key" "$((num + 1))"
      [ -n "$h" ] && printf '%s\n' "$h" >>"$WORK_LEDGER"
    fi
    copy_count=$((copy_count + 1))
  done < <(find "$SD_PATH" -type f "${name_args[@]}" 2>/dev/null | sort)

  if [ "$DRY_RUN" = yes ]; then rm -rf "$WORK_STATE"; fi

  log "Done: $copy_count imported, $skip_count already present."
  if [ "$DRY_RUN" = yes ]; then
    log "DRY RUN - no files were written."
  else
    notify="Downloaded $copy_count photos" && osascript -e "display notification \"$notify\" with title \"SD Photo Downloader\"" 2>/dev/null
  fi
}


# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) [ $# -ge 2 ] || die "--config needs a file argument"; CONFIG_FILE="$2"; shift 2;;
    --card)      [ $# -ge 2 ] || die "--card needs a path argument"; ARG_CARD="$2"; shift 2;;
    --dry-run)   DRY_RUN=yes; shift;;
    -h|--help)   usage; exit 0;;
    -*)          die "unknown option: $1 (see --help)";;
    *)           ARG_CARD="$1"; shift;;   # Automator passes dropped folders here
  esac
done

# Belt and suspenders: if Automator delivered folders on stdin, use the first.
if [ -z "$ARG_CARD" ] && [ ! -t 0 ]; then
  while IFS= read -r line; do
    if [ -n "$line" ] && [ -d "$line" ]; then ARG_CARD="$line"; break; fi
  done
fi

load_config
main