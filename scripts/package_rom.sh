#!/usr/bin/env bash
# package_rom.sh <merged_dir> <target_img_dir> <out_dir> <output_name> <bin_dir>
#
# Menyusun hasil merge menjadi ZIP flashable lewat CUSTOM RECOVERY (OrangeFox/
# TWRP) SAJA -- tidak lagi menghasilkan flash.sh berbasis fastboot/fastbootd.
#
# update-binary bergaya AnyKernel3 (script shell dengan shebang #!/sbin/sh,
# BUKAN edify biner) yang menjalankan update-script.sh. update-script.sh
# men-STREAM tiap image langsung dari dalam zip ke block device tujuan lewat
# `unzip -p | dd` -- TIDAK meng-extract seluruh image ke /tmp dulu, karena
# /tmp di recovery biasanya tmpfs kecil (jauh lebih kecil dari total image
# yang bisa >7GB untuk paket ini).
set -euo pipefail

MERGED="${1:?}"
TARGET="${2:?}"
OUT="${3:?}"
NAME="${4:-marble_HyperOS_Port}"
BIN="${5:?}"
export PATH="$BIN:$PATH"

mkdir -p "$OUT"
PKGDIR="$OUT/${NAME}_zip"
rm -rf "$PKGDIR"
mkdir -p "$PKGDIR/META-INF/com/google/android" "$PKGDIR/images"

DYNAMIC_PARTS="system system_ext product mi_ext vendor vendor_dlkm odm odm_dlkm"
STATIC_PARTS="boot vendor_boot dtbo vbmeta vbmeta_system vbmeta_vendor"

echo "==> Menyusun image dinamis (di-flash via /dev/block/mapper/<partisi>):"
for p in $DYNAMIC_PARTS; do
  if [ -f "$MERGED/${p}.img" ]; then
    cp "$MERGED/${p}.img" "$PKGDIR/images/"
    echo "    [OK] ${p}.img"
  fi
done

echo "==> Menyusun image statis (di-flash via /dev/block/bootdevice/by-name/<partisi><slot>):"
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

# Manifest nama firmware (dibaca update-script.sh saat flashing -- streaming
# tidak bisa "ls" isi zip di device, jadi daftar namanya disimpan di build time)
FW_LIST="$PKGDIR/firmware_list.txt"
: > "$FW_LIST"
if [ -d "$TARGET/firmware-update" ]; then
  echo "==> Menyalin firmware-update (modem/wifi/kalibrasi) dari TARGET apa adanya"
  cp -r "$TARGET/firmware-update" "$PKGDIR/images/firmware-update"
  ( cd "$PKGDIR/images/firmware-update" && for f in *.img; do [ -f "$f" ] && basename "$f" .img; done ) > "$FW_LIST" 2>/dev/null || true
  echo "    firmware terdaftar: $(wc -l < "$FW_LIST") item"
fi

cp "$MERGED/PORT_MANIFEST.txt" "$PKGDIR/" 2>/dev/null || true

# --- META-INF: sentinel updater-script (bukan edify sungguhan, cuma penanda) ---
cat > "$PKGDIR/META-INF/com/google/android/updater-script" <<'EOF'
# Port ROM flashable zip -- logika sebenarnya ada di update-binary +
# update-script.sh (script shell), BUKAN edify. File ini cuma penanda.
EOF

# --- update-script.sh: logika flashing sesungguhnya (jalan di /sbin/sh recovery) ---
cat > "$PKGDIR/update-script.sh" <<'SCRIPTEOF'
#!/sbin/sh
# update-script.sh <OUTFD> <ZIPFILE>
# Flash semua image lewat streaming (unzip -p | dd) -- TIDAK extract ke /tmp
# dulu, supaya tidak kehabisan ruang tmpfs recovery untuk paket besar.
OUTFD="$1"
ZIP="$2"

ui_print() {
  echo "ui_print $1" >> /proc/self/fd/"$OUTFD"
  echo "ui_print" >> /proc/self/fd/"$OUTFD"
}
set_progress() {
  echo "set_progress $1" >> /proc/self/fd/"$OUTFD"
}

BYNAME=/dev/block/bootdevice/by-name
ERRORS=0

SLOT="$(getprop ro.boot.slot_suffix 2>/dev/null)"
if [ -z "$SLOT" ]; then
  SLOT="$(grep -o 'androidboot\.slot_suffix=_[ab]' /proc/cmdline 2>/dev/null | cut -d= -f2)"
fi
[ -z "$SLOT" ] && SLOT="_a"
ui_print "Slot aktif terdeteksi: $SLOT"

zip_has_entry() {
  unzip -l "$ZIP" 2>/dev/null | grep -qF "$1"
}

zip_entry_size() {
  unzip -l "$ZIP" 2>/dev/null | awk -v e="$1" 'index($0,e){print $1; exit}'
}

flash_static() {
  entry="images/$1"
  dev="$BYNAME/${2}${SLOT}"
  if [ ! -e "$dev" ]; then
    ui_print "  [skip] $dev tidak ada"
    return 0
  fi
  if ! zip_has_entry "$entry"; then
    ui_print "  [skip] $entry tidak ada di paket"
    return 0
  fi
  ui_print "  Flashing $1 -> ${2}${SLOT}"
  if ! unzip -p "$ZIP" "$entry" | dd of="$dev" bs=4M 2>/dev/null; then
    ui_print "  !! GAGAL flash $1"
    ERRORS=$((ERRORS + 1))
  fi
}

flash_dynamic() {
  entry="images/$1"
  dev="/dev/block/mapper/$2"
  if [ ! -e "$dev" ]; then
    ui_print "  [skip] $dev tidak ada (partisi logis tidak ditemukan)"
    return 0
  fi
  if ! zip_has_entry "$entry"; then
    ui_print "  [skip] $entry tidak ada di paket"
    return 0
  fi
  devsize="$(blockdev --getsize64 "$dev" 2>/dev/null)"
  imgsize="$(zip_entry_size "$entry")"
  if [ -n "$devsize" ] && [ -n "$imgsize" ]; then
    if [ "$imgsize" -gt "$devsize" ] 2>/dev/null; then
      ui_print "  !! $1 (${imgsize}B) > partisi $2 (${devsize}B) -- DILEWATI"
      ui_print "  !! Partisi $2 perlu di-resize dulu (lihat README)"
      ERRORS=$((ERRORS + 1))
      return 1
    fi
  fi
  ui_print "  Flashing $1 -> $2 (dynamic)"
  if ! unzip -p "$ZIP" "$entry" | dd of="$dev" bs=4M 2>/dev/null; then
    ui_print "  !! GAGAL flash $1"
    ERRORS=$((ERRORS + 1))
  fi
}

ui_print "============================================"
ui_print " Port HyperOS -> marble (POCO F5)"
ui_print "============================================"

set_progress 0.05
ui_print "Tahap 1/3: partisi statis (boot/dtbo/vbmeta)"
flash_static boot.img boot
flash_static vendor_boot.img vendor_boot
flash_static dtbo.img dtbo
flash_static vbmeta.img vbmeta
flash_static vbmeta_system.img vbmeta_system
flash_static vbmeta_vendor.img vbmeta_vendor

set_progress 0.35
ui_print "Tahap 2/3: partisi dinamis (system/vendor/product/dll)"
flash_dynamic system.img system
flash_dynamic system_ext.img system_ext
flash_dynamic product.img product
flash_dynamic mi_ext.img mi_ext
flash_dynamic vendor.img vendor
flash_dynamic vendor_dlkm.img vendor_dlkm
flash_dynamic odm.img odm
flash_dynamic odm_dlkm.img odm_dlkm

set_progress 0.85
ui_print "Tahap 3/3: firmware (modem/wifi/kalibrasi)"
if zip_has_entry "firmware_list.txt"; then
  unzip -p "$ZIP" firmware_list.txt > /tmp/port_fw_list.txt 2>/dev/null || true
  while IFS= read -r fwname; do
    [ -z "$fwname" ] && continue
    flash_static "firmware-update/${fwname}.img" "$fwname"
  done < /tmp/port_fw_list.txt
  rm -f /tmp/port_fw_list.txt
else
  ui_print "  (tidak ada firmware_list.txt, lewati tahap ini)"
fi

set_progress 1.0
if [ "$ERRORS" -gt 0 ]; then
  ui_print "SELESAI dengan $ERRORS masalah -- CEK LOG DI ATAS sebelum reboot!"
  exit 1
fi
ui_print "Selesai tanpa error. Reboot ke system untuk uji boot."
exit 0
SCRIPTEOF
chmod +x "$PKGDIR/update-script.sh"

# --- update-binary: wrapper AnyKernel3-style, cuma extract update-script.sh
#     (kecil) ke /tmp -- sisanya di-stream langsung dari zip oleh script itu. ---
cat > "$PKGDIR/META-INF/com/google/android/update-binary" <<'BINEOF'
#!/sbin/sh
# update-binary gaya AnyKernel3 -- script shell, BUKAN edify biner.
OUTFD="$2"
ZIP="$3"

TMPDIR=/tmp/port_rom_zip
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
unzip -o "$ZIP" "update-script.sh" -d "$TMPDIR" >&2

sh "$TMPDIR/update-script.sh" "$OUTFD" "$ZIP"
RC=$?

rm -rf "$TMPDIR"
exit $RC
BINEOF
chmod +x "$PKGDIR/META-INF/com/google/android/update-binary"

echo "==> Membuat zip paket akhir (flashable lewat recovery)"
( cd "$PKGDIR" && zip -r -X "$OUT/${NAME}.zip" . -x '*.DS_Store' > /dev/null )
rm -rf "$PKGDIR"

echo "==> Selesai:"
ls -lh "$OUT/${NAME}.zip"
