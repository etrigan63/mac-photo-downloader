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
[ -z "$CONFIG_FILE" ] && [ -f "$HOME/.sd-photo-downloader/config" ] && CONFIG_FILE="$HOME/.sd-photo-downloader/config"
[ -z "$CONFIG_FILE" ] && CONFIG_FILE="$HOME/Library/Application Support/SD Photo Downloader/config"

TARGET_DIR=""
BACKUP_DIR=""
EXIFTOOL=""
STATE_DIR=""
FOLDER_PATTERN="%Y/%Y-%m-%d"
COUNTER_DIGITS=4
COUNTER_START=1
COUNTER_PER_MODEL=yes
NUMBER_SOURCE="exif"
PHOTO_EXTS="jpg jpeg jpe tif tiff nef cr2 cr3 arw dng orf rw2 raf pef srf sr2 rwl raw heic heif hif png gif bmp"
VIDEO_EXTS="mp4 mov m4v avi mts m2ts 3gp mod"
SD_CARD="auto"
LOG_FILE=""
EJECT_CARD=yes
NOTIFY=yes
NOTIFY_PROGRESS=25
PROGRESS_BAR=yes
PROGRESS_FILE=""
EXIF_BATCH=yes

DRY_RUN=no
NO_EJECT=no
CARD_PATHS=()
ARG_CARDS=()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; [ -z "$LOG_FILE" ] || printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null; }

# Log-file only, no terminal output (used while the progress bar owns the line).
logf() { [ -z "$LOG_FILE" ] || printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null; }

# Status banner via Notification Center (used when running from Stream Deck
# or any context with no visible terminal). Enabled by NOTIFY=yes.
notify() {
  [ "$NOTIFY" = "yes" ] || return 0
  [ "$DRY_RUN" = yes ] && return 0
  local msg="$*"
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  osascript -e "display notification \"$msg\" with title \"SD Photo Downloader\"" 2>/dev/null
}

die() { log "ERROR: $*" >&2; notify "Failed: $*"; progress "error" "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Single instance, with takeover
# ---------------------------------------------------------------------------
# The GUI keeps its window open for a moment after a run so the result stays on
# screen, and macOS treats a second launch of a running app as "activate it".
# Without this, a Stream Deck press in that window would do nothing at all.
#
# So a new instance does not kill the running one: it asks it to stop at a safe
# point (between files, or while it is only waiting to close), waits for it to
# exit, then takes over. If the running instance is genuinely mid-import and
# does not stop, the new one gives up instead of writing the same files twice.

LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-15}"
RUN_LOCK=""
TAKEOVER_REQ=""

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Claims the lock, or leaves the blocking pid in CLAIM_BUSY_PID when another
# live instance refused to hand over. Nothing is printed: the caller runs this
# without command substitution, so log output stays on stdout.
CLAIM_BUSY_PID=""

claim_run_lock() {
  local owner waited
  RUN_LOCK="$STATE_DIR/run.lock"
  TAKEOVER_REQ="$STATE_DIR/run.lock.takeover"
  CLAIM_BUSY_PID=""

  if [ -f "$RUN_LOCK" ]; then
    owner="$(tr -d '[:space:]' <"$RUN_LOCK" 2>/dev/null)"
    if pid_alive "$owner"; then
      printf '%s\n' "$$" >"$TAKEOVER_REQ"
      log "Another instance is running (pid $owner); asking it to stop."
      waited=0
      while pid_alive "$owner" && [ "$waited" -lt "$((LOCK_WAIT_SECONDS * 5))" ]; do
        sleep 0.2
        waited=$((waited + 1))
      done
      if pid_alive "$owner"; then
        rm -f "$TAKEOVER_REQ"
        CLAIM_BUSY_PID="$owner"
        return 0
      fi
      log "Took over from a finished instance (pid $owner)."
      rm -f "$RUN_LOCK"
    else
      rm -f "$RUN_LOCK"
    fi
  fi
  printf '%s\n' "$$" >"$RUN_LOCK"
}

release_run_lock() { [ -n "$RUN_LOCK" ] && rm -f "$RUN_LOCK"; return 0; }

# True when a newer live instance asked us to stop. Only call this at safe
# points: between files, or while idling before exit.
takeover_requested() {
  local req
  [ -n "$TAKEOVER_REQ" ] && [ -f "$TAKEOVER_REQ" ] || return 1
  req="$(tr -d '[:space:]' <"$TAKEOVER_REQ" 2>/dev/null)"
  [ -n "$req" ] && [ "$req" != "$$" ] || return 1
  if pid_alive "$req"; then
    rm -f "$TAKEOVER_REQ"
    return 0
  fi
  rm -f "$TAKEOVER_REQ"
  return 1
}

# ---------------------------------------------------------------------------
# Progress reporting: in-place terminal bar (when attached to a TTY), a
# machine-readable progress file, and periodic Notification Center updates.
# ---------------------------------------------------------------------------

# Wipe the bar line so ordinary output can continue underneath it.
bar_clear() {
  [ "$PROGRESS_BAR" = yes ] && [ -t 1 ] || return 0
  printf '\r%*s\r' 100 ""
}

# Per-file progress. $1 done, $2 total, $3 current file, $4 status.
bar_line() {
  local done="$1" total="$2" current="$3" status="${4:-}"
  local pct=0 filled=0 width=30
  if [ "${total:-0}" -gt 0 ]; then pct=$((done * 100 / total)); fi
  filled=$((pct * width / 100))
  local bar="" i
  for ((i = 0; i < filled; i++)); do bar="$bar#"; done
  for ((i = filled; i < width; i++)); do bar="$bar-"; done
  printf '[%s] %3d%% %s/%s %s' "$bar" "$pct" "$done" "${total:-?}" "$current"
  [ -n "$status" ] && printf ' (%s)' "$status"
}

bar_draw() {
  [ "$PROGRESS_BAR" = yes ] && [ -t 1 ] || return 0
  printf '\r%s' "$(bar_line "$1" "$2" "$3" "$4")"
}

# Progress file: a watcher (or Shortcut) can poll this for current state.
progress() {
  local status="$1" msg="$2"
  [ -z "$PROGRESS_FILE" ] && return 0
  printf 'status=%s pct=%s done=%s total=%s message=%s\n' \
    "$status" "${TOTAL_PCT:-0}" "${DONE_COUNT:-0}" "${TOTAL:-0}" "$msg" \
    >"$PROGRESS_FILE" 2>/dev/null
}

# Advance the shared counters after one file, then repaint every surface:
# terminal bar, progress file, and (every NOTIFY_PROGRESS %) a banner update.
progress_update() {
  local current="$1" status="${2:-}"
  DONE_COUNT=$((DONE_COUNT + 1))
  if [ "${TOTAL:-0}" -gt 0 ]; then TOTAL_PCT=$((DONE_COUNT * 100 / TOTAL)); else TOTAL_PCT=0; fi
  bar_draw "$DONE_COUNT" "$TOTAL" "$current" "$status"
  progress "$status" "$current"
  if [ "$NOTIFY_PROGRESS" -gt 0 ] && [ "$TOTAL_PCT" -ge $((LAST_NOTIFY_PCT + NOTIFY_PROGRESS)) ]; then
    LAST_NOTIFY_PCT=$((TOTAL_PCT / NOTIFY_PROGRESS * NOTIFY_PROGRESS))
    notify "Importing: ${TOTAL_PCT}% ($DONE_COUNT/$TOTAL)"
  fi
  return 0
}

expand_home() { case "$1" in "~/"*) printf '%s/%s' "$HOME" "${1#\~/}";; *) printf '%s' "$1";; esac; }

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  echo
  echo "Options:"
  echo "  -c, --config FILE   use FILE instead of the default config"
  echo "  --card PATH         import from PATH (repeatable, or Automator folder input)"
  echo "  --dry-run           preview actions (renames/copies) without writing files"
  echo "  --no-eject          do not eject the card when done"
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
  while IFS= read -r line || [ -n "$line" ]; do
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
      NUMBER_SOURCE)      case "$val" in exif|counter) NUMBER_SOURCE="$val";; esac;;
      PHOTO_EXTS)         PHOTO_EXTS="$val";;
      VIDEO_EXTS)         VIDEO_EXTS="$val";;
      SD_CARD)            SD_CARD="$val";;
      EJECT_CARD)         case "$val" in yes|YES|true|1) EJECT_CARD=yes;; *) EJECT_CARD=no;; esac;;
      LOG_FILE)           LOG_FILE="$(expand_home "$val")";;
      NOTIFY)             case "$val" in yes|YES|true|1) NOTIFY=yes;; *) NOTIFY=no;; esac;;
      NOTIFY_PROGRESS)     NOTIFY_PROGRESS="${val#-}"; if ! printf '%s\n' "$NOTIFY_PROGRESS" | grep -qxE '[0-9]+'; then NOTIFY_PROGRESS=25; fi;;
      PROGRESS_BAR)        case "$val" in yes|YES|true|1) PROGRESS_BAR=yes;; *) PROGRESS_BAR=no;; esac;;
      PROGRESS_FILE)       PROGRESS_FILE="$(expand_home "$val")";;
      EXIF_BATCH)          case "$val" in yes|YES|true|1) EXIF_BATCH=yes;; *) EXIF_BATCH=no;; esac;;
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
volumes_root() { printf '%s' "${SD_VOLUMES_DIR:-/Volumes}"; }

# Looks for a DCIM folder at the volume root or one level down, mirroring the
# Swift implementation: symlinks and nested mounts (cloud shares on nfs, smbfs
# or webdav) are skipped because they can hang for minutes when unreachable.
has_dcim() {
  local v="$1" vdev child cdev grandchild
  vdev="$(stat -f %d "$v" 2>/dev/null)" || return 1
  for child in "$v"/*; do
    [ -d "$child" ] || continue
    [ -L "$child" ] && continue
    [ "$(basename -- "$child" | tr '[:upper:]' '[:lower:]')" = "dcim" ] && return 0
    cdev="$(stat -f %d "$child" 2>/dev/null)"
    [ -n "$cdev" ] && [ "$cdev" != "$vdev" ] && continue
    for grandchild in "$child"/*; do
      # Compare names before touching the filesystem: a stale cloud mount can
      # take minutes to answer a stat, and only a DCIM candidate is worth it.
      [ "$(basename -- "$grandchild" | tr '[:upper:]' '[:lower:]')" = "dcim" ] || continue
      [ -d "$grandchild" ] || continue
      return 0
    done
  done
  return 1
}

scan_card_volumes() {
  local v name count=0 found=""
  for v in "$(volumes_root)"/*; do
    [ -d "$v" ] || continue
    name="$(basename -- "$v")"
    [ "$name" = "Macintosh HD" ] && continue
    [ -L "$v" ] && continue
    if has_dcim "$v"; then
      count=$((count + 1)); found="$v"
    fi
  done
  SCAN_COUNT="$count"; SCAN_FOUND="$found"
}

diskutil_out() { diskutil "$@" 2>/dev/null; }

# macOS sometimes leaves a freshly inserted card unmounted, which used to end
# the run with "no SD card found". Mount removable media, then look again.
# Fixed disks (external SSDs, NAS mounts) are never touched, and a volume that
# still has no DCIM folder is left alone for the caller to ignore.
mount_removable_media() {
  local disk part point
  while read -r disk; do
    [ -n "$disk" ] || continue
    diskutil_out info "$disk" | grep -Eq "Removable Media:.*Removable" || continue
    while read -r part; do
      [ -n "$part" ] || continue
      diskutil_out info "$part" | grep -Eq "Mounted:.*No" || continue
      if point="$(diskutil_out mount "$part")" && [ -n "$point" ]; then
        log "Mounted $point (was not mounted)"
      fi
    done < <(diskutil_out list "$disk" | awk -v d="${disk#/dev/}" '{ id=$NF; if (id ~ "^" d "s[0-9]+$") print "/dev/" id }')
  done < <(diskutil_out list external physical | awk '/^\/dev\/disk[0-9]+ \(external/ {print $1}')
}

resolve_cards() {
  local name count v found p

  CARD_PATHS=()
  if [ "${#ARG_CARDS[@]}" -gt 0 ]; then
    for p in "${ARG_CARDS[@]}"; do
      [ -d "$p" ] || die "card path is not a directory: $p"
      CARD_PATHS+=("$p")
    done
    return 0
  fi

  if [ "$SD_CARD" != "auto" ]; then
    p="$(expand_home "$SD_CARD")"
    [ -d "$p" ] || die "configured SD_CARD is not a directory: $p"
    CARD_PATHS=("$p")
    return 0
  fi

  scan_card_volumes
  if [ "$SCAN_COUNT" -eq 0 ]; then
    mount_removable_media
    scan_card_volumes
  fi
  count="$SCAN_COUNT"; found="$SCAN_FOUND"; v="$(volumes_root)"

  [ "$count" -eq 0 ] && die "no SD card found: no volume under $v has a DCIM folder"
  [ "$count" -gt 1 ] && die "multiple SD cards found; pass one explicitly with --card (or drop it on the action)"
  CARD_PATHS=("$found")
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
# Batched metadata extraction
#
# Reading metadata one tag at a time costs one exiftool process per tag per
# file (~6 per file, ~90ms each), which dominates the run: 100 files took 27s
# that way versus 0.3s for a single batched pass. So we walk the card once
# with `exiftool -json` and flatten the result into a TSV the loop reads.
# Columns: SourceFile, DateTimeOriginal, CreateDate, ModifyDate, Model, Make,
# FileName. Absent tags are written as "-" rather than empty: a tab-separated
# `read` would otherwise swallow the empty fields and shift the columns, since
# tab is an IFS whitespace character.
# ---------------------------------------------------------------------------

JSON_TSV_PY='
import json, sys

KEYS = ("SourceFile", "DateTimeOriginal", "CreateDate", "ModifyDate",
        "Model", "Make", "FileName")
MISSING = "-"

def first(value):
    if isinstance(value, list):
        return first(value[0]) if value else ""
    if value is None:
        return ""
    return str(value)

def clean(text):
    return " ".join(text.replace("\t", " ").replace("\r", " ").split("\n"))

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

with open(sys.argv[1], "w") as out:
    for item in data:
        row = [clean(first(item.get(k, ""))) for k in KEYS]
        if not row[0]:
            continue
        row = [v if v else MISSING for v in row]
        out.write("\t".join(row) + "\n")
'

json_to_tsv() { # stdin: exiftool -json, $1: output TSV
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c "$JSON_TSV_PY" "$1" 2>/dev/null
}

# Camera image shot number, taken from the digits immediately preceding the
# extension in the EXIF FileName tag (e.g. "_DSF5099.RAF" -> "5099"). This is
# the number the camera burns into both the RAW and the HEIF of a pair.
exif_number() { # file -> digits only, no padding
  number_from_name "$(exif_field FileName "$1")"
}

# Pull the trailing digit run out of a camera file name
# (e.g. "_DSF5099.RAF" -> "5099"). Split out so the batched path can reuse it.
number_from_name() { # name -> digits only, no padding
  local n="$1"
  [ -n "$n" ] || return 0
  n="${n%.*}"              # strip extension
  n="${n##*[^0-9]}"        # keep the trailing run of digits
  [ -n "$n" ] && printf '%s' "$n"
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
    case "$num" in ''|*[!0-9]*) continue;; *) num=$((10#$num));; esac
    [ "$num" -gt "$best" ] && best=$num
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
  # scan_max_number prints 0 rather than an empty string, so test the value:
  # an empty scan must fall back to COUNTER_START, not a hard-coded 1.
  [ "$maxn" -lt 1 ] && maxn=$((COUNTER_START - 1))
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
HANDED_OVER=no

main() {
  local c total_copy=0 total_skip=0

  cd "$HOME" || true   # cd out of /Volumes so the card can be unmounted

  mkdir -p "$STATE_DIR" "$TARGET_DIR" 2>/dev/null
  mkdir -p "${LOG_FILE%/*}" 2>/dev/null
  [ -n "$BACKUP_DIR" ] && mkdir -p "$BACKUP_DIR"

  # Default progress file so Shortcuts/other tools can poll import state.
  [ -z "$PROGRESS_FILE" ] && PROGRESS_FILE="$STATE_DIR/progress.txt"

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

  claim_run_lock
  if [ -n "$CLAIM_BUSY_PID" ]; then
    die "another import is already in progress (pid $CLAIM_BUSY_PID)"
  fi
  trap 'release_run_lock' EXIT

  resolve_cards

  CARD_COUNT="${#CARD_PATHS[@]}"
  c=0
  for SD_PATH in "${CARD_PATHS[@]}"; do
    c=$((c + 1))
    copy_count=0; skip_count=0

    HANDED_OVER=no
    import_card_body
    total_copy=$((total_copy + copy_count))
    total_skip=$((total_skip + skip_count))
    if [ "$HANDED_OVER" = yes ]; then break; fi
    maybe_eject
  done

  if [ "$DRY_RUN" = yes ]; then rm -rf "$WORK_STATE"; fi
  if [ "${HANDED_OVER:-no}" = yes ]; then
    log "Stopped: a newer instance took over."
    progress "done" "stopped, a newer instance took over"
    return 0
  fi
  log "Done: $total_copy imported, $total_skip already present."
  if [ "$DRY_RUN" = yes ]; then
    log "DRY RUN - no files were written."
    progress "done" "$total_copy would import, $total_skip skipped (dry run)"
  else
    progress "done" "$total_copy imported, $total_skip skipped"
    notify "Done: $total_copy imported, $total_skip skipped."
  fi
}

# Import one card from SD_PATH. Leaves its tallies in copy_count/skip_count.
import_card_body() {
  local f ext h exif_dt year month day hh min ss model
  local token key num numpad name target backup
  local exifnum used_counter prev prevrel
  local total TOTAL=0 DONE_COUNT=0 TOTAL_PCT=0 LAST_NOTIFY_PCT=-1

  # Build find expression from extension lists.
  local name_args=() e
  for e in $PHOTO_EXTS $VIDEO_EXTS; do
    if [ "${#name_args[@]}" -eq 0 ]; then name_args+=(-iname "*.$e"); else name_args+=(-o -iname "*.$e"); fi
  done
  [ "${#name_args[@]}" -gt 0 ] || die "no file extensions configured"

  if [ "$CARD_COUNT" -gt 1 ]; then
    log "SD card:   $SD_PATH ($c/$CARD_COUNT)"
  else
    log "SD card:   $SD_PATH"
  fi
  log "Target:    $TARGET_DIR"
  [ -n "$BACKUP_DIR" ] && log "Backup:    $BACKUP_DIR"
  log "Scanning for photos/videos..."
  notify "Importing from $(basename "$SD_PATH")..."
  [ -n "$PROGRESS_FILE" ] && log "Progress: $PROGRESS_FILE"

  # Materialize the list so we know the total and can render a real progress bar.
  local listf="$WORK_STATE/filelist"
  find "$SD_PATH" -type f "${name_args[@]}" 2>/dev/null | sort >"$listf"
  total="$(grep -c '' "$listf" 2>/dev/null)"; [ -n "$total" ] || total=0
  TOTAL="$total"
  log "Found $total file(s)."
  progress "starting" "scanning"

  # One batched metadata pass over the card (see "Batched metadata extraction").
  local metaf="$WORK_STATE/meta.tsv"
  : >"$metaf"
  if [ "$EXIF_BATCH" = yes ] && [ "$total" -gt 0 ]; then
    local tag_args=(-r)
    for e in $PHOTO_EXTS $VIDEO_EXTS; do tag_args+=(-ext "$e"); done
    log "Reading metadata in one pass..."
    "$EXIFTOOL" -q -q -json "${tag_args[@]}" \
      -SourceFile -DateTimeOriginal -CreateDate -ModifyDate -Model -Make \
      -FileName "$SD_PATH" 2>/dev/null | json_to_tsv "$metaf"
  fi
  # If batching is off, python3 is missing, or exiftool failed, fall back to
  # reading tags file by file: slower, but never silently wrong.
  if [ ! -s "$metaf" ] && [ "$total" -gt 0 ]; then
    [ "$EXIF_BATCH" = yes ] && log "WARN: batch metadata unavailable; falling back to per-file reads."
    log "Reading metadata file by file..."
    local bf d mdl mk fn
    while IFS= read -r bf; do
      [ -n "$bf" ] || continue
      d="$(exif_datetime "$bf" 2>/dev/null)"; [ -n "$d" ] || d="-"
      mdl="$(exif_field Model "$bf")"; [ -n "$mdl" ] || mdl="-"
      mk="$(exif_field Make "$bf")"; [ -n "$mk" ] || mk="-"
      fn="$(exif_field FileName "$bf")"; [ -n "$fn" ] || fn="-"
      printf '%s\t%s\t-\t-\t%s\t%s\t%s\n' "$bf" "$d" "$mdl" "$mk" "$fn" >>"$metaf"
    done <"$listf"
  fi

  # Files exiftool did not report (unreadable/unsupported) still get imported,
  # with empty metadata so the loop falls back to mtime + UNKNOWN + counter.
  local leftover="$WORK_STATE/leftover.txt" lf
  LC_ALL=C comm -23 <(LC_ALL=C sort "$listf") \
                   <(cut -f1 "$metaf" 2>/dev/null | LC_ALL=C sort -u) >"$leftover"
  if [ -s "$leftover" ]; then
    log "WARN: $(grep -c '' "$leftover") file(s) unreadable by exiftool; using file dates."
    while IFS= read -r lf; do
      [ -n "$lf" ] && printf '%s\t-\t-\t-\t-\t-\t-\n' "$lf" >>"$metaf"
    done <"$leftover"
  fi

  # Deterministic order regardless of which metadata path filled metaf: the
  # sequential counter fallback depends on processing order, so both must match.
  LC_ALL=C sort -o "$metaf" "$metaf"

  local h
  local PROGRESS_TTY=no
  [ "$PROGRESS_BAR" = yes ] && [ -t 1 ] && PROGRESS_TTY=yes

  # $2..$7 are the pre-read metadata fields (see json_to_tsv columns).
  while IFS=$'\t' read -r f dt_dto dt_cdt dt_mdt dt_model dt_make dt_fname; do
    if takeover_requested; then
      log "Handing over: a newer instance asked me to stop."
      HANDED_OVER=yes
      break
    fi
    [ -n "$f" ] || continue
    # "-" means "this tag was absent".
    [ "$dt_dto" = "-" ] && dt_dto=""
    [ "$dt_cdt" = "-" ] && dt_cdt=""
    [ "$dt_mdt" = "-" ] && dt_mdt=""
    [ "$dt_model" = "-" ] && dt_model=""
    [ "$dt_make" = "-" ] && dt_make=""
    [ "$dt_fname" = "-" ] && dt_fname=""
    ext="${f##*.}"; ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"

    h="$(md5 -q "$f" 2>/dev/null)"
    [ -z "$h" ] && h="$(shasum "$f" 2>/dev/null | cut -d' ' -f1)"

    # Date: DateTimeOriginal -> CreateDate -> ModifyDate -> file mtime.
    exif_dt=""
    [ -n "$dt_dto" ] && exif_dt="$dt_dto"
    [ -z "$exif_dt" ] && [ -n "$dt_cdt" ] && exif_dt="$dt_cdt"
    [ -z "$exif_dt" ] && [ -n "$dt_mdt" ] && exif_dt="$dt_mdt"
    case "$exif_dt" in
      [0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) exif_dt="${exif_dt:0:19}";;
      *) exif_dt="$(mtime_datetime "$f")";;
    esac

    year="${exif_dt:0:4}"; month="${exif_dt:5:2}"; day="${exif_dt:8:2}"
    hh="${exif_dt:11:2}"; min="${exif_dt:14:2}"; ss="${exif_dt:17:2}"

    SUBDIR=""; fmt_subdir "$FOLDER_PATTERN" "$year" "$month" "$day" "$hh" "$min" "$ss"

    model="$dt_model"
    [ -n "$model" ] || model="$dt_make"
    token="$(sanitize_token "$model")"

    if [ "$COUNTER_PER_MODEL" = "yes" ]; then key="$token"; else key="ALL"; fi

    # Image number: from EXIF by default (pairs share it), else sequential counter.
    exifnum=""
    if [ "$NUMBER_SOURCE" = "exif" ]; then
      exifnum="$(number_from_name "$dt_fname")"
      # Force base 10. printf "%d" reads a leading-zero number as octal, so
      # "0008" would print as 0000 and "0010" as 0008.
      case "$exifnum" in
        ''|*[!0-9]*) exifnum="";;
        *) exifnum=$((10#$exifnum));;
      esac
    fi
    numpad=""
    used_counter=no
    if [ -n "$exifnum" ]; then
      numpad="$(printf "%0*d" "$COUNTER_DIGITS" "$exifnum")"
    else
      num="$(next_number "$token" "$key")"
      numpad="$(printf "%0*d" "$COUNTER_DIGITS" "$num")"
      used_counter=yes
    fi
    name="${token}-${year}${month}${day}-${numpad}.${ext}"

    target="$TARGET_DIR${SUBDIR:+/$SUBDIR}/$name"
    backup="$BACKUP_DIR${SUBDIR:+/$SUBDIR}/$name"

    if [ -e "$target" ]; then
      # For EXIF-numbered names the target name is deterministic, so an existing
      # file means "already imported". A counter-generated name can collide with
      # an unrelated file, which would silently drop a photo - warn instead.
      if [ "$used_counter" = yes ]; then
        if [ "$PROGRESS_TTY" = yes ]; then logf "WARN: name collision, not importing: $name"; else log "WARN: name collision, not importing: $name"; fi
      fi
      skip_count=$((skip_count + 1))
      if [ "$PROGRESS_TTY" = yes ]; then logf "skip     (already imported): $name"; else log "skip     (already imported): $name"; fi
      progress_update "$name" skipped; continue
    fi

    # Content-ledger dedup: skip only if the copy we recorded still exists in
    # the library. Deleted files re-import on the next run.
    if [ -n "$h" ]; then
      prev="$(grep -F "$h" "$WORK_LEDGER" 2>/dev/null | tail -n 1)"
      if [ -n "$prev" ]; then
        prevrel="${prev#*$'\t'}"
        if [ "$prevrel" != "$prev" ] && [ -e "$TARGET_DIR/$prevrel" ]; then
          skip_count=$((skip_count + 1))
          if [ "$PROGRESS_TTY" = yes ]; then logf "skip     (already imported and still in library): $name"; else log "skip     (already imported and still in library): $name"; fi
          progress_update "$name" skipped; continue
        fi
      fi
    fi

    if [ "$PROGRESS_TTY" = yes ]; then
      logf "import   $name"
      logf "         from: $f"
      [ -n "$BACKUP_DIR" ] && logf "         backup to: $BACKUP_DIR${SUBDIR:+/$SUBDIR}"
    else
      log "import   $name"
      log "         from: $f"
      [ -n "$BACKUP_DIR" ] && log "         backup to: $BACKUP_DIR${SUBDIR:+/$SUBDIR}"
    fi

    if [ "$DRY_RUN" != yes ]; then
      mkdir -p "$(dirname -- "$target")"
      cp -p "$f" "$target"         || log "WARN: copy to target failed for $name"
      if [ -n "$BACKUP_DIR" ]; then
        mkdir -p "$(dirname -- "$backup")"
        [ -e "$backup" ] || cp -p "$f" "$backup" || log "WARN: backup copy failed for $name"
      fi
      [ "$used_counter" = yes ] && bump_counter "$key" "$((num + 1))"
      [ -n "$h" ] && printf '%s\t%s\n' "$h" "${target#$TARGET_DIR/}" >>"$WORK_LEDGER"
    fi
    copy_count=$((copy_count + 1))
    progress_update "$name" imported
  done <"$metaf"

  bar_clear
}

# Eject the card once the import finished without errors.
maybe_eject() {
  [ "$EJECT_CARD" = "yes" ] || { log "Eject skipped (EJECT_CARD=$EJECT_CARD)."; return 0; }
  if [ "$DRY_RUN" = yes ]; then
    log "DRY RUN - would eject $SD_PATH"
    return 0
  fi
  case "$SD_PATH" in
    /Volumes/*)
      if diskutil eject "$SD_PATH" >/dev/null 2>&1; then
        log "Ejected $SD_PATH"
      else
        log "WARN: could not eject $SD_PATH (not a mountable volume?)"
      fi
      ;;
    *)
      log "Not ejecting non-volume path: $SD_PATH"
      ;;
  esac
}


# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) [ $# -ge 2 ] || die "--config needs a file argument"; CONFIG_FILE="$2"; shift 2;;
    --card)      [ $# -ge 2 ] || die "--card needs a path argument"; ARG_CARDS+=("$2"); shift 2;;
    --dry-run)   DRY_RUN=yes; shift;;
    --no-eject)  NO_EJECT=yes; shift;;
    -h|--help)   usage; exit 0;;
    -*)          die "unknown option: $1 (see --help)";;
    *)           ARG_CARDS+=("$1"); shift;;   # Automator passes dropped folders here
  esac
done

# Belt and suspenders: if Automator delivered folders on stdin, use the first.
if [ "${#ARG_CARDS[@]}" -eq 0 ] && [ ! -t 0 ]; then
  while IFS= read -r line; do
    if [ -n "$line" ] && [ -d "$line" ]; then ARG_CARDS+=("$line"); break; fi
  done
fi

load_config
[ "$NO_EJECT" = yes ] && EJECT_CARD=no
main