#!/usr/bin/env bash
# port_rom.sh <donor_img_dir> <target_img_dir> <merged_out_dir> <bin_dir> <port_mode> <disable_avb>
#
# Logika inti quick-port:
#   - Dari DONOR  : system, system_ext, product, mi_ext (lapisan OS/UI HyperOS)
#   - Dari TARGET : vendor, vendor_dlkm, odm, odm_dlkm, boot, vendor_boot,
#                   dtbo, persist (semua yang terikat hardware marble)
#   - vbmeta*     : basis dari TARGET, lalu verifikasi di-disable (kalau diminta)
#
# port_mode=system_vendor akan mengambil vendor* dari DONOR juga — HANYA aman
# kalau donor & marble satu platform chipset yang identik. Untuk donor dari
# device/chipset lain (mis. build flagship yang di-quick-port ke marble),
# WAJIB pakai system_only.
set -euo pipefail

DONOR="${1:?}"
TARGET="${2:?}"
MERGED="${3:?}"
BIN="${4:?}"
PORT_MODE="${5:-system_only}"
DISABLE_AVB="${6:-true}"
export PATH="$BIN:$PATH"

mkdir -p "$MERGED"

DONOR_PARTS="system system_ext product mi_ext"
TARGET_PARTS="vendor vendor_dlkm odm odm_dlkm boot vendor_boot dtbo persist"
VBMETA_PARTS="vbmeta vbmeta_system vbmeta_vendor"

copy_if_exists() {
  local name="$1" src="$2" dst="$3"
  if [ -f "$src/${name}.img" ]; then
    cp -f "$src/${name}.img" "$dst/${name}.img"
    echo "    [OK]   ${name}.img  <-  $(basename "$src")"
    return 0
  fi
  echo "    [skip] ${name}.img tidak ada di $(basename "$src")"
  return 1
}

echo "==> Mode porting: $PORT_MODE"
echo "==> Menyalin partisi dari DONOR (lapisan HyperOS/UI):"
for p in $DONOR_PARTS; do
  copy_if_exists "$p" "$DONOR" "$MERGED" || true
done

echo "==> Menyalin partisi dari TARGET/marble (lapisan hardware):"
for p in $TARGET_PARTS; do
  copy_if_exists "$p" "$TARGET" "$MERGED" || true
done

if [ "$PORT_MODE" = "system_vendor" ]; then
  echo "==> port_mode=system_vendor: mengambil vendor* dari DONOR"
  echo "    (pastikan donor & marble memang satu platform chipset yang sama!)"
  copy_if_exists "vendor" "$DONOR" "$MERGED" || true
  copy_if_exists "vendor_dlkm" "$DONOR" "$MERGED" || true
fi

echo "==> Menyalin vbmeta* dari TARGET sebagai basis:"
for p in $VBMETA_PARTS; do
  copy_if_exists "$p" "$TARGET" "$MERGED" || true
done

if [ "$DISABLE_AVB" = "true" ]; then
  echo "==> Menonaktifkan verifikasi AVB (hashtree + verification) pada semua vbmeta*.img"
  shopt -s nullglob
  for vb in "$MERGED"/vbmeta*.img; do
    avbtool make_vbmeta_image --flags 3 --padding_size 4096 --algorithm NONE --output "$vb.new"
    mv "$vb.new" "$vb"
    echo "    [AVB] $(basename "$vb") -> verification+hashtree disabled"
  done
  shopt -u nullglob
  if [ ! -f "$MERGED/vbmeta.img" ]; then
    echo "==> Tidak ada vbmeta.img dari target, membuat vbmeta.img kosong (disabled) sebagai jaring pengaman"
    avbtool make_vbmeta_image --flags 3 --padding_size 4096 --algorithm NONE --output "$MERGED/vbmeta.img"
  fi
fi

{
  echo "Port manifest"
  echo "============="
  echo "Mode        : $PORT_MODE"
  echo "AVB disable : $DISABLE_AVB"
  echo "Dari DONOR  : $DONOR_PARTS"
  echo "Dari TARGET : $TARGET_PARTS $VBMETA_PARTS"
  echo "Dibuat      : $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
} > "$MERGED/PORT_MANIFEST.txt"

echo "==> Hasil merge di $MERGED:"
ls -lh "$MERGED"
