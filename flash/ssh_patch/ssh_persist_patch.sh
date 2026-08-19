#!/bin/sh
# ssh_persist_patch.sh
# Enable SSH on the Unitree GO2 (RK3588S board) and keep the Unitree stack from
# disabling it. The stock firmware ships a module (unitree_patch) whose install
# hook runs:  pkill -9 sshd; service ssh stop; systemctl disable ssh
# so simply setting a password is not enough - sshd gets killed and disabled.
#
# This patch:
#   1. (optional) sets the `unitree` account password
#   2. neutralizes the ssh-kill command in unitree_patch/module.json
#   3. installs an INDEPENDENT, self-healing sshd unit (Restart=always) under a
#      name the Unitree teardown commands don't target
#   4. ensures /run/sshd exists at boot
#
# USAGE
#   Live robot (root shell via serial console / init=/bin/sh):
#       sh ssh_persist_patch.sh [newpassword]
#   Offline against a mounted rootfs image:
#       ROOT=/mnt/goimg sh ssh_persist_patch.sh [newpassword]
#
# Safe to re-run (idempotent). Makes a .bak of module.json.
set -eu
ROOT="${ROOT:-/}"
PW="${1:-}"
say(){ echo "[ssh-patch] $*"; }

# ---- 1. optional password ----------------------------------------------------
if [ -n "$PW" ]; then
  if command -v openssl >/dev/null 2>&1; then
    HASH=$(openssl passwd -6 "$PW")
    awk -v h="$HASH" -F: 'BEGIN{OFS=":"} $1=="unitree"{$2=h; if($3=="")$3="20637"} {print}' \
        "$ROOT/etc/shadow" > "$ROOT/etc/shadow.tmp"
    cat "$ROOT/etc/shadow.tmp" > "$ROOT/etc/shadow"
    rm -f "$ROOT/etc/shadow.tmp"
    chmod 640 "$ROOT/etc/shadow"
    say "unitree password set"
  else
    say "WARNING: openssl not found; skipped password (set it later with: passwd unitree)"
  fi
fi

# ---- 2. neutralize the unitree_patch ssh-kill --------------------------------
MJ="$ROOT/unitree/robot/pkg/module/unitree_patch/module.json"
if [ -f "$MJ" ] && grep -q 'pkill -9 sshd' "$MJ"; then
  cp -f "$MJ" "$MJ.bak"
  sed 's/pkill -9 sshd; service ssh stop; systemctl disable ssh/true/g' "$MJ.bak" > "$MJ"
  say "neutralized ssh-kill in unitree_patch/module.json (backup: module.json.bak)"
else
  say "unitree_patch ssh-kill not present (already patched or module absent)"
fi

# ---- 3. /run/sshd at boot ----------------------------------------------------
printf 'd /run/sshd 0755 root root -\n' > "$ROOT/etc/tmpfiles.d/sshd.conf"

# ---- 4. independent, self-healing sshd unit ---------------------------------
# Runs its OWN sshd (Restart=always). Unit is named 'sshkeep', not 'ssh', so the
# firmware's `systemctl disable ssh` / `service ssh stop` cannot touch it. If a
# `pkill -9 sshd` ever fires, systemd relaunches within RestartSec.
cat > "$ROOT/etc/systemd/system/sshkeep.service" <<'UNIT'
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
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/sshkeep.service \
       "$ROOT/etc/systemd/system/multi-user.target.wants/sshkeep.service"
say "installed sshkeep.service (Restart=always, port 22)"

# ---- 5. activate now if patching the live system -----------------------------
if [ "$ROOT" = "/" ]; then
  mkdir -p /run/sshd
  systemctl daemon-reload 2>/dev/null || true
  systemctl stop ssh 2>/dev/null || true
  systemctl enable --now sshkeep.service 2>/dev/null || systemctl start sshkeep.service 2>/dev/null || /usr/sbin/sshd
  sleep 1
  if (ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -q ':22 '; then
    say "OK: sshd is listening on port 22"
  else
    say "WARNING: nothing on :22 yet - check: systemctl status sshkeep; journalctl -u sshkeep"
  fi
fi

say "done. SSH starts at boot and self-restarts if killed."
say "connect (wired): ssh unitree@192.168.123.161   (root over ssh is key-only by default)"
