#!/usr/bin/env python3
# rkops — REAL privileged operations for the RK3588S2 SOM porter.
# Shells out to proven tools (e2fsprogs / debugfs / mount / sgdisk) rather than
# reimplementing filesystems. Every op: logged with its exact command line,
# copy-on-write for mutations, verified after the fact.
#
# Root is required for: extract_tree (ownership), rebuild_rootfs, patch_shadow,
# chroot_test. Carving and analysis need no root.

import os, sys, subprocess, shutil, tempfile, hashlib, struct, datetime
import rkcore

class OpError(RuntimeError): pass

def is_root(): return os.geteuid() == 0

def run(cmd, log, dry_run=False, check=True, input_text=None):
    """Run a command, streaming stdout/stderr into the log. Returns (rc, output)."""
    shown = " ".join(cmd) if isinstance(cmd, list) else cmd
    if dry_run:
        log(f"DRY-RUN would exec: {shown}")
        return 0, ""
    log(f"exec: {shown}")
    p = subprocess.run(cmd, capture_output=True, text=True, input=input_text)
    out = (p.stdout or "") + (p.stderr or "")
    for ln in out.splitlines():
        log(f"  | {ln}")
    if check and p.returncode != 0:
        raise OpError(f"command failed (rc={p.returncode}): {shown}")
    return p.returncode, out


# --------------------------------------------------------------------------- carve
def carve(dump, part, out_path, log, dry_run=False, chunk=8*2**20):
    """Byte-exact carve of a partition from the (split) dump. No root needed."""
    total = min(part["bytes"], dump.total - part["start_byte"])
    truncated = total < part["bytes"]
    if dry_run:
        log(f"DRY-RUN carve {part['name']}: {total} bytes "
            f"{'(TRUNCATED)' if truncated else ''} -> {out_path}")
        return {"name": part["name"], "bytes": total, "truncated": truncated}
    off, written, h = part["start_byte"], 0, hashlib.sha256()
    with open(out_path, "wb") as f:
        while written < total:
            d = dump.read(off, min(chunk, total-written))
            f.write(d); h.update(d); off += len(d); written += len(d)
    log(f"carved {part['name']}: {written} bytes sha256={h.hexdigest()[:16]}… "
        f"{'(TRUNCATED — rebuild if ext4)' if truncated else ''}")
    return {"name": part["name"], "bytes": written,
            "sha256": h.hexdigest(), "truncated": truncated, "path": out_path}


# --------------------------------------------------------------------------- ext4 helpers
def fsck(image, log, fix=True, dry_run=False):
    return run(["e2fsck", "-f", "-y" if fix else "-n", image],
               log, dry_run, check=False)

def ext4_ident(image):
    """(label, uuid, block_size, total_bytes) from an ext4 image superblock."""
    with open(image, "rb") as f:
        f.seek(1024); sb = f.read(1024)
    if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
        raise OpError(f"{image}: not ext4")
    block = 1024 << struct.unpack_from("<I", sb, 0x18)[0]
    uuid = sb[0x68:0x78]
    uuid_s = (f"{uuid[0:4].hex()}-{uuid[4:6].hex()}-{uuid[6:8].hex()}-"
              f"{uuid[8:10].hex()}-{uuid[10:16].hex()}")
    label = sb[0x78:0x88].split(b"\x00")[0].decode("latin1", "replace")
    lo = struct.unpack_from("<I", sb, 0x04)[0]
    hi = struct.unpack_from("<I", sb, 0x150)[0] if (
         struct.unpack_from("<I", sb, 0x60)[0] & 0x80) else 0
    total_bytes = ((hi << 32) | lo) * block
    return label, uuid_s, block, total_bytes


def extract_tree(image, dest_dir, log, dry_run=False):
    """Extract a full ext4 tree with metadata. Uses debugfs rdump (as root =>
    ownership/mode/times preserved); no loop device required."""
    if not dry_run and not is_root():
        raise OpError("extract_tree needs root (to restore ownership)")
    os.makedirs(dest_dir, exist_ok=True)
    run(["debugfs", "-R", f"rdump / {dest_dir}", image], log, dry_run)
    return dest_dir


def rebuild_ext4(src_dir, out_img, size_bytes, label, uuid, log,
                 block=4096, reserve_pct=1, dry_run=False):
    """Build a fresh ext4 image of size_bytes from a directory tree, preserving
    label + UUID, then verify it."""
    blocks = size_bytes // block
    cmd = ["mke2fs", "-t", "ext4", "-b", str(block), "-m", str(reserve_pct),
           "-L", label, "-U", uuid, "-d", src_dir, "-F", out_img, str(blocks)]
    run(cmd, log, dry_run)
    fsck(out_img, log, fix=False, dry_run=dry_run)
    return out_img


def rebuild_rootfs_from_dump(dump, part, out_img, target_size, log,
                             workdir=None, dry_run=False, keep_temp=False):
    """Full rootfs rebuild for a raw-truncated-but-data-complete partition:
       carve captured region -> e2fsck -> extract tree -> mke2fs -d at target
       size, preserving label+UUID. Verified."""
    if not dry_run and not is_root():
        raise OpError("rebuild_rootfs needs root")
    # workdir beside the OUTPUT (not /tmp, which may be tmpfs/RAM and too small
    # for a ~15 GiB working image)
    tmp = workdir or (os.path.abspath(out_img) + ".workdir")
    os.makedirs(tmp, exist_ok=True)
    work = os.path.join(tmp, "work.img")
    tree = os.path.join(tmp, "tree")
    log(f"rebuild rootfs '{part['name']}' -> {out_img} "
        f"(target {target_size/2**30:.2f} GiB); workdir {tmp}")
    carve(dump, part, work, log, dry_run)
    if dry_run:
        label, uuid = "linuxroot", "<preserved>"
    else:
        # A carved truncated ext4 has physical size < superblock size, so
        # e2fsck aborts and debugfs can't open it. Sparse-extend the image up
        # to the full filesystem size first: the missing tail becomes
        # unallocated zeros, and every real file (all in the captured range)
        # then reads back cleanly.
        label, uuid, _, full = ext4_ident(work)
        cur = os.path.getsize(work)
        if full > cur:
            with open(work, "r+b") as f:
                f.truncate(full)
            log(f"sparse-extended work image {cur} -> {full} bytes "
                f"(full fs size) so e2fsck/debugfs can open it")
    fsck(work, log, fix=True, dry_run=dry_run)          # now physical>=sb; fixes tail
    log(f"preserving identity: label={label} uuid={uuid}")
    extract_tree(work, tree, log, dry_run)
    if not dry_run:
        nfiles = sum(len(fs) for _, _, fs in os.walk(tree))
        tbytes = sum(os.path.getsize(os.path.join(d, f))
                     for d, _, fs in os.walk(tree) for f in fs
                     if not os.path.islink(os.path.join(d, f)))
        log(f"extracted {nfiles} files, {tbytes/2**20:.1f} MiB from rootfs")
        if nfiles == 0:
            raise OpError("rootfs extract produced 0 files — debugfs could not "
                          "open the image; refusing to build an empty rootfs")
    rebuild_ext4(tree, out_img, target_size, label, uuid, log, dry_run=dry_run)
    if not keep_temp and not dry_run:
        shutil.rmtree(tmp, ignore_errors=True)
    return {"out": out_img, "label": label, "uuid": uuid, "size": target_size}


# --------------------------------------------------------------------------- user enumeration
def _debugfs_cat(image, path):
    """Read a file out of an ext4 image via debugfs (no root, no mount).
    Returns text, or '' if absent/unreadable."""
    p = subprocess.run(["debugfs", "-R", f"cat {path}", image],
                       capture_output=True, text=True)
    # debugfs prints its banner to stderr; the file body is on stdout
    return p.stdout if p.returncode == 0 else ""

def list_users(image, log=None):
    """Enumerate accounts from /etc/passwd + /etc/shadow inside an ext4 image.
    Works read-only via debugfs (no mount / no root). Returns a list of dicts:
      name, uid, gid, home, shell, has_shell, shadow_status, locked
    shadow_status: 'set'|'empty'|'locked'|'disabled'|'no-entry'."""
    log = log or (lambda *a, **k: None)
    passwd = _debugfs_cat(image, "/etc/passwd")
    shadow = _debugfs_cat(image, "/etc/shadow")
    if not passwd:
        raise OpError("could not read /etc/passwd from image (not a rootfs, or "
                      "image unreadable by debugfs)")
    sh = {}
    for ln in shadow.splitlines():
        f = ln.split(":")
        if len(f) >= 2:
            sh[f[0]] = f[1]
    users = []
    for ln in passwd.splitlines():
        f = ln.split(":")
        if len(f) < 7:
            continue
        name, _pw, uid, gid, _gecos, home, shell = f[:7]
        h = sh.get(name)
        if h is None:            status, locked = "no-entry", False
        elif h == "":            status, locked = "empty", False
        elif h in ("*", "!"):    status, locked = "disabled", True
        elif h.startswith("!"):  status, locked = "locked", True
        else:                    status, locked = "set", False
        has_shell = shell not in ("", "/usr/sbin/nologin", "/sbin/nologin",
                                  "/bin/false", "/usr/bin/false",
                                  "/bin/sync", "/usr/bin/sync")
        try: uid_i = int(uid)
        except ValueError: uid_i = -1
        users.append({"name": name, "uid": uid_i, "gid": gid, "home": home,
                      "shell": shell, "has_shell": has_shell,
                      "shadow_status": status, "locked": locked})
    log(f"found {len(users)} accounts in /etc/passwd "
        f"({sum(1 for u in users if u['has_shell'])} with a login shell)")
    return users

def login_users(users):
    """Real login accounts = those with an interactive shell. Keys off the shell,
    NOT the uid range, so vendor logins like 'unitree' (uid 999, /bin/bash) are
    included — a uid>=1000 filter would silently miss them."""
    return [u for u in users if u["has_shell"]]


# --------------------------------------------------------------------------- password patch
def _cow_copy(src, dst, log, dry_run=False):
    run(["cp", "--reflink=auto", "--sparse=always", src, dst], log, dry_run)

def patch_shadow(image, accounts, password, log, cow=True, method="sha512",
                 backup_dir=None, dry_run=False):
    """Patch /etc/shadow in an ext4 image via a loop mount (kernel driver keeps
    journal + metadata_csum correct). Copy-on-write by default. Verified."""
    if not dry_run and not is_root():
        raise OpError("patch_shadow needs root (loop mount)")
    target = image
    if cow:
        target = image + ".patched"
        _cow_copy(image, target, log, dry_run)
        log(f"copy-on-write: editing {target}, original untouched")
    fsck(target, log, fix=True, dry_run=dry_run)         # replay/clear journal first
    new_hash = rkcore.make_hash(password, method)
    log(f"new hash ({method}): {new_hash[:12]}…  accounts: {', '.join(accounts)}")
    if dry_run:
        log("DRY-RUN: would loop-mount, back up /etc/shadow, rewrite, verify")
        return {"image": target, "accounts": accounts, "applied": False,
                "hash": new_hash}

    mnt = tempfile.mkdtemp(prefix="rkport_mnt_")
    mounted = False
    try:
        run(["mount", "-o", "loop", target, mnt], log); mounted = True
        shadow = os.path.join(mnt, "etc", "shadow")
        if not os.path.exists(shadow):
            raise OpError("/etc/shadow not found in image (is this a rootfs?)")
        # audit backup
        bdir = backup_dir or os.path.dirname(os.path.abspath(image))
        os.makedirs(bdir, exist_ok=True)
        bpath = os.path.join(bdir, "shadow.backup")
        shutil.copy2(shadow, bpath); log(f"backed up original shadow -> {bpath}")
        # rewrite
        lines = open(shadow).read().splitlines()
        all_names = [ln.split(":")[0] for ln in lines if ":" in ln]
        want = list(accounts)
        if any(a.upper() == "ALL" for a in accounts):
            want = all_names
            log(f"'ALL' -> every account in shadow ({len(want)}): "
                f"{', '.join(want)}")
        changed = []
        for i, ln in enumerate(lines):
            parts = ln.split(":")
            if parts and parts[0] in want:
                parts[1] = new_hash
                # ensure the account isn't locked/expired by a stale flag
                if len(parts) > 2 and parts[2] == "":
                    parts[2] = "19000"
                lines[i] = ":".join(parts); changed.append(parts[0])
        missing = set(want) - set(changed)
        if missing:
            log(f"WARNING: accounts not present in shadow: {', '.join(missing)}", "WARN")
        with open(shadow, "w") as f:
            f.write("\n".join(lines) + "\n")
        os.chmod(shadow, 0o640)
        log(f"patched accounts: {', '.join(changed) or '(none)'}")
        # verify by re-reading
        verify = open(shadow).read()
        ok = all(f"{a}:{new_hash}:" in verify for a in changed)
        log(f"verify re-read: {'PASS' if ok else 'FAIL'}")
    finally:
        if mounted:
            run(["sync"], log, check=False)
            rc, _ = run(["umount", mnt], log, check=False)
            if rc != 0:                                  # busy → lazy-detach
                run(["umount", "-l", mnt], log, check=False)
        try: os.rmdir(mnt)
        except OSError: pass
    fsck(target, log, fix=False)                         # final consistency check
    return {"image": target, "accounts": changed, "applied": True,
            "hash": new_hash, "backup": bpath}


def patch_shadow_in_dump(dump, part, out_img, accounts, password, log,
                         target_size=None, dry_run=False):
    """Patch passwords starting from the ORIGINAL dump: carve rootfs (CoW, the
    split .BIN files are never mutated) -> [rebuild to target size] -> patch.
    Emits a standalone patched image."""
    tmp = tempfile.mkdtemp(prefix="rkport_dumppatch_")
    work = os.path.join(tmp, "rootfs.img")
    rep = rkcore.ext4_capture_report(dump, part, log)
    if rep.get("ext4") and not rep.get("raw_complete") and rep.get("data_complete"):
        log("rootfs is raw-truncated but data-complete -> rebuild before patch")
        size = target_size or rep["fs_bytes"]
        rebuild_rootfs_from_dump(dump, part, work, size, log,
                                 workdir=os.path.join(tmp, "rb"), dry_run=dry_run)
    else:
        carve(dump, part, work, log, dry_run)
        fsck(work, log, fix=True, dry_run=dry_run)
    res = patch_shadow(work, accounts, password, log, cow=False, dry_run=dry_run)
    if not dry_run:
        shutil.move(work, out_img)
        res["image"] = out_img
        shutil.rmtree(tmp, ignore_errors=True)
    log(f"patched rootfs image -> {out_img}")
    return res


# --------------------------------------------------------------------------- verify / test
def verify_images(image_dir, log):
    """Integrity gate: sha256 every image + e2fsck any ext4 image."""
    results = []
    for name in sorted(os.listdir(image_dir)):
        p = os.path.join(image_dir, name)
        if not os.path.isfile(p) or not name.endswith(".img"):
            continue
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for blk in iter(lambda: f.read(1 << 20), b""):
                h.update(blk)
        entry = {"name": name, "sha256": h.hexdigest(), "bytes": os.path.getsize(p)}
        with open(p, "rb") as f:
            f.seek(1024 + 0x38); magic = f.read(2)   # ext4 s_magic at sb+0x38
        if magic == b"\x53\xef":
            rc, _ = run(["e2fsck", "-fn", p], log, check=False)
            entry["ext4_clean"] = (rc == 0)
        log(f"{name}: sha256={h.hexdigest()[:16]}… "
            f"{'ext4 '+('clean' if entry.get('ext4_clean') else 'ISSUES') if 'ext4_clean' in entry else ''}")
        results.append(entry)
    return results


def chroot_test(rootfs_img, log, cmds=None):
    """Tier-2 integrity test: loop-mount the rootfs and run aarch64 binaries
    under binfmt/qemu-user-static. Requires qemu-user-static + binfmt active."""
    if not is_root():
        raise OpError("chroot_test needs root")
    cmds = cmds or [["/bin/uname", "-m"],
                    ["/usr/bin/dpkg", "-l"],
                    ["/bin/cat", "/etc/os-release"]]
    mnt = tempfile.mkdtemp(prefix="rkport_chroot_")
    qemu = shutil.which("qemu-aarch64-static")
    try:
        run(["mount", "-o", "loop", rootfs_img, mnt], log)
        # provide qemu inside the tree if binfmt uses the F flag it isn't needed,
        # but copy defensively
        if qemu and os.path.isdir(os.path.join(mnt, "usr", "bin")):
            try: shutil.copy(qemu, os.path.join(mnt, "usr", "bin",
                                                os.path.basename(qemu)))
            except Exception: pass
        for m in ("proc", "sys", "dev"):
            run(["mount", "--rbind", f"/{m}", os.path.join(mnt, m)], log, check=False)
        out = {}
        for c in cmds:
            rc, o = run(["chroot", mnt] + c, log, check=False)
            out[" ".join(c)] = (rc, o.strip().splitlines()[:3])
        return out
    finally:
        for m in ("dev", "sys", "proc"):
            run(["umount", "-lR", os.path.join(mnt, m)], log, check=False)
        run(["umount", "-l", mnt], log, check=False)
        shutil.rmtree(mnt, ignore_errors=True)


if __name__ == "__main__":
    print("rkops is a library; use rkport_cli.py or the GUI.", file=sys.stderr)
