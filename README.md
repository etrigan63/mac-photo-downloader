# SD Photo Downloader

Downloads photos and videos from a mounted SD card into your photo library,
organized by EXIF date and renamed by camera model.

* **Target folder** — photos copied to `TARGET_DIR/{YYYY}/{YYYY-MM-DD}` and
  renamed to `{Camera Model}-{YYYYMMDD}-{image number}.ext`
  (e.g. `Canon-EOS-R5-20260829-0001.JPG`).
* **Backup folder** — a second copy of each file under the same date
  subfolder structure, using the same renamed filenames as the target.
* Image numbers are sequential and tracked per camera model, so a third card
  from the same camera keeps counting without overwriting older photos.
* Runs from an Automator Quick Action, right-click an SD card volume in
  Finder → Quick Actions → **SD Photo Downloader**. Files already imported
  are skipped automatically, so re-running is safe.

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
| `COUNTER_PER_MODEL` | Separate number sequence per camera model (yes/no) |
| `PHOTO_EXTS` / `VIDEO_EXTS` | File extensions to import |
| `SD_CARD` | `auto`, or a fixed mount point like `/Volumes/CANON` |

Files with no usable EXIF date use the file's modification date; files with no
camera model get `UNKNOWN`.

## Usage

```sh
sd-photo-download.sh                                   # auto-detect the card
sd-photo-download.sh --card /Volumes/CANON             # explicit mount point
sd-photo-download.sh --dry-run                         # preview, write nothing
sd-photo-download.sh --config /path/to/config
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