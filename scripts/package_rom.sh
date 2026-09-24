#!/usr/bin/env bash
# package_rom.sh <merged_dir> <target_img_dir> <out_dir> <output_name> <bin_dir>
#
# Menyusun hasil merge menjadi paket fastboot-flashable + script flash.sh.
# Partisi dinamis (system/vendor/product/dll) sengaja TIDAK di-repack manual
# jadi satu super.img baru (lpmake perlu tahu persis ukuran & nama group
# super milik marble, yang bisa berbeda per build) -- sebagai gantinya
# di-flash satu per satu lewat fastbootd, yang menangani super secara
# otomatis di device.
set -euo pipefail

MERGED="${1:?}"
TARGET="${2:?}"
OUT="${3:?}"
NAME="${4:-marble_HyperOS_Port}"
BIN="${5:?}"
export PATH="$BIN:$PATH"

mkdir -p "$OUT"
PKGDIR="$OUT/${NAME}_pkg"
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR/images"

DYNAMIC_PARTS="system system_ext product mi_ext vendor vendor_dlkm odm odm_dlkm"
STATIC_PARTS="boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor"

echo "==> Menyusun image dinamis (nanti di-flash lewat fastbootd):"
for p in $DYNAMIC_PARTS; do
  if [ -f "$MERGED/${p}.img" ]; then
    cp "$MERGED/${p}.img" "$PKGDIR/images/"
    echo "    [OK] ${p}.img"
  fi
done

echo "==> Menyusun image statis (nanti di-flash lewat bootloader fastboot):"
for p in $STATIC_PARTS; do
  if [ -f "$MERGED/${p}.img" ]; then
    cp "$MERGED/${p}.img" "$PKGDIR/images/"
    echo "    [OK] ${p}.img"
  fi
done

# Dump metadata super.img target -- referensi manual saja (lihat README),
# tidak dipakai otomatis supaya tidak salah tebak ukuran/group.
if [ -f "$TARGET/super.img" ] && command -v lpdump >/dev/null 2>&1; then
  lpdump "$TARGET/super.img" > "$OUT/target_super_dump.txt" 2>&1 || true
fi

if [ -d "$TARGET/firmware-update" ]; then
  echo "==> Menyalin firmware-update (modem/wifi/kalibrasi) dari TARGET apa adanya"
  cp -r "$TARGET/firmware-update" "$PKGDIR/images/firmware-update"
fi

cp "$MERGED/PORT_MANIFEST.txt" "$PKGDIR/" 2>/dev/null || true

cat > "$PKGDIR/flash.sh" <<'FLASHEOF'
#!/usr/bin/env bash
# Flash hasil quick-port ini ke marble (POCO F5).
#
# SYARAT: bootloader sudah UNLOCKED, device dalam mode fastboot (bootloader)
# saat script ini dijalankan.
#
# Pemakaian: ./flash.sh [slot]     (slot default: a)
set -euo pipefail
cd "$(dirname "$0")/images"
SLOT="${1:-a}"

flash_static() {
  local img="$1" part="$2"
  [ -f "$img" ] && fastboot flash "${part}_${SLOT}" "$img"
}

flash_dynamic() {
  local img="$1" part="$2"
  [ -f "$img" ] && fastboot flash "$part" "$img"
}

echo "== Tahap 1/3: partisi statis (mode bootloader) =="
flash_static boot.img boot
flash_static vendor_boot.img vendor_boot
flash_static dtbo.img dtbo
flash_static vbmeta.img vbmeta
flash_static vbmeta_system.img vbmeta_system
flash_static vbmeta_vendor.img vbmeta_vendor

echo "== Masuk fastbootd untuk partisi dinamis =="
fastboot reboot fastboot
echo "Menunggu fastbootd siap..."
for _ in $(seq 1 30); do
  if fastboot getvar is-userspace 2>&1 | grep -qi yes; then
    break
  fi
  sleep 2
done

echo "== Tahap 2/3: partisi dinamis (mode fastbootd) =="
flash_dynamic system.img system
flash_dynamic system_ext.img system_ext
flash_dynamic product.img product
flash_dynamic mi_ext.img mi_ext
flash_dynamic vendor.img vendor
flash_dynamic vendor_dlkm.img vendor_dlkm
flash_dynamic odm.img odm
flash_dynamic odm_dlkm.img odm_dlkm

if [ -d firmware-update ]; then
  echo "== Tahap 3/3: firmware (modem/wifi/kalibrasi) =="
  for f in firmware-update/*.img; do
    [ -f "$f" ] || continue
    fastboot flash "$(basename "$f" .img)" "$f"
  done
fi

fastboot reboot bootloader
echo "Selesai. Kalau bootloop: 'fastboot -w' (WIPE DATA) lalu reboot ulang."
FLASHEOF
chmod +x "$PKGDIR/flash.sh"

echo "==> Membuat zip paket akhir"
( cd "$OUT" && zip -r "${NAME}.zip" "$(basename "$PKGDIR")" -x '*.DS_Store' > /dev/null )

echo "==> Selesai:"
ls -lh "$OUT/${NAME}.zip"
