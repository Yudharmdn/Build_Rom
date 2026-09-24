#!/usr/bin/env bash
# download_rom.sh <url> <dest_dir>
#
# Mengunduh satu paket ROM (fastboot .tgz/.zip atau recovery/OTA .zip) ke dest_dir.
# Menulis path file hasil unduhan ke dest_dir/.downloaded_path supaya script
# berikutnya (extract_rom.sh) tahu file mana yang harus dibongkar.
set -euo pipefail

URL="${1:?Usage: download_rom.sh <url> <dest_dir>}"
DEST="${2:?Usage: download_rom.sh <url> <dest_dir>}"

mkdir -p "$DEST"

FILENAME="$(basename "${URL%%\?*}")"
if [ -z "$FILENAME" ] || [ "$FILENAME" = "/" ]; then
  FILENAME="rom_download.bin"
fi

echo "==> Mengunduh: $URL"
echo "==> Simpan sebagai: $DEST/$FILENAME"

if command -v aria2c >/dev/null 2>&1; then
  aria2c -x 8 -s 8 -k 1M --summary-interval=15 --dir="$DEST" --out="$FILENAME" "$URL"
else
  curl -L --retry 5 --retry-delay 5 -o "$DEST/$FILENAME" "$URL"
fi

if [ ! -s "$DEST/$FILENAME" ]; then
  echo "!! Gagal: file hasil unduhan kosong atau tidak ada ($DEST/$FILENAME)" >&2
  exit 1
fi

echo "$DEST/$FILENAME" > "$DEST/.downloaded_path"
echo "==> Selesai:"
ls -lh "$DEST/$FILENAME"
