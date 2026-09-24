#!/usr/bin/env bash
# patch_fstab.sh <merged_dir> <bin_dir> <enabled>
#
# Mem-patch fstab.* di dalam vendor.img (dan odm.img kalau ada) hasil merge:
#   - forceencrypt=/fileencryption=  -> encryptable=footer (tidak wajib enkripsi saat boot)
#   - flag "verify"                  -> dihapus
#   - flag mount "ro"                -> "rw" (khusus baris system/vendor/product/odm)
#
# Mendukung vendor image bertipe EROFS (extract+rebuild lewat erofs-utils)
# maupun ext4 (edit in-place lewat debugfs, tanpa perlu loop-mount/sudo).
# enabled=false -> script tidak melakukan apa-apa (exit 0).
set -euo pipefail

MERGED="${1:?Usage: patch_fstab.sh <merged_dir> <bin_dir> <enabled>}"
BIN="${2:?}"
ENABLED="${3:-true}"
export PATH="$BIN:$PATH"

if [ "$ENABLED" != "true" ]; then
  echo "==> patch_fstab.sh dilewati (patch_fstab=false)"
  exit 0
fi

detect_fs() {
  local img="$1"
  if fsck.erofs -d0 "$img" >/dev/null 2>&1; then
    echo erofs
  elif dumpe2fs -h "$img" >/dev/null 2>&1; then
    echo ext4
  else
    echo unknown
  fi
}

# Mem-patch satu file fstab teks di tempat. Cetak "changed" atau "unchanged" ke stdout.
patch_fstab_text() {
  local f="$1"
  python3 - "$f" <<'PYEOF'
import re, sys
path = sys.argv[1]
targets = {"/system", "/vendor", "/product", "/odm", "/system_ext", "/mi_ext"}
changed = False
out_lines = []
with open(path) as fh:
    for line in fh:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            out_lines.append(line)
            continue
        cols = stripped.split()
        if len(cols) < 4:
            out_lines.append(line)
            continue
        mnt_base = re.sub(r'(_a|_b)$', '', cols[1])
        is_target = mnt_base in targets or cols[0] in targets
        new_cols = []
        for c in cols:
            c2 = re.sub(r'forceencrypt=\S+', 'encryptable=footer', c)
            c2 = re.sub(r'fileencryption=\S+', 'encryptable=footer', c2)
            if c2 != c:
                changed = True
            new_cols.append(c2)
        cols = new_cols
        if is_target and len(cols) >= 4:
            flags = cols[3].split(',')
            new_flags = []
            for fl in flags:
                if fl == 'ro':
                    new_flags.append('rw')
                    changed = True
                elif fl == 'verify':
                    changed = True
                    continue
                else:
                    new_flags.append(fl)
            cols[3] = ','.join(new_flags)
        out_lines.append(' '.join(cols) + '\n')
if changed:
    with open(path, 'w') as fh:
        fh.writelines(out_lines)
print('changed' if changed else 'unchanged')
PYEOF
}

process_image() {
  local img="$1"
  [ -f "$img" ] || return 0
  local base fstype found=0
  base="$(basename "$img")"
  fstype="$(detect_fs "$img")"
  echo "==> $base: filesystem terdeteksi = $fstype"

  case "$fstype" in
    erofs)
      local ex="${img}.extract"
      rm -rf "$ex"
      fsck.erofs "--extract=$ex" "$img" >/dev/null 2>&1 || true
      while IFS= read -r -d '' f; do
        found=1
        local result
        result="$(patch_fstab_text "$f")"
        echo "    [$result] $(basename "$f")"
      done < <(find "$ex" -maxdepth 3 -iname 'fstab.*' -print0 2>/dev/null)
      if [ "$found" = "1" ]; then
        rm -f "$img"
        mkfs.erofs -zlz4hc "$img" "$ex" >/dev/null
        echo "    [rebuild] $base ditulis ulang sebagai EROFS baru"
      else
        echo "    [skip] tidak ada fstab.* ditemukan di $base"
      fi
      rm -rf "$ex"
      ;;
    ext4)
      local tmpd
      tmpd="$(mktemp -d)"
      debugfs -R "rdump /etc $tmpd" "$img" >/dev/null 2>&1 || true
      while IFS= read -r -d '' f; do
        found=1
        local result rel
        result="$(patch_fstab_text "$f")"
        rel="etc/$(basename "$f")"
        if [ "$result" = "changed" ]; then
          debugfs -w -R "rm $rel" "$img" >/dev/null 2>&1 || true
          debugfs -w -R "write $f $rel" "$img" >/dev/null 2>&1
        fi
        echo "    [$result] $rel"
      done < <(find "$tmpd" -maxdepth 2 -iname 'fstab.*' -print0 2>/dev/null)
      if [ "$found" = "0" ]; then
        echo "    [skip] tidak ada fstab.* di etc/ pada $base"
      fi
      rm -rf "$tmpd"
      ;;
    *)
      echo "    [skip] tipe filesystem $base tidak dikenali (bukan erofs/ext4) -- lewati, cek manual"
      ;;
  esac
}

echo "==> Patch fstab: nonaktifkan forceencrypt/fileencryption + set rw (system/vendor/product/odm)"
process_image "$MERGED/vendor.img"
process_image "$MERGED/odm.img"

if [ -f "$MERGED/PORT_MANIFEST.txt" ]; then
  echo "fstab patched  : forceencrypt/fileencryption off, rw system/vendor/product/odm" >> "$MERGED/PORT_MANIFEST.txt"
fi

echo "==> Selesai patch fstab"
echo "    Catatan: kalau device tetap force-encrypt setelah ini, kemungkinan fstab"
echo "    yang aktif ada di ramdisk boot/vendor_boot (bukan di vendor.img) -- belum"
echo "    di-cover script ini, perlu extract ramdisk manual."
