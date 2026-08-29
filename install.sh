#!/bin/bash
# install.sh
#
# Installs SD Photo Downloader for the current user:
#   * copies sd-photo-download.sh to ~/.sd-photo-downloader/
#   * creates ~/.sd-photo-downloader/config from config.example on first run
#   * copies the Automator Quick Action to ~/Library/Services/
#
# After installing, open the workflow once:
#   open ~/Library/Services/"SD Photo Downloader.workflow"
#   -> "Install" when prompted, so it shows up in the Finder Services menu.
# Or run:  open "SD Photo Downloader.workflow"
#
# The Quick Action runs the script, passing any folder you right-clicked
# (e.g. the mounted SD card) as the card path. Right-click a volume in
# Finder -> Quick Actions -> SD Photo Downloader.

set -euo pipefail

SRC_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
DEST="$HOME/.sd-photo-downloader"
SERVICES="$HOME/Library/Services"

mkdir -p "$DEST"
cp -f "$SRC_DIR/sd-photo-download.sh" "$DEST/"
chmod +x "$DEST/sd-photo-download.sh"

if [ ! -f "$DEST/config" ]; then
  cp "$SRC_DIR/config.example" "$DEST/config"
  echo "Created $DEST/config - edit TARGET_DIR/BACKUP_DIR before your first run."
else
  echo "Keeping existing config: $DEST/config"
fi

mkdir -p "$SERVICES"
cp -Rf "$SRC_DIR/SD Photo Downloader.workflow" "$SERVICES/"
echo "Installed Automator action to: $SERVICES/SD Photo Downloader.workflow"

echo
echo "Next steps:"
echo "  1. Edit $DEST/config (set TARGET_DIR / BACKUP_DIR)"
echo "  2. Register the Quick Action, then click Install when prompted:"
echo "     open \"$SERVICES/SD Photo Downloader.workflow\""
echo "  3. Test without writing anything:"
echo "     $DEST/sd-photo-download.sh --dry-run"