#!/usr/bin/env bash
# patch_fstab.sh <merged_dir> <bin_dir> <enabled>
#
# Mem-patch fstab.* di dalam vendor.img (dan odm.img kalau ada) hasil merge:
#   - forceencrypt=/fileencryption=  -> encryptable=footer (tidak wajib enkripsi saat boot)
#   - flag "verify"                  -> dihapus
#   - flag mount "ro"                -> "rw" (khusus baris system/vendor/product/odm)
#
# Output SELALU EXT4, apapun format sumbernya:
#   - Sumber EROFS -> di-extract, fstab dipatch, lalu dibangun ulang sebagai EXT4
#     baru (mke2fs -d). Label SELinux di-reapply best-effort lewat `setfiles`
#     memakai vendor_file_contexts yang ada di dalam image itu sendiri (fsck.erofs
#     versi Ubuntu/apt TIDAK punya flag extract-xattr, jadi xattr asli tidak ikut
#     ke-extract -- lihat relabel_selinux_best_effort).
#   - Sumber EXT4  -> edit in-place lewat debugfs (tanpa loop-mount/sudo), tetap
#     EXT4. Xattr security.selinux file fstab yang ditulis ulang disalin manual
#     (ea_get sebelum rm, ea_set sesudah write) supaya labelnya tidak hilang.
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

def dedupe(tokens):
    seen = False
    result = []
    for t in tokens:
        if t == 'encryptable=footer':
            if seen:
                continue
            seen = True
        result.append(t)
    return result

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
        for idx, c in enumerate(cols):
            new_tokens = []
            for t in c.split(','):
                t2 = t
                if t.startswith('forceencrypt=') or t.startswith('fileencryption='):
                    t2 = 'encryptable=footer'
                elif idx == 3 and is_target and t == 'ro':
                    t2 = 'rw'
                elif idx == 3 and is_target and t == 'verify':
                    changed = True
                    continue
                if t2 != t:
                    changed = True
                new_tokens.append(t2)
            new_cols.append(','.join(dedupe(new_tokens)))
        out_lines.append(' '.join(new_cols) + '\n')
if changed:
    with open(path, 'w') as fh:
        fh.writelines(out_lines)
print('changed' if changed else 'unchanged')
PYEOF
}

# Membangun image EXT4 baru berisi isi direktori $1, ditulis ke path $2, label $3.
# Ukuran dihitung dari isi + margin (25% + 32MB) untuk overhead metadata ext4,
# lalu di-sparse-kan (img2simg) supaya konsisten dengan image lain yang di-flash
# lewat fastboot/fastbootd. mke2fs -d (e2fsprogs >= 1.43-an) ikut menyalin xattr
# (termasuk security.selinux) dari direktori sumber -- sudah diuji manual dan
# terkonfirmasi jalan di e2fsprogs 1.47.
build_ext4_from_dir() {
  local srcdir="$1" outimg="$2" label="$3"
  local size_kb margin_kb total_kb
  size_kb=$(du -sk "$srcdir" | cut -f1)
  margin_kb=$(( size_kb / 4 + 32768 ))
  total_kb=$(( size_kb + margin_kb ))
  echo "    [ext4] isi ${size_kb}KB, image dialokasikan ${total_kb}KB"
  truncate -s "${total_kb}K" "$outimg.raw"
  mke2fs -t ext4 -F -O ^has_journal -d "$srcdir" -L "$label" -m 0 "$outimg.raw" >/dev/null
  if img2simg "$outimg.raw" "$outimg" 2>/dev/null; then
    rm -f "$outimg.raw"
  else
    mv "$outimg.raw" "$outimg"
  fi
}

# Best-effort: cari *_file_contexts di dalam direktori hasil extract ($1) dan
# pakai `setfiles` untuk melabeli ulang seluruh isinya, dengan $2 (mis. "vendor")
# sebagai nama mount point supaya pola seperti "/vendor/..." di file_contexts
# cocok. Tidak fatal kalau gagal/tidak ketemu -- fsck.erofs versi apt/Ubuntu
# tidak punya opsi extract-xattr, jadi tanpa langkah ini file di EXT4 hasil
# konversi akan TANPA label SELinux sama sekali (bisa kena "avc: denied" saat
# SELinux enforcing).
relabel_selinux_best_effort() {
  local root="$1" mountname="$2"
  if ! command -v setfiles >/dev/null 2>&1; then
    echo "    [selinux] setfiles tidak tersedia, lewati relabel (best-effort)"
    return 0
  fi
  local fc_rel
  fc_rel="$(find "$root/etc/selinux" -maxdepth 1 -iname '*file_contexts*' ! -iname '*.sha256' 2>/dev/null | head -n1 || true)"
  if [ -z "$fc_rel" ]; then
    echo "    [selinux] tidak ketemu *_file_contexts di $root/etc/selinux, lewati relabel"
    return 0
  fi
  fc_rel="${fc_rel#"$root"/}"

  local wrap
  wrap="$(mktemp -d)"
  mv "$root" "$wrap/$mountname"
  if setfiles -r "$wrap" "$wrap/$mountname/$fc_rel" "$wrap/$mountname" >/dev/null 2>&1; then
    echo "    [selinux] relabel dari $fc_rel berhasil (best-effort)"
  else
    echo "    [selinux] setfiles gagal/sebagian -- EXT4 hasil mungkin sebagian tanpa label"
  fi
  mv "$wrap/$mountname" "$root"
  rmdir "$wrap" 2>/dev/null || true
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
      # fsck.erofs versi apt/Ubuntu (1.7.x) TIDAK punya flag --xattrs/--no-xattrs
      # (baru ada di versi lebih baru) -- xattr memang tidak ikut ke-extract di sini,
      # makanya ada relabel_selinux_best_effort di bawah sebagai kompensasi.
      fsck.erofs "--extract=$ex" "$img" >/dev/null 2>&1 || true
      while IFS= read -r -d '' f; do
        found=1
        local result
        result="$(patch_fstab_text "$f")"
        echo "    [$result] $(basename "$f")"
      done < <(find "$ex" -maxdepth 3 -iname 'fstab.*' -print0 2>/dev/null)
      if [ "$found" = "1" ]; then
        relabel_selinux_best_effort "$ex" "${base%.img}"
        rm -f "$img"
        build_ext4_from_dir "$ex" "$img" "${base%.img}"
        echo "    [rebuild] $base: EROFS -> EXT4"
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
        local result rel oldctx
        result="$(patch_fstab_text "$f")"
        rel="etc/$(basename "$f")"
        if [ "$result" = "changed" ]; then
          # Simpan label SELinux file lama sebelum ditimpa, supaya bisa dipasang
          # lagi -- debugfs "write" membuat inode baru dan TIDAK mewarisi xattr
          # file yang di-rm (sudah diuji manual: ea_get kosong kalau dilewati).
          oldctx="$(debugfs -R "ea_get /$rel security.selinux" "$img" 2>/dev/null \
            | sed -n 's/^security\.selinux ([0-9]*) = "\(.*\)"$/\1/p' | sed 's/\\000$//' || true)"
          debugfs -w -R "rm $rel" "$img" >/dev/null 2>&1 || true
          debugfs -w -R "write $f $rel" "$img" >/dev/null 2>&1
          if [ -n "$oldctx" ]; then
            debugfs -w -R "ea_set /$rel security.selinux $oldctx" "$img" >/dev/null 2>&1 || true
          fi
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
echo "    Catatan 1: kalau device tetap force-encrypt setelah ini, kemungkinan fstab"
echo "    yang aktif ada di ramdisk boot/vendor_boot (bukan di vendor.img) -- belum"
echo "    di-cover script ini, perlu extract ramdisk manual."
echo "    Catatan 2: EXT4 hasil konversi dari EROFS biasanya LEBIH BESAR (EROFS terkompresi,"
echo "    EXT4 tidak) -- kalau 'fastboot flash vendor' gagal 'not enough space' di fastbootd,"
echo "    cek target_super_dump.txt (dari package_rom.sh) untuk kapasitas group super asli."
