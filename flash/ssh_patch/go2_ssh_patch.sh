#!/bin/sh
# go2_ssh_patch.sh — patch SSH login on the Unitree GO2 (RK3588S board).
#
# WORKS ON:
#   * the LIVE robot            (default, --root /)
#   * a mounted rootfs dir      (--root /mnt/goimg)
#   * an IMAGE FILE (--image):
#       - full eMMC dump w/ GPT  (finds & mounts the rootfs partition)
#       - a bare rootfs partition image (RKDevTool rootfs.img = plain ext4)
#     (4-part dump? concat first:  cat A B C D > emmc_full.img)
#
# WHAT IT DOES
#   * sets the `unitree` (and optionally `root`) password  (crypt-verified)
#   * (unless --password-only) makes SSH actually usable, because stock firmware's
#     unitree_patch module disables + kills sshd:
#       - neutralizes that ssh-kill in unitree_patch/module.json
#       - installs sshkeep.service: independent sshd, Restart=always, named so
#         `systemctl disable ssh` / `service ssh stop` can't touch it
#       - ensures /run/sshd exists at boot
#
# USAGE
#   Live robot (root shell via serial console / init=/bin/sh):
#       sh go2_ssh_patch.sh --password 'NEWPASS'
#   eMMC dump / RKDevTool rootfs image (run as root; needs losetup+mount):
#       sh go2_ssh_patch.sh --image emmc_full.img --password 'NEWPASS'
#       sh go2_ssh_patch.sh --image rootfs.img    --password 'NEWPASS'
#   Already-mounted rootfs:
#       sh go2_ssh_patch.sh --root /mnt/goimg --password 'NEWPASS'
#
# OPTIONS
#   --password PASS        password for the login user (required)
#   --user NAME            login user to patch            (default: unitree)
#   --root-password PASS   also set root's password
#   --permit-root          set 'PermitRootLogin yes' in sshd_config
#   --password-only        ONLY change the password (skip the keep-ssh-alive parts)
#   --image FILE           patch a rootfs/eMMC image file (auto-mounts, root needed)
#   --root DIR             operate on an already-mounted rootfs (default /  = live)
#   -h | --help
#
# Idempotent. Backs up edited files with .bak. After patching an image, flash it
# back (rkdeveloptool / RKDevTool) — for a full-disk dump, write it whole or just
# the rootfs partition.
set -eu

ROOTDIR=/ ; USER_NAME=unitree ; PW= ; ROOTPW= ; PERMIT_ROOT=0 ; PWONLY=0 ; IMAGE=
MOUNTED= ; LOOPDEV=
die(){ echo "go2-ssh-patch: ERROR: $*" >&2; exit 1; }
say(){ echo "[go2-ssh-patch] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --password) PW="${2:?}"; shift 2;;
    --user) USER_NAME="${2:?}"; shift 2;;
    --root-password) ROOTPW="${2:?}"; shift 2;;
    --permit-root) PERMIT_ROOT=1; shift;;
    --password-only) PWONLY=1; shift;;
    --image) IMAGE="${2:?}"; shift 2;;
    --root) ROOTDIR="${2:?}"; shift 2;;
    -h|--help) sed -n '2,48p' "$0"; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done
[ -n "$PW" ] || die "--password is required"
command -v openssl >/dev/null 2>&1 || die "openssl not found (needed to hash the password)"

# ---- image handling: mount the rootfs, set ROOTDIR --------------------------
cleanup_image(){
  [ -n "$MOUNTED" ] && { umount "$MOUNTED" 2>/dev/null || umount -l "$MOUNTED" 2>/dev/null; rmdir "$MOUNTED" 2>/dev/null; }
  [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null || true
}
if [ -n "$IMAGE" ]; then
  [ "$(id -u)" -eq 0 ] || die "--image needs root (losetup/mount)"
  [ -f "$IMAGE" ] || die "no such image: $IMAGE"
  command -v losetup >/dev/null 2>&1 || die "losetup not found"
  trap cleanup_image EXIT
  MNT=$(mktemp -d)
  ext4m=$(dd if="$IMAGE" bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  gptm=$(dd if="$IMAGE" bs=1 skip=512 count=8 2>/dev/null)
  spm=$(dd if="$IMAGE" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$ext4m" = "53ef" ]; then
    say "image type: bare ext4 rootfs"
    mount -o loop "$IMAGE" "$MNT" || die "mount failed"; MOUNTED="$MNT"
  elif [ "$gptm" = "EFI PART" ]; then
    say "image type: full disk (GPT) — locating rootfs partition"
    LOOPDEV=$(losetup -fP --show "$IMAGE") || die "losetup -P failed"
    # give the kernel a moment to create partition nodes
    i=0; while [ ! -e "${LOOPDEV}p1" ] && [ $i -lt 20 ]; do sleep 0.2; i=$((i+1)); done
    part=
    for p in "${LOOPDEV}"p*; do
      [ -e "$p" ] || continue
      lbl=$(blkid -o value -s LABEL "$p" 2>/dev/null || true)
      case "$lbl" in linuxroot|rootfs) part="$p"; break;; esac
    done
    [ -n "$part" ] || part="${LOOPDEV}p7"   # Go2: rootfs is partition 7
    say "rootfs partition: $part  (label $(blkid -o value -s LABEL "$part" 2>/dev/null))"
    mount "$part" "$MNT" || die "mount $part failed"; MOUNTED="$MNT"
  elif [ "$spm" = "3aff26ed" ]; then
    die "Android sparse image — convert first:  simg2img '$IMAGE' raw.img  then --image raw.img"
  else
    if dd if="$IMAGE" bs=1 count=4 2>/dev/null | grep -qa 'RKAF\|RKFW\|RKNS'; then
      die "Rockchip update.img — unpack it first, then --image the rootfs partition file"
    fi
    die "unrecognized image format (not ext4, GPT, sparse, or a raw partition)"
  fi
  ROOTDIR="$MNT"
  say "mounted rootfs at $ROOTDIR"
fi

[ -f "$ROOTDIR/etc/shadow" ] || die "no $ROOTDIR/etc/shadow (wrong target?)"

# ---- password helpers -------------------------------------------------------
verify_hash(){ [ "$(openssl passwd -6 -salt "$(printf '%s' "$2" | cut -d'$' -f3)" "$1")" = "$2" ]; }
set_password(){
  _u="$1"; _p="$2"
  grep -q "^$_u:" "$ROOTDIR/etc/shadow" || die "user $_u not in shadow"
  _h=$(openssl passwd -6 "$_p")
  cp -f "$ROOTDIR/etc/shadow" "$ROOTDIR/etc/shadow.bak"
  awk -v u="$_u" -v h="$_h" -F: 'BEGIN{OFS=":"} $1==u{$2=h; if($3=="")$3="20637"} {print}' \
      "$ROOTDIR/etc/shadow.bak" > "$ROOTDIR/etc/shadow"
  chmod 640 "$ROOTDIR/etc/shadow"
  _stored=$(grep "^$_u:" "$ROOTDIR/etc/shadow" | cut -d: -f2)
  if verify_hash "$_p" "$_stored"; then say "password set + verified for '$_u'"
  else die "hash verification FAILED for '$_u' (restore from etc/shadow.bak)"; fi
}

# ---- 1. passwords -----------------------------------------------------------
set_password "$USER_NAME" "$PW"
[ -n "$ROOTPW" ] && set_password root "$ROOTPW"

if [ "$PWONLY" -eq 1 ]; then
  say "password-only mode: done. NOTE: stock firmware disables+kills sshd, so this"
  say "alone may not let you connect. Re-run without --password-only to fix that."
  exit 0
fi

# ---- 2. neutralize the unitree_patch ssh-kill ------------------------------
MJ="$ROOTDIR/unitree/robot/pkg/module/unitree_patch/module.json"
if [ -f "$MJ" ] && grep -q 'pkill -9 sshd' "$MJ"; then
  cp -f "$MJ" "$MJ.bak"
  sed 's/pkill -9 sshd; service ssh stop; systemctl disable ssh/true/g' "$MJ.bak" > "$MJ"
  say "neutralized ssh-kill in unitree_patch/module.json (backup .bak)"
else
  say "unitree_patch ssh-kill not present (ok)"
fi

# ---- 3. /run/sshd at boot ---------------------------------------------------
printf 'd /run/sshd 0755 root root -\n' > "$ROOTDIR/etc/tmpfiles.d/sshd.conf"

# ---- 4. optional: allow root over ssh --------------------------------------
if [ "$PERMIT_ROOT" -eq 1 ]; then
  SC="$ROOTDIR/etc/ssh/sshd_config"; cp -f "$SC" "$SC.bak"
  grep -q '^PermitRootLogin' "$SC" && sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$SC" \
                                   || printf '\nPermitRootLogin yes\n' >> "$SC"
  say "set PermitRootLogin yes"
fi

# ---- 5. independent, self-healing sshd unit --------------------------------
cat > "$ROOTDIR/etc/systemd/system/sshkeep.service" <<'UNIT'
[Unit]
Description=Persistent SSH (independent of unitree ssh management)
After=network.target
[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/sshd
ExecStart=/usr/sbin/sshd -D -e
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$ROOTDIR/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/sshkeep.service \
       "$ROOTDIR/etc/systemd/system/multi-user.target.wants/sshkeep.service"
say "installed sshkeep.service (Restart=always, port 22)"

# ---- 6. activate now if live -----------------------------------------------
if [ "$ROOTDIR" = "/" ]; then
  mkdir -p /run/sshd; systemctl daemon-reload 2>/dev/null || true
  systemctl stop ssh 2>/dev/null || true
  systemctl enable --now sshkeep.service 2>/dev/null || systemctl start sshkeep.service 2>/dev/null || /usr/sbin/sshd
  sleep 1
  (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -q ':22 ' \
    && say "OK: sshd listening on :22" || say "check: systemctl status sshkeep"
fi
say "done. Connect (wired): ssh $USER_NAME@192.168.123.161"
[ -n "$IMAGE" ] && say "image patched — flash it back (rkdeveloptool/RKDevTool: whole disk, or the rootfs partition)"
exit 0
