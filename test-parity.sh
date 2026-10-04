#!/bin/bash
# Parity harness: runs the Bash and Swift implementations over identical
# fixtures and compares every observable - target/backup names and contents,
# counters, ledger lines, per-file decisions and exit codes.
#
# Usage:  ./test-parity.sh [-v] [scenario ...]
# Env:    SWIFT_BIN=<path>   use an already built binary instead of compiling
#         WORK=<dir>         scratch directory (default: $TMPDIR/sd-parity-$$)
#         EXIFTOOL=<path>    exiftool to use
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
BASH_BIN="$REPO/sd-photo-download.sh"
EXIFTOOL="${EXIFTOOL:-/opt/homebrew/bin/exiftool}"
WORK="${WORK:-${TMPDIR:-/tmp}/sd-parity-$$}"
VERBOSE=0
FAILURES=0
ONLY_SCENARIOS=""

while [ $# -gt 0 ]; do
    case "$1" in
        -v) VERBOSE=1 ;;
        -*) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) ONLY_SCENARIOS="$ONLY_SCENARIOS $1" ;;
    esac
    shift
done

mkdir -p "$WORK" || exit 1
CARDS="$WORK/cards"

swift_bin() {
    if [ -n "${SWIFT_BIN:-}" ]; then printf '%s' "$SWIFT_BIN"; return; fi
    printf '%s' "$WORK/sd-photo-download-swift"
}

build_swift() {
    [ -n "${SWIFT_BIN:-}" ] && return 0
    if [ ! -x "$WORK/sd-photo-download-swift" ] \
       || [ "$REPO/sd-photo-download.swift" -nt "$WORK/sd-photo-download-swift" ]; then
        printf 'building Swift binary...\n' >&2
        swiftc -O -o "$WORK/sd-photo-download-swift" "$REPO/sd-photo-download.swift" \
            || { printf 'swift build failed\n' >&2; exit 1; }
    fi
}

# ---------------------------------------------------------------- fixtures --

# Deterministic 2x2 PNG whose bytes depend on $1, so every fixture file has a
# unique md5 without needing to ship binaries in the repo.
make_png() { # <out.png> <seed>
    python3 - "$1" "$2" <<'PY'
import sys, zlib, struct
path, seed = sys.argv[1], int(sys.argv[2])
def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
rows = b"".join(b"\x00" + bytes(((seed * 11) % 256, (seed * 23) % 256, (seed * 37) % 256)) * 2
               for _ in range(2))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
open(path, "wb").write(png)
PY
}

fresh_cards() {
    rm -rf "$CARDS"
    mkdir -p "$CARDS/mixed/DCIM/100GUFOS" "$CARDS/second/DCIM" "$CARDS/empty/DCIM" "$CARDS/noexif"
    local i=0
    for n in IMG_0001 IMG_0008 IMG_0010 IMG_0099 RAW_5099 RAW_5100 VID_0042; do
        i=$((i + 1))
        make_png "$CARDS/stage-$i.png" "$i"
    done
    # Two files share one camera number, as on Fujifilm bodies.
    cp "$CARDS/stage-5.png" "$CARDS/mixed/DCIM/100GUFOS/RAW_5099.RAF"
    cp "$CARDS/stage-6.png" "$CARDS/mixed/DCIM/100GUFOS/RAW_5099.HIF"
    cp "$CARDS/stage-6.png" "$CARDS/mixed/DCIM/100GUFOS/RAW_5100.RAF"
    cp "$CARDS/stage-1.png" "$CARDS/mixed/DCIM/100GUFOS/IMG_0001.RAF"
    cp "$CARDS/stage-2.png" "$CARDS/mixed/DCIM/100GUFOS/IMG_0008.RAF"
    cp "$CARDS/stage-3.png" "$CARDS/mixed/DCIM/100GUFOS/IMG_0010.RAF"
    cp "$CARDS/stage-4.png" "$CARDS/mixed/DCIM/100GUFOS/IMG_0099.RAF"
    cp "$CARDS/stage-7.png" "$CARDS/mixed/DCIM/100GUFOS/VID_0042.MP4"
    # No number in the name: exercises the sequential counter.
    cp "$CARDS/stage-1.png" "$CARDS/mixed/DCIM/100GUFOS/shoot.JPEG"
    # Byte order matters for LC_ALL=C sort vs Swift's utf8 comparison.
    cp "$CARDS/stage-2.png" "$CARDS/mixed/DCIM/100GUFOS/IMG_0100ä.png"
    cp "$CARDS/stage-3.png" "$CARDS/mixed/DCIM/100GUFOS/IMG_0100.png"
    cp "$CARDS/stage-4.png" "$CARDS/mixed/DCIM/100GUFOS/IMG_0100~.png"
    # exiftool cannot read this one: UNKNOWN model + mtime fallback.
    head -c 64 /dev/urandom > "$CARDS/mixed/DCIM/100GUFOS/BAD.RAF"

    make_png "$CARDS/stage-1.png" 1
    cp "$CARDS/stage-1.png" "$CARDS/second/DCIM/IMG_2001.RAF"
    make_png "$CARDS/stage-2.png" 2
    cp "$CARDS/stage-2.png" "$CARDS/noexif/PLAIN.RAF"

    if [ -x "$EXIFTOOL" ]; then
        "$EXIFTOOL" -q -overwrite_original -Model="Fujifilm GFX100RF" \
            -DateTimeOriginal="2026:08:29 12:34:56" \
            "$CARDS/mixed/DCIM/100GUFOS"/*.RAF "$CARDS/mixed/DCIM/100GUFOS"/*.HIF \
            "$CARDS/mixed/DCIM/100GUFOS"/*.JPEG "$CARDS/mixed/DCIM/100GUFOS"/*.png \
            >/dev/null 2>&1
        "$EXIFTOOL" -q -overwrite_original -Model="Canon EOS R5" \
            -DateTimeOriginal="2025:01:02 03:04:05" "$CARDS/second/DCIM/IMG_2001.RAF" >/dev/null 2>&1
    fi
    rm -f "$CARDS"/stage-*.png
}

# An exiftool stand-in whose batched (-json) pass yields nothing, so both
# implementations must fall back to reading tags one file at a time.
shim_no_batch() { # <out-path>
    cat > "$1" <<EOF
#!/bin/bash
for a in "\$@"; do
    [ "\$a" = "-json" ] && exit 0     # batched pass returns nothing
done
exec $EXIFTOOL "\$@"
EOF
    chmod +x "$1"
}

# Same, plus synthesised tags for video files: no DateTimeOriginal, a
# CreateDate, and a model, so the video branch of both implementations runs.
shim_videos() { # <out-path>
    cat > "$1" <<EOF
#!/bin/bash
# Understands both per-file protocols: one tag at a time (-s -s -s -TAG file)
# and every tag at once (-s -s -s -T -A -B file).
TAB=\$(printf '\t')
for a in "\$@"; do
    [ "\$a" = "-json" ] && exit 0
done
tabs=no; tags=""; file=""
for a in "\$@"; do
    case "\$a" in
        -T) tabs=yes ;;
        -*) t="\${a#-}"
            case "\$t" in s|q|q) ;; *) tags="\$tags \$t" ;; esac ;;
        *) file="\$a" ;;
    esac
done
video_value() {
    case "\$1" in
        DateTimeOriginal) ;;
        CreateDate|ModifyDate) printf '2024:03:04 05:06:07' ;;
        Model) printf 'HandyCam' ;;
        Make) printf 'Handy' ;;
        FileName) printf '%s' "\${file##*/}" ;;
    esac
}
case "\$file" in
    *.MOV|*.mov|*.MP4|*.mp4|*.M4V|*.m4v)
        if [ "\$tabs" = yes ]; then
            sep=""
            for t in \$tags; do
                printf '%s' "\$sep"; video_value "\$t"; sep="\$TAB"
            done
            printf '\n'
        else
            for t in \$tags; do video_value "\$t"; printf '\n'; break; done
        fi
        exit 0 ;;
esac
exec $EXIFTOOL "\$@"
EOF
    chmod +x "$1"
}

# ------------------------------------------------------------------ config --

write_config() { # <root> <card-spec-file> [KEY=VALUE ...]
    local root="$1"; shift
    local cards_file="$1"; shift
    mkdir -p "$root/target" "$root/backup" "$root/state"
    {
        printf 'TARGET_DIR=%s/target\n' "$root"
        printf 'BACKUP_DIR=%s/backup\n' "$root"
        printf 'STATE_DIR=%s/state\n' "$root"
        printf 'EXIFTOOL=%s\n' "$EXIFTOOL"
        printf 'NOTIFY=no\n'
        printf 'PROGRESS_BAR=yes\n'
        local kv
        for kv in "$@"; do printf '%s\n' "$kv"; done
    } > "$root/config"
    # The card list is passed per run so scenarios can vary it.
    printf '%s\n' "$cards_file"
}

# ------------------------------------------------------------------- report --

normalize_lines() { # strip timestamps and pids so bash and swift logs compare
    sed -e 's/^\[[0-9-]* [0-9:]*\] //' -e 's/pid [0-9][0-9]*/pid N/g'
}

report() { # <root>
    local root="$1"
    printf 'exit: %s\n' "$2"
    printf -- '-- target --\n'
    if [ -d "$root/target" ]; then
        ( cd "$root/target" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
              printf '%s %s\n' "$(md5 -q "$f")" "$f"; done )
    fi
    printf -- '-- backup --\n'
    if [ -d "$root/backup" ]; then
        ( cd "$root/backup" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
              printf '%s %s\n' "$(md5 -q "$f")" "$f"; done )
    fi
    printf -- '-- counters --\n'
    if [ -d "$root/state/counters" ]; then
        for f in "$root/state/counters"/*.txt; do
            [ -e "$f" ] || continue
            printf '%s %s\n' "$(basename "$f")" "$(tr -d '[:space:]' < "$f")"
        done | LC_ALL=C sort
    fi
    printf -- '-- ledger --\n'
    if [ -f "$root/state/imported.txt" ]; then
        LC_ALL=C sort "$root/state/imported.txt" | sed -e 's/$//'
    fi
    printf -- '-- progress --\n'
    if [ -f "$root/state/progress.txt" ]; then grep -o 'status=[a-z]*' "$root/state/progress.txt" | tail -1; fi
    printf -- '-- decisions --\n'
    if [ -f "$root/state/run.log" ]; then
        normalize_lines < "$root/state/run.log" \
            | sed -e "s|$root|@ROOT@|g" -e "s|$CARDS|@CARDS@|g" \
            | grep -E '^(import|skip|WARN|ERROR|Done|Found|Eject|DRY RUN|Not ejecting|Another instance|Took over|Handing over|Stopped:)' || true
    fi
    # Everything the user actually sees: the same lines bash prints to the
    # terminal, with each implementation's own scratch root folded away.
    printf -- '-- stdout --\n'
    if [ -s "$root/stdout.txt" ]; then
        sed -e "s|$root|@ROOT@|g" -e "s|$CARDS|@CARDS@|g" "$root/stdout.txt" \
            | normalize_lines
    fi
}

# ------------------------------------------------------------------- runner --

run_impl() { # <impl> <root> <script-or-binary> [args...]
    local impl="$1" root="$2"; shift 2
    local out rc
    if [ "$impl" = bash ]; then
        out="$("$BASH_BIN" "$@" 2>&1)"; rc=$?
    else
        out="$("$SWIFT" "$@" 2>&1)"; rc=$?
    fi
    printf '%s' "$out" > "$root/stdout.txt"
    return $rc
}

# --------------------------------------------------------------- scenarios --

# Each scenario receives the runner command as $RUN and its own root, and must
# leave observable state behind. Reports are produced by the caller.

scenario_basic() { # $1 runner fn, $2 root
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM"
}

scenario_rerun() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_deleted() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
    # Remove one imported file: the next run must bring it back even though its
    # hash is in the ledger.
    find "$root/target" -name '*5099.raf' -delete
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_legacy_ledger() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    mkdir -p "$root/state" "$root/target/2026/2026-08-29"
    # Legacy format: hash only, no recorded path, so it must not block import.
    local h; h="$(md5 -q "$CARDS/mixed/DCIM/100GUFOS/IMG_0001.RAF")"
    printf '%s\n' "$h" > "$root/state/imported.txt"
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_dry_run() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" --dry-run --no-eject >/dev/null
}

scenario_dry_run_then_real() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" --dry-run --no-eject >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_no_backup() {
    local run="$1" root="$2"
    write_config "$root" ignored BACKUP_DIR= >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_counter_source() {
    local run="$1" root="$2"
    write_config "$root" ignored NUMBER_SOURCE=counter >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_global_counter() {
    local run="$1" root="$2"
    write_config "$root" ignored COUNTER_PER_MODEL=no >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
    # A second model must continue the same global counter.
    $run "$root" --config "$root/config" --card "$CARDS/second/DCIM" >/dev/null
}

scenario_counter_start() {
    local run="$1" root="$2"
    write_config "$root" ignored NUMBER_SOURCE=counter COUNTER_START=7 COUNTER_DIGITS=3 >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/noexif" >/dev/null
}

scenario_seeded_counter() {
    local run="$1" root="$2"
    write_config "$root" ignored NUMBER_SOURCE=counter >/dev/null
    mkdir -p "$root/state/counters"
    printf '4242\n' > "$root/state/counters/ALL.txt"
    $run "$root" --config "$root/config" --card "$CARDS/noexif" >/dev/null
}

scenario_existing_library_numbers() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    # Library already holds numbers up to 5100, so the counter must not collide.
    mkdir -p "$root/target/2026/2026-08-29"
    cp "$CARDS/mixed/DCIM/100GUFOS/IMG_0001.RAF" "$root/target/2026/2026-08-29/Fujifilm-GFX100RF-20260829-5100.raf"
    cp "$CARDS/mixed/DCIM/100GUFOS/IMG_0001.RAF" "$root/target/2026/2026-08-29/Fujifilm-GFX100RF-20260829-5099.raf"
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_multi_card() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" --card "$CARDS/second/DCIM" >/dev/null
}

scenario_missing_card() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/does-not-exist" >/dev/null
}

scenario_empty_card() {
    local run="$1" root="$2"
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/empty/DCIM" >/dev/null
}

scenario_no_exiftool() {
    local run="$1" root="$2"
    write_config "$root" ignored EXIFTOOL=/nonexistent/exiftool >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_per_file_metadata() {
    local run="$1" root="$2"
    write_config "$root" ignored EXIF_BATCH=no >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_flat_library() {
    local run="$1" root="$2"
    write_config "$root" ignored FOLDER_PATTERN= >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_folder_pattern_time() {
    local run="$1" root="$2"
    write_config "$root" ignored 'FOLDER_PATTERN=%Y/%y-%m/%H%M' >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_batch_fallback() {
    local run="$1" root="$2"
    local shim="$root/exiftool-shim"
    shim_no_batch "$shim"
    write_config "$root" ignored "EXIFTOOL=$shim" >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_videos() {
    local run="$1" root="$2"
    local shim="$root/exiftool-shim"
    shim_videos "$shim"
    write_config "$root" ignored "EXIFTOOL=$shim" >/dev/null
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
}

scenario_sd_card_config() {
    local run="$1" root="$2"
    # No --card: both implementations must take the configured mount point.
    write_config "$root" ignored "SD_CARD=$CARDS/mixed/DCIM" >/dev/null
    $run "$root" --config "$root/config" >/dev/null
}

# A lock left behind by a crashed run must not block the next run.
scenario_stale_lock() {
    local run="$1" root="$2"
    write_config "$root" ignored SD_CARD=auto >/dev/null
    # No such process: the lock is stale and has to be ignored.
    printf '999999\n' > "$root/state/run.lock"
    $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
    rm -f "$root/state/run.lock"
}

# A live lock whose owner never stops (an import that cannot be interrupted at
# a file boundary) must make the newcomer refuse rather than import in parallel.
scenario_busy_lock() {
    local run="$1" root="$2"
    write_config "$root" ignored SD_CARD=auto >/dev/null
    sleep 300 &
    local holder=$!
    printf '%s\n' "$holder" > "$root/state/run.lock"
    LOCK_WAIT_SECONDS=1 $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
    kill "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null
    # The request must be cleaned up so the next run starts clean.
    rm -f "$root/state/run.lock" "$root/state/run.lock.takeover"
}

# Two instances at once. The first is held inside its metadata pass by a gated
# exiftool wrapper, so the test decides exactly when it may continue: by then the
# second one has asked it to stop. The first must hand over at the next file
# boundary without importing anything, and the second must import the lot.
scenario_takeover() {
    local run="$1" root="$2"
    local gate="$root/gate"
    cat > "$root/slow-exiftool" <<EOF
#!/bin/bash
# Blocks until the test opens the gate, so the run can be paused mid-flight.
while [ ! -f "$gate" ]; do sleep 0.05; done
exec $EXIFTOOL "\$@"
EOF
    chmod +x "$root/slow-exiftool"
    write_config "$root" ignored SD_CARD=auto >/dev/null
    sed -i '' "s|^EXIFTOOL=.*|EXIFTOOL=$root/slow-exiftool|" "$root/config"

    LOCK_WAIT_SECONDS=20 $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null &
    local first=$!
    local waited=0
    while [ ! -f "$root/state/run.lock" ] && [ "$waited" -lt 200 ]; do sleep 0.05; waited=$((waited + 1)); done
    [ -f "$root/state/run.lock" ] || { wait "$first"; printf 'first run never started\n' > "$root/decisions.txt"; return 0; }

    # Open the gate only once the second instance has asked the first one to
    # stop, so the handover happens at a known point rather than by timeout.
    ( while [ ! -f "$root/state/run.lock.takeover" ]; do sleep 0.05; done
      sleep 0.3
      : > "$gate" ) &
    local opener=$!

    LOCK_WAIT_SECONDS=20 $run "$root" --config "$root/config" --card "$CARDS/mixed/DCIM" >/dev/null
    wait "$first"
    wait "$opener" 2>/dev/null
    # The second run overwrote stdout.txt; stitch both halves back together,
    # newline included so the last line of one is not glued to the next.
    cat "$root/stdout.txt" > "$root/stdout-a.txt"
    { cat "$root/stdout-a.txt"; printf '\n'; cat "$root/stdout.txt"; } > "$root/stdout-both.txt"
    mv "$root/stdout-both.txt" "$root/stdout.txt"
    rm -f "$gate"
}

# A card the OS has not mounted yet: both must mount it, then carry on.
# Needs SD_VOLUMES_DIR (fake volumes root) and a fake diskutil on PATH, since
# touching real /Volumes or a real disk is not an option in tests.
scenario_unmounted_card() {
    local run="$1" root="$2"
    local vols="$root/volumes" shim="$root/shim"
    mkdir -p "$vols" "$shim"
    cat > "$shim/diskutil" <<EOF
#!/bin/bash
# Fake diskutil: one removable, unmounted card that materialises on mount.
case "\$*" in
"list external physical")
    printf '/dev/disk9 (external, physical):\n'
    printf '   1:                  Microsoft Basic Data               32.0 GB    disk9s1\n' ;;
"info /dev/disk9")
    printf '   Device / Media Name:  SD Reader\n'
    printf '   Removable Media:      Removable\n' ;;
"info /dev/disk9s1")
    printf '   Mounted:              No\n' ;;
"list /dev/disk9")
    printf '/dev/disk9 (external, physical):\n'
    printf '   1:                  Microsoft Basic Data               32.0 GB    disk9s1\n' ;;
"mount /dev/disk9s1")
    mkdir -p "$vols/NO_NAME"
    cp -R "$CARDS/mixed/DCIM" "$vols/NO_NAME/DCIM"
    printf '%s\n' "$vols/NO_NAME" ;;
"eject "*|"unmount "*) exit 0 ;;
*) exit 1 ;;
esac
EOF
    chmod +x "$shim/diskutil"
    write_config "$root" ignored SD_CARD=auto >/dev/null
    (
        export SD_VOLUMES_DIR="$vols"
        export PATH="$shim:$PATH"
        $run "$root" --config "$root/config" --dry-run --no-eject >/dev/null
    )
}

# Two card-like volumes at once: refuse instead of guessing which one to read.
scenario_two_cards_present() {
    local run="$1" root="$2"
    local vols="$root/volumes"
    mkdir -p "$vols/NO_NAME/DCIM" "$vols/PHOTO/DCIM"
    cp "$CARDS/stage-1.png" "$vols/NO_NAME/DCIM/IMG_0001.RAF"
    cp "$CARDS/stage-2.png" "$vols/PHOTO/DCIM/IMG_0002.RAF"
    write_config "$root" ignored SD_CARD=auto >/dev/null
    (
        export SD_VOLUMES_DIR="$vols"
        $run "$root" --config "$root/config" --dry-run --no-eject >/dev/null
    )
}

scenario_nested_mount_ignored() {
    local run="$1" root="$2"
    local vols="$root/volumes"
    local img="$root/nested.dmg"
    local point="$vols/Drive/Share"
    mkdir -p "$point"
    if ! hdiutil create -size 20m -fs ExFAT -type SPARSE -volname NESTED "$img" \
        >/dev/null 2>&1; then
        printf 'hdiutil create failed\n' > "$WORK/$SCENARIO/.skipped"
        return 0
    fi
    if ! diskutil image attach "$img.sparseimage" --mountPoint "$point" \
        >/dev/null 2>&1; then
        rm -f "$img"*
        printf 'cannot mount a test volume here\n' > "$WORK/$SCENARIO/.skipped"
        return 0
    fi
    # A DCIM inside a filesystem mounted inside a volume (a cloud share) must
    # not count as a card: reading a stale server hangs for minutes. Drive has
    # no DCIM of its own, so both must report that no card was found.
    mkdir -p "$point/DCIM"
    cp "$CARDS/stage-1.png" "$point/DCIM/IMG_9001.RAF"
    write_config "$root" ignored SD_CARD=auto >/dev/null
    printf 'no SD card found\n' > "$WORK/$SCENARIO/.expect"
    (
        export SD_VOLUMES_DIR="$vols"
        $run "$root" --config "$root/config" --dry-run --no-eject >/dev/null
    )
    local status=$?
    diskutil unmount force "$point" >/dev/null 2>&1 || true
    rm -f "$img"*
    return $status
}

# Only safe when no card is mounted: auto-detection would otherwise import a
# real one into the scratch library.
scenario_no_card() {
    local run="$1" root="$2"
    if card_volume_present; then
        printf 'a card-like volume is mounted\n' > "$WORK/$SCENARIO/.skipped"
        return 0
    fi
    write_config "$root" ignored SD_CARD=auto >/dev/null
    $run "$root" --config "$root/config" --dry-run --no-eject >/dev/null
}

card_volume_present() {
    local v
    for v in /Volumes/*; do
        [ -d "$v" ] || continue
        [ "$(basename -- "$v")" = "Macintosh HD" ] && continue
        if find "$v" -maxdepth 2 -type d -iname DCIM -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

# Filenames and folders that break naive quoting: spaces, an apostrophe, a
# hash, a non-ASCII character, an upper-case extension and a nested folder.
scenario_weird_names() {
    local run="$1" root="$2"
    local d="$CARDS/weird/DCIM"
    mkdir -p "$d/Photos from John's card"
    make_png "$d/IMG 1234 copy.jpg" 11
    make_png "$d/John's photo #2.jpg" 12
    make_png "$d/IMG_0456ä.jpg" 13
    make_png "$d/shoot.JPG" 14
    make_png "$d/Photos from John's card/IMG_0777.jpg" 15
    make_png "$d/clip one.MOV" 16
    if [ -x "$EXIFTOOL" ]; then
        "$EXIFTOOL" -q -overwrite_original -Model="Odd Cam  X1" \
            -DateTimeOriginal="2023:07:08 09:10:11" \
            "$d"/*.jpg "$d"/*.JPG "$d/Photos from John's card"/*.jpg >/dev/null 2>&1
    fi
    write_config "$root" ignored >/dev/null
    $run "$root" --config "$root/config" --card "$d" >/dev/null
}

SCENARIOS="basic rerun deleted legacy_ledger dry_run dry_run_then_real no_backup
counter_source global_counter counter_start seeded_counter
existing_library_numbers multi_card missing_card empty_card no_exiftool
per_file_metadata batch_fallback videos flat_library folder_pattern_time
sd_card_config unmounted_card two_cards_present nested_mount_ignored
stale_lock busy_lock takeover no_card weird_names"

# -------------------------------------------------------------------- main --

build_swift
SWIFT="$(swift_bin)"
[ -x "$SWIFT" ] || { printf 'no swift binary\n' >&2; exit 1; }
fresh_cards

printf 'work dir: %s\n' "$WORK"
printf 'cards:    %s\n' "$CARDS"
printf '\n'

run_for() { # <impl> <scenario> -> prints report
    local impl="$1" scenario="$2"
    local root="$WORK/$scenario/$impl"
    rm -rf "$root"
    mkdir -p "$root"
    local rc=0
    case "$impl" in
        bash) RUN() { run_impl bash "$@"; } ;;
        *)    RUN() { run_impl swift "$@"; } ;;
    esac
    if ! declare -f "scenario_$scenario" >/dev/null; then
        printf 'FAIL  %s (no such scenario)\n' "$scenario"
        FAILURES=$((FAILURES + 1))
        continue
    fi
    "scenario_$scenario" RUN "$root" >/dev/null 2>&1 || rc=$?
    report "$root" "$rc"
}

for scenario in $SCENARIOS; do
    [ -z "$ONLY_SCENARIOS" ] || case " $ONLY_SCENARIOS " in *" $scenario "*) ;; *) continue ;; esac
    mkdir -p "$WORK/$scenario"
    rm -f "$WORK/$scenario/.skipped" "$WORK/$scenario/.expect"
    SCENARIO="$scenario"; export SCENARIO
    bash_report="$WORK/$scenario/bash-report.txt"
    swift_report="$WORK/$scenario/swift-report.txt"
    run_for bash "$scenario" > "$bash_report"
    run_for swift "$scenario" > "$swift_report"
    if [ -f "$WORK/$scenario/.skipped" ]; then
        printf 'SKIP  %s (%s)\n' "$scenario" "$(cat "$WORK/$scenario/.skipped")"
    elif [ -f "$WORK/$scenario/.expect" ] \
        && ! grep -qFf "$WORK/$scenario/.expect" "$bash_report"; then
        printf 'FAIL  %s (missing expected output)\n' "$scenario"
        sed 's/^/      want: /' "$WORK/$scenario/.expect"
        FAILURES=$((FAILURES + 1))
    elif diff -u "$bash_report" "$swift_report" > "$WORK/$scenario/diff.txt" 2>&1; then
        printf 'PASS  %s\n' "$scenario"
        [ "$VERBOSE" = 1 ] && sed 's/^/      /' "$bash_report"
    else
        printf 'FAIL  %s\n' "$scenario"
        sed 's/^/      /' "$WORK/$scenario/diff.txt"
        FAILURES=$((FAILURES + 1))
    fi
done

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'all scenarios match\n'
    exit 0
fi
printf '%s scenario(s) differ\n' "$FAILURES"
exit 1