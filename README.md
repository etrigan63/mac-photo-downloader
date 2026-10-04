# SD Photo Downloader

Downloads photos and videos from a mounted SD card into your photo library,
organized by EXIF date and renamed by camera model.

* **Target folder** — photos copied to `TARGET_DIR/{YYYY}/{YYYY-MM-DD}` and
  renamed to `{Camera Model}-{YYYYMMDD}-{image number}.ext`
  (e.g. `Canon-EOS-R5-20260829-0001.JPG`).
* **Backup folder** — a second copy of each file under the same date
  subfolder structure, using the same renamed filenames as the target.
* The image number is taken from the camera file name (the digits just before
  the extension, e.g. `_DSF5099.RAF` → `5099`), so a RAW + HEIF pair keeps the
  same number across both cards. Files without trailing digits in their name
  fall back to a sequential counter tracked per camera model.
* Ships in two flavours with identical behaviour: a **native macOS app**
  (`sd-photo-download.swift`, progress window) and the original **shell script**
  (`sd-photo-download.sh`, terminal bar). `./test-parity.sh` proves they agree
  file for file.
* Runs from an Automator Quick Action, right-click an SD card volume in
  Finder → Quick Actions → **SD Photo Downloader**. Re-running is safe:
  files still in the library are skipped, while files you deleted from the
  library are re-imported on the next run. The card is ejected automatically
  when a run finishes successfully (`--no-eject` to keep it mounted).

## Requirements

* macOS with **exiftool** installed: `brew install exiftool`
* Xcode Command Line Tools for the native build: `xcode-select --install`
  (the shell version has no build step)

## Install

```sh
./install.sh
```

This copies the script to `~/.sd-photo-downloader/`, builds the native binary
next to it (if `swiftc` is available), creates a config from `config.example`
(edit it first!), and installs the Automator action to `~/Library/Services/`.

You get two commands, same behaviour, pick either:

| Command | Use it for |
|---------|-----------|
| `~/.sd-photo-downloader/sd-photo-download` | the native build: add `--gui` for a progress window |
| `~/.sd-photo-downloader/sd-photo-download.sh` | the shell fallback, no build step needed |

Both read the first config that exists: `$SD_CARD_DOWNLOADER_CONFIG`, a `config`
next to the binary, `~/.sd-photo-downloader/config`, then
`~/Library/Application Support/SD Photo Downloader/config`.

### The app bundle

```sh
./build-app.sh                # -> ./SD Photo Downloader.app
```

A native double-clickable app (`LSUIElement`, so no Dock icon) that shows the
progress window, then closes itself shortly after reporting the result. It is
what the Stream Deck *Open* action launches. Its icon is generated into
`resources/AppIcon.icns` by `build-app.sh` from `resources/sd-card-fill.svg`,
which is a [Remix Icon](https://remixicon.com/) `sd-card-fill` glyph (Apache
2.0). Extra arguments pass through:

```sh
open -Wn "SD Photo Downloader.app" --args --card /Volumes/NO_NAME --dry-run
```

Open the workflow once to register the Quick Action:

```sh
open ~/Library/Services/"SD Photo Downloader.workflow"   # click Install
```

Then right-click your mounted SD card in Finder → *Quick Actions* → *SD Photo
Downloader*.

## Configuration

Edit `~/.sd-photo-downloader/config` (the format is `KEY=VALUE`, see
`config.example` for every option):

| Key | Purpose |
|-----|---------|
| `TARGET_DIR` | Destination photo library (subfolders auto-created) |
| `BACKUP_DIR` | Optional original-file backup (leave blank to disable) |
| `EXIFTOOL` | Path to exiftool (auto-detected if blank) |
| `FOLDER_PATTERN` | Subfolder layout, e.g. `%Y/%Y-%m-%d` or `{YYYY}/{YYYY-MM-DD}` |
| `COUNTER_DIGITS` | Zero-padding for the image number (default 4) |
| `NUMBER_SOURCE` | `exif` (digits before extension in the filename, default) or `counter` (sequential) |
| `COUNTER_PER_MODEL` | Separate number sequence per camera model (yes/no) |
| `PHOTO_EXTS` / `VIDEO_EXTS` | File extensions to import |
| `SD_CARD` | `auto`, or a fixed mount point like `/Volumes/CANON` |
| `EJECT_CARD` | Eject the card when done (`yes`/`no`, override with `--no-eject`) |
| `NOTIFY` | Notification Center banners: started, result, errors (`yes`/`no`) |
| `NOTIFY_PROGRESS` | Refresh the banner every N% while importing (default 25, `0` = only start/finish) |
| `PROGRESS_BAR` | In-place terminal progress bar when stdout is a terminal (`yes`/`no`) |
| `PROGRESS_FILE` | Progress state file for other tools (default `$STATE_DIR/progress.txt`) |
| `EXIF_BATCH` | Read EXIF in one batched pass (default `yes`; falls back to per-file reads) |

Files with no usable EXIF date use the file's modification date; files with no
camera model get `UNKNOWN`.

## Finding the card

With `SD_CARD=auto` the tool looks for a volume under `/Volumes` that contains a
`DCIM` folder (directly or one level down). If it finds none, it asks
`diskutil` for external disks that report `Removable Media: Removable`, mounts
any that are unmounted, and looks again — so a card you just inserted works even
if macOS has not mounted it yet. Fixed disks (external SSDs, NAS shares) are
never mounted. Two card-like volumes at once is an error rather than a guess; pass
one with `--card`.

`SD_VOLUMES_DIR` overrides the volumes root. It exists for `test-parity.sh`, which
uses it together with a fake `diskutil` to exercise the mount and two-card paths
without touching real hardware.

The walk skips symlinks and anything mounted *inside* a volume, so a cloud share
such as a Nextcloud or Google Drive folder mounted under `/Volumes/BigData/Cloud`
is never read. Servers that are slow or offline can take minutes to answer, and
one of those inside a volume root used to hang detection until it timed out.

## Two runs at once

Both implementations keep `$STATE_DIR/run.lock` while importing. A second launch
does not queue behind the first: it asks the running instance to stop between
files and takes the lock over, and the instance it replaced prints what it was
doing. A lock whose owner is gone is treated as stale and simply cleared, so a
crashed or force-quit run never blocks the next one. If the first instance is
still inside a slow batch, the second one waits `LOCK_WAIT_SECONDS` (default 15)
and then exits with `another import is already in progress`. Set the variable to
`0` to fail immediately instead.

Only one import ever runs, so the GUI does not need the same protection for a
repeat press: a press while the app is still open starts a fresh run instead.

## Performance

EXIF metadata is read in a single batched `exiftool` pass over the card and
flattened into a table the import loop reads from, instead of spawning exiftool
three to six times per file. On a 200-file card that is **17s versus 92s**
end to end (5.3x); the remaining cost is copying, plus the per-file hashing
used for duplicate detection. Set `EXIF_BATCH=no` to force the old per-file
path — it produces identical filenames, just slower. That path reads tags with
exiftool's tab-separated output rather than `-json`, so the fallback still works
if a batched pass comes back empty (an exiftool too old for `-json`, say).

The native build does the same work without the per-file subprocesses, so on the
same 200-file card it finishes in **3.2s versus 29.9s** for the batched shell
version (~9x), with byte-identical results. The shell version spends most of
that time forking helpers: one `date` per log line, plus `tr`, `tail`, `md5sum`
and `mkdir` per file.

## Usage

```sh
sd-photo-download --gui                                # native, progress window
sd-photo-download                                      # native, terminal output
sd-photo-download.sh                                   # shell version (same flags)
```

Shared flags (both implementations):

```sh
--card PATH          # repeatable; import from PATH instead of auto-detecting
--dry-run            # preview only: write nothing, leave counters/ledger alone
--no-eject           # import but keep the card mounted
--config FILE        # use FILE instead of the discovered config
--gui / --no-gui     # native only: force the progress window on or off
```

A bare path is also accepted, so folders dropped on an Automator action still
work.

Progress is logged to `~/Library/Application Support/SD Photo Downloader/run.log`.

## Progress and status

Three surfaces report progress, so you can tell what is happening and when it
finished regardless of how the script was launched:

1. **Terminal progress bar** — when you run it in a terminal, a live bar is
   redrawn in place:
   ```
   [######################--------]  75% 9/12 Fujifilm-GFX100RF-20260829-0006.raf (imported)
   ```
   When stdout is not a terminal (log file, pipe, Shortcut), the bar is
   suppressed and normal per-file log lines are printed instead, so nothing
   ends up with stray `\r` characters.
2. **Progress file** — `progress.txt` is rewritten after every file so another
   tool can follow along:
   ```
   status=running pct=75 done=9 total=12 message=Fujifilm-GFX100RF-20260829-0006.raf
   ```
   `status` is `starting`, `running`, `done`, or `error`.
3. **Notification Center banners** — `Importing from CARD...`, then
   `Importing: 75% (9/12)` every `NOTIFY_PROGRESS` percent, then
   `Done: 12 imported, 0 skipped.` Errors post `Failed: <reason>` and exit
   non-zero, so a failure is never silent.

## Tests

`./test-parity.sh` runs both implementations over the same fixtures and diffs
everything observable: target and backup names, file contents, counters, ledger
lines, per-file import/skip decisions, the full terminal output, and exit codes.

```sh
./test-parity.sh                 # all scenarios
./test-parity.sh basic deleted   # only these
./test-parity.sh -v basic        # print the report for a passing scenario
```

Scenarios cover re-runs, deleted files re-importing, legacy hash-only ledger
lines, dry runs, missing backups, counter sources and seeding, existing library
numbers, multiple cards, missing/empty cards, missing exiftool, a failed batched
metadata pass, videos, a configured `SD_CARD`, awkward filenames (spaces,
apostrophes, non-ASCII, upper-case extensions), and flat or time-based folder
patterns. Pass `WORK=/some/dir` to keep the reports.

Locking has its own scenarios: `stale_lock`, `busy_lock`, and `takeover`, which
runs both implementations against each other at once. `nested_mount_ignored`
mounts a real disk image inside a volume and fails if a `DCIM` behind that mount
is mistaken for a card; it reports `SKIP` on machines that cannot mount a
volume into a subdirectory.

The auto-detection scenario refuses to run while a card is mounted, so the suite
can never import a real card into a scratch library.

## Manually wiring up Automator (alternative to the bundle)

1. Open **Automator** → *New Document* → *Quick Action*.
2. *Workflow receives current:* **folders** in **Finder**.
3. Add a **Run Shell Shell Script** action:
   - Shell: `/bin/bash`
   - Pass input: **as arguments**
   - Command:
     ```bash
     exec "$HOME/.sd-photo-downloader/sd-photo-download.sh" "$@"
     ```
4. Save as **SD Photo Downloader**; then right-click a card volume in Finder
   → *Quick Actions* → **SD Photo Downloader**.

## Stream Deck

**Option A (recommended): the app.** Run `./build-app.sh`, then add an *Open*
action in Stream Deck and pick `SD Photo Downloader.app`. Each press shows the
progress window, posts the notification banners, ejects the card and exits.

The window stays up for five seconds after a run so the result is readable, and
the app quits on its own. Pressing the button again during those five seconds
starts another run rather than doing nothing; a press while an import is still
running is ignored, because the first one is already doing the work.

**Option B: a macOS Shortcut.** The Stream Deck's native *Shortcuts* action
launches a Shortcut whose **Run Shell Script** action calls either build, and
the status banners (see `NOTIFY` above) report progress without a terminal.

1. In the **Shortcuts** app: *New Shortcut* → name it `Import SD Photos`.
2. Add a **Run Shell Script** action:
   - Shell: `/bin/bash`
   - Input: `None`
   - Script (the action runs through a shell, so `$HOME` expands; swap in `--gui`
     for the progress window):
     ```bash
     "$HOME/.sd-photo-downloader/sd-photo-download" --gui
     ```
3. Run it once from Shortcuts with a card mounted to approve the "allow
   running scripts" prompt; the action shows the script's output inline and
   the progress banners appear in Notification Center.
4. In **Stream Deck**: add the **Shortcuts** action → pick `Import SD Photos`.
   If it isn't listed yet, run the shortcut once and restart Stream Deck.

Notes:

* To watch the shell version's **terminal progress bar** instead of banners,
  change the Shortcut's Run Shell Script action to open a Terminal window:
  ```bash
  osascript -e "tell application \"Terminal\" to do script \"$HOME/.sd-photo-downloader/sd-photo-download.sh; echo; echo Finished - press Return to close this window; read\""
  ```
  Replace `read` with `exit` if you'd rather the window close itself when done.
* Third-party "Run Shell Script" Stream Deck plugins often launch the command
  without a shell, so `$HOME`, quotes, and environment variables are not
  expanded. If you use one, use the absolute path with explicit `bash` as above
  (or an `Open` action pointing at the `.app` from `build-app.sh`).
* Allow notifications for Shortcuts in System Settings → Notifications so the
  status banners are visible.