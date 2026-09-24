#!/usr/bin/env bash
# extract_rom.sh <pkg_dir> <out_img_dir> <bin_dir>
#
# Membongkar paket yang sudah diunduh (lihat download_rom.sh) menjadi
# kumpulan file .img mentah (raw, bukan sparse) di out_img_dir. Menangani:
#   - paket fastboot (.tgz/.zip berisi image langsung, kadang sparse)
#   - paket recovery/OTA (.zip berisi payload.bin) -> pakai payload-dumper-go
#   - super.img dynamic partitions -> dibongkar lewat lpunpack
set -euo pipefail

SRC="${1:?Usage: extract_rom.sh <pkg_dir> <out_dir> <bin_dir>}"
OUT="${2:?}"
BIN="${3:?}"
export PATH="$BIN:$PATH"

if [ ! -f "$SRC/.downloaded_path" ]; then
  echo "!! Tidak ketemu $SRC/.downloaded_path — jalankan download_rom.sh dulu" >&2
  exit 1
fi
PKG="$(cat "$SRC/.downloaded_path")"

mkdir -p "$OUT"
WORK="$SRC/_unpacked"
mkdir -p "$WORK"

echo "==> Membongkar paket: $PKG"
case "$PKG" in
  *.tgz|*.tar.gz) tar -xzf "$PKG" -C "$WORK" ;;
  *.tar) tar -xf "$PKG" -C "$WORK" ;;
  *.zip) unzip -oq "$PKG" -d "$WORK" ;;
  *)
    echo "!! Format paket tidak dikenali (bukan .tgz/.tar.gz/.tar/.zip): $PKG" >&2
    exit 1
    ;;
esac

# Kadang isi tgz masih berupa images_*.zip bersarang di dalamnya — bongkar juga
find "$WORK" -maxdepth 2 -iname '*.zip' -print0 2>/dev/null \
  | while IFS= read -r -d '' z; do unzip -oq "$z" -d "$WORK"; done

# --- Kasus paket recovery/OTA: payload.bin ---
PAYLOAD="$(find "$WORK" -iname 'payload.bin' 2>/dev/null | head -n1 || true)"
if [ -n "$PAYLOAD" ]; then
  echo "==> Ditemukan payload.bin, mengekstrak dengan payload-dumper-go"
  mkdir -p "$WORK/payload_out"
  payload-dumper-go -o "$WORK/payload_out" "$PAYLOAD"
  find "$WORK/payload_out" -iname '*.img' -exec cp -n {} "$OUT/" \;
fi

# --- Kasus paket fastboot: image langsung ada (mentah atau sparse) ---
find "$WORK" -maxdepth 4 -iname '*.img' -exec cp -n {} "$OUT/" \;

# Salin folder firmware-update (modem/wifi/kalibrasi) apa adanya kalau ada
FWUP_DIR="$(find "$WORK" -maxdepth 4 -type d -iname 'firmware-update' 2>/dev/null | head -n1 || true)"
if [ -n "$FWUP_DIR" ]; then
  cp -r "$FWUP_DIR" "$OUT/firmware-update"
fi

# --- Konversi sparse image -> raw kalau perlu (simg2img gagal diam-diam kalau sudah raw) ---
shopt -s nullglob
for img in "$OUT"/*.img; do
  if simg2img "$img" "$img.rawtmp" 2>/dev/null && [ -s "$img.rawtmp" ]; then
    mv "$img.rawtmp" "$img"
    echo "    [sparse->raw] $(basename "$img")"
  else
    rm -f "$img.rawtmp"
  fi
done

# --- Bongkar super.img (dynamic partitions) kalau ada ---
if [ -f "$OUT/super.img" ]; then
  echo "==> super.img ditemukan, membongkar dengan lpunpack"
  mkdir -p "$OUT/super_unpacked"
  if ! lpunpack "$OUT/super.img" "$OUT/super_unpacked" 2>"$OUT/lpunpack.err"; then
    echo "    lpunpack tanpa --slot gagal, mencoba --slot=0 ..."
    lpunpack --slot=0 "$OUT/super.img" "$OUT/super_unpacked"
  fi
  find "$OUT/super_unpacked" -iname '*.img' -exec cp -n {} "$OUT/" \;
  # Normalisasi nama: sebagian lpunpack menghasilkan <part>_a.img / <part>_b.img
  for f in "$OUT"/*_a.img; do
    [ -e "$f" ] || continue
    base="$(basename "$f" _a.img)"
    [ -f "$OUT/${base}.img" ] || cp "$f" "$OUT/${base}.img"
  done
fi
shopt -u nullglob

echo "==> Isi $OUT:"
ls -lh "$OUT"
