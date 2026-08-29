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
* Runs from an Automator Quick Action, right-click an SD card volume in
  Finder → Quick Actions → **SD Photo Downloader**. Re-running is safe:
  files still in the library are skipped, while files you deleted from the
  library are re-imported on the next run. The card is ejected automatically
  when a run finishes successfully (`--no-eject` to keep it mounted).

## Requirements

* macOS with **exiftool** installed: `brew install exiftool`

## Install

```sh
./install.sh
```

This copies the script to `~/.sd-photo-downloader/`, creates a config from
`config.example` (edit it first!), and installs the Automator action to
`~/Library/Services/`.

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

Files with no usable EXIF date use the file's modification date; files with no
camera model get `UNKNOWN`.

## Usage

```sh
sd-photo-download.sh                                   # auto-detect the card
sd-photo-download.sh --card /Volumes/CANON             # explicit mount point
sd-photo-download.sh --dry-run                         # preview, write nothing, don't eject
sd-photo-download.sh --config /path/to/config
sd-photo-download.sh --no-eject                        # import but keep the card mounted
```

Progress is logged to `~/Library/Application Support/SD Photo Downloader/run.log`.

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

The most reliable way to trigger the import from a Stream Deck button is a
macOS **Shortcut** with a **Run Shell Script** action — the Stream Deck's
native **Shortcuts** action launches it, and the script reports its own status
banners (see `NOTIFY` above) so you get feedback without a terminal.

1. In the **Shortcuts** app: *New Shortcut* → name it `Import SD Photos`.
2. Add a **Run Shell Script** action:
   - Shell: `/bin/bash`
   - Input: `None`
   - Script:
     ```bash
     /bin/bash /Users/guru/.sd-photo-downloader/sd-photo-download.sh
     ```
3. Run it once from Shortcuts with a card mounted to approve the "allow
   running scripts" prompt; the action shows the script's output inline and
   the progress banners appear in Notification Center.
4. In **Stream Deck**: add the **Shortcuts** action → pick `Import SD Photos`.
   If it isn't listed yet, run the shortcut once and restart Stream Deck.

Notes:

* Third-party "Run Shell Script" Stream Deck plugins often launch the command
  without a shell, so `$HOME`, quotes, and environment variables are not
  expanded. If you use one, use the absolute path with explicit `bash` as above
  (or an `Open` action pointing at the `.app` from `build-app.sh`).
* Allow notifications for Shortcuts in System Settings → Notifications so the
  status banners are visible.