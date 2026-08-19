#!/usr/bin/env python3
# rkcore — backend logic for the RK3588S2 SOM porting tool.
# Pure Python, no Qt: importable by the GUI and runnable headless (`--selftest`).
#
# Covers, for real:
#   * split-dump virtual address space (A/B/C/D... as one device, no concat)
#   * GPT parse
#   * ext4 truncation-usability check (are all *allocated* blocks captured?)
#   * parameter.txt (RK mtdparts) writer
#   * config.cfg (RKDevTool binary, 610-byte records) writer
#   * partition carve
#   * password-patch planning (shadow) with a hard safety contract
#
# Destructive/heavy ops (carve of GB, real shadow patch) are gated behind
# explicit flags; the mock GUI runs them in "plan" mode by default.

import os, struct, glob, hashlib, json, datetime, subprocess

SECTOR = 512

# ----------------------------------------------------------------------------- logging
class Log:
    """Session logger: every line goes to stdout, an in-memory buffer, and a file."""
    def __init__(self, logdir=None, sink=None):
        self.sink = sink            # optional callable(str) for a GUI pane
        self.lines = []
        self.path = None
        if logdir:
            os.makedirs(logdir, exist_ok=True)
            stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
            self.path = os.path.join(logdir, f"rkport_{stamp}.log")
            self._fh = open(self.path, "a", encoding="utf-8")
        else:
            self._fh = None

    def __call__(self, msg, level="INFO"):
        ts = datetime.datetime.now().strftime("%H:%M:%S")
        line = f"[{ts}] {level:5} {msg}"
        self.lines.append(line)
        print(line)
        if self._fh:
            self._fh.write(line + "\n"); self._fh.flush()
        if self.sink:
            try: self.sink(line)
            except Exception: pass

    def close(self):
        if self._fh: self._fh.close()


# ----------------------------------------------------------------------------- split dump
class SplitDump:
    """Treat one or more split files as a single linear device, read-only,
    without ever concatenating them on disk."""
    def __init__(self, paths, log=None):
        self.paths = list(paths)
        self.sizes = [os.path.getsize(p) for p in self.paths]
        self.starts, off = [], 0
        for s in self.sizes:
            self.starts.append(off); off += s
        self.total = off
        self._fh = [open(p, "rb") for p in self.paths]
        self.log = log or (lambda *a, **k: None)
        self.log(f"opened {len(self.paths)} part(s), virtual size "
                 f"{self.total} bytes ({self.total/2**30:.2f} GiB)")

    IMG_EXT = {".bin", ".img", ".raw", ".dd", ".emmc"}
    MIN_PART = 1 << 20   # ignore anything under 1 MiB when scanning a folder

    @staticmethod
    def autodetect(path_or_dir, log=None):
        """Accept a single file, a glob, or a directory; return ordered parts.
        An explicit single file is honored as-is. A folder/glob is filtered to
        image-like files (.bin/.img/.raw/.dd or a numeric split suffix) above
        MIN_PART, so stray scripts/docs in the folder are ignored."""
        # explicit single file → honor it regardless of extension
        if (os.path.isfile(path_or_dir)
                and not any(c in path_or_dir for c in "*?[]")):
            return [path_or_dir]
        if os.path.isdir(path_or_dir):
            cands = sorted(glob.glob(os.path.join(path_or_dir, "*")))
        else:
            cands = sorted(glob.glob(path_or_dir))
        parts = []
        for c in cands:
            if not os.path.isfile(c) or os.path.getsize(c) < SplitDump.MIN_PART:
                continue
            ext = os.path.splitext(c)[1].lower()
            if ext in SplitDump.IMG_EXT or ext[1:].isdigit():
                parts.append(c)
        return parts

    def read(self, offset, length):
        out = bytearray()
        while length > 0:
            if offset >= self.total:
                raise EOFError(f"read past captured range @0x{offset:x} "
                               f"(have {self.total} bytes)")
            idx = max(i for i in range(len(self.starts)) if self.starts[i] <= offset)
            local = offset - self.starts[idx]
            chunk = min(length, self.sizes[idx] - local)
            self._fh[idx].seek(local)
            data = self._fh[idx].read(chunk)
            if not data:
                raise EOFError(f"short read @0x{offset:x}")
            out += data; offset += len(data); length -= len(data)
        return bytes(out)

    def close(self):
        for fh in self._fh: fh.close()


# ----------------------------------------------------------------------------- GPT
def _guid(b):
    d1, d2, d3 = struct.unpack("<IHH", b[:8])
    d4 = b[8:10]; d5 = b[10:16]
    return (f"{d1:08x}-{d2:04x}-{d3:04x}-"
            f"{d4.hex()}-{d5.hex()}")

def parse_gpt(dump, log=None):
    log = log or (lambda *a, **k: None)
    hdr = dump.read(SECTOR, SECTOR)
    if hdr[:8] != b"EFI PART":
        raise ValueError("no GPT signature at LBA1 (not a GPT image?)")
    (sig, rev, hsz, hcrc, _r, my_lba, alt_lba, first_lba, last_lba
     ) = struct.unpack("<8sIIIIQQQQ", hdr[:56])
    disk_guid = _guid(hdr[0x38:0x48])
    pe_lba, n_pe, pe_sz = struct.unpack("<QII", hdr[0x48:0x58])
    parts = []
    for i in range(n_pe):
        raw = dump.read(pe_lba*SECTOR + i*pe_sz, pe_sz)
        if raw[:16] == b"\x00"*16:
            continue
        start, end, attr = struct.unpack("<QQQ", raw[0x20:0x38])
        name = raw[0x38:0x38+72].decode("utf-16-le").rstrip("\x00")
        parts.append({
            "index": i+1, "name": name,
            "start_lba": start, "end_lba": end,
            "sectors": end-start+1, "bytes": (end-start+1)*SECTOR,
            "start_byte": start*SECTOR,
            "type_guid": _guid(raw[:16]), "part_guid": _guid(raw[16:32]),
        })
    info = {"disk_guid": disk_guid, "alt_lba": alt_lba,
            "device_sectors": alt_lba+1, "device_bytes": (alt_lba+1)*SECTOR,
            "first_usable": first_lba, "last_usable": last_lba}
    log(f"GPT: {len(parts)} partitions, device {info['device_bytes']/1e9:.2f} GB")
    return info, parts


# ----------------------------------------------------------------------------- ext4 usability
def ext4_capture_report(dump, part, log=None):
    """For an ext4 partition, decide whether every *allocated* block is inside
    the captured dump range. A raw-truncated partition can still be data-complete."""
    log = log or (lambda *a, **k: None)
    base = part["start_byte"]
    try:
        sb = dump.read(base + 1024, 1024)
    except EOFError:
        return {"ext4": False, "reason": "superblock beyond capture"}
    if struct.unpack_from("<H", sb, 0x38)[0] != 0xEF53:
        return {"ext4": False, "reason": "no ext4 magic"}
    log_bs = struct.unpack_from("<I", sb, 0x18)[0]
    block = 1024 << log_bs
    blocks_total = struct.unpack_from("<I", sb, 0x04)[0]
    free_total = struct.unpack_from("<I", sb, 0x0C)[0]
    bpg = struct.unpack_from("<I", sb, 0x20)[0]
    inodes_pg = struct.unpack_from("<I", sb, 0x28)[0]
    first_data = struct.unpack_from("<I", sb, 0x14)[0]
    feat_incompat = struct.unpack_from("<I", sb, 0x60)[0]
    desc_size = struct.unpack_from("<H", sb, 0xFE)[0] or 32
    is64 = bool(feat_incompat & 0x80)
    label = sb[0x78:0x88].split(b"\x00")[0].decode("latin1", "replace")
    ngroups = (blocks_total + bpg - 1)//bpg

    captured_fs_bytes = dump.total - base
    captured_blocks = captured_fs_bytes // block
    captured_groups = captured_blocks // bpg

    gd_block = first_data + 1
    used_in = used_out = 0
    inodes_out = 0            # allocated INODES beyond the captured range
    last_data_group = -1
    for g in range(ngroups):
        o = base + gd_block*block + g*desc_size
        try:
            d = dump.read(o, desc_size)
        except EOFError:
            break
        free_lo = struct.unpack_from("<H", d, 0x0C)[0]
        free_hi = struct.unpack_from("<H", d, 0x2C)[0] if desc_size >= 0x2C else 0
        free = (free_hi << 16) | free_lo
        ifree_lo = struct.unpack_from("<H", d, 0x0E)[0]
        ifree_hi = struct.unpack_from("<H", d, 0x2E)[0] if desc_size >= 0x30 else 0
        ifree = (ifree_hi << 16) | ifree_lo
        this = min(bpg, blocks_total - g*bpg)
        used = this - free
        iused = inodes_pg - ifree
        if used > 0:
            last_data_group = g
        if g < captured_groups:
            used_in += used
        else:
            used_out += used
            inodes_out += iused

    # Blocks beyond the cut are almost always flex_bg metadata (reserved inode
    # tables / bitmaps) that mke2fs regenerates. The decisive test for "can I
    # rebuild every file" is whether any allocated INODE lives beyond the cut.
    data_complete = inodes_out == 0
    return {
        "ext4": True, "label": label, "block": block,
        "blocks_total": blocks_total, "fs_bytes": blocks_total*block,
        "used_bytes": (blocks_total-free_total)*block,
        "captured_bytes": captured_fs_bytes,
        "allocated_outside": used_out*block,
        "inodes_outside": inodes_out,
        "data_complete": data_complete,
        "raw_complete": captured_fs_bytes >= blocks_total*block,
        "last_data_group": last_data_group, "groups": ngroups,
        "is64": is64,
    }


def partition_status(dump, parts, log=None):
    """Per-partition: is it fully captured raw, or (for ext4) data-complete?"""
    rows = []
    for p in parts:
        raw_end = p["start_byte"] + p["bytes"]
        raw_ok = raw_end <= dump.total
        row = {**p, "raw_captured": raw_ok, "kind": "raw", "note": ""}
        if raw_ok:
            row["note"] = "fully captured"
        else:
            rep = ext4_capture_report(dump, p, log)
            if rep.get("ext4") and rep.get("data_complete"):
                row["kind"] = "ext4"
                row["note"] = (f"raw-truncated but DATA-COMPLETE "
                               f"(label={rep['label']}, "
                               f"{rep['used_bytes']/2**30:.2f} GiB used) — rebuild")
            elif rep.get("ext4"):
                row["note"] = (f"INCOMPLETE: {rep['allocated_outside']/2**20:.0f} MiB "
                               f"of data beyond capture")
            else:
                row["note"] = "truncated / not captured"
        rows.append(row)
    return rows


# ----------------------------------------------------------------------------- writers
def write_parameter_txt(parts, out_path, fw="1.0.0", model="RK3588S", magic="0x5041524B"):
    """RK parameter.txt: CMDLINE mtdparts (size@offset in sectors) + uuid lines."""
    keep = [p for p in parts if p["name"]]
    items = []
    for i, p in enumerate(keep):
        size = "-" if i == len(keep)-1 else f"0x{p['sectors']:08x}"
        grow = ":grow" if i == len(keep)-1 else ""
        items.append(f"{size}@0x{p['start_lba']:08x}({p['name']}{grow})")
    lines = [
        f"FIRMWARE_VER: {fw}", f"MACHINE_MODEL: {model}", "MACHINE_ID: 007",
        "MANUFACTURER: RKPORT", f"MAGIC: {magic}", "ATAG: 0x00200800",
        "MACHINE: 0xffffffff", "CHECK_MASK: 0x80", "PWR_HLD: 0,0,A,0,1",
        "TYPE: GPT",
        "CMDLINE: mtdparts=rk29xxnand:" + ",".join(items),
    ]
    for p in keep:
        lines.append(f"uuid:{p['name']}={p['part_guid']}")
    with open(out_path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return out_path


# --- RKDevTool binary config.cfg ---------------------------------------------
CFG_HDR = 29
CFG_REC = 610
def _cfg_header(count):
    h = bytearray(CFG_HDR)
    h[0:4] = b"CFG\x00"
    struct.pack_into("<H", h, 0x04, 0x001d)
    # SYSTEMTIME (cosmetic) — fixed placeholder, no wall-clock dependency
    for i, v in enumerate((2024, 1, 1, 1, 0, 0, 0, 0)):
        struct.pack_into("<H", h, 0x06 + i*2, v)
    h[0x16] = count & 0xFF
    struct.pack_into("<I", h, 0x17, CFG_HDR)     # record-start offset
    struct.pack_into("<H", h, 0x1b, CFG_REC)     # record size
    return h

def _cfg_record(name, path, addr_sectors, selected=1):
    r = bytearray(CFG_REC)
    struct.pack_into("<H", r, 0, CFG_REC)
    nb = name.encode("utf-16-le")
    pb = path.encode("utf-16-le")
    if len(nb) > 40*2-2: raise ValueError(f"name too long: {name}")
    if len(pb) > 260*2-2: raise ValueError(f"path too long: {path}")
    r[2:2+len(nb)] = nb
    r[82:82+len(pb)] = pb
    struct.pack_into("<I", r, 602, addr_sectors & 0xFFFFFFFF)
    struct.pack_into("<I", r, 606, 1 if selected else 0)
    return r

def write_config_cfg(rows, out_path):
    """rows: list of dict(name, addr, path, selected). Byte-compatible with RKDevTool."""
    buf = bytearray(_cfg_header(len(rows)))
    for r in rows:
        buf += _cfg_record(r["name"], r["path"], int(r.get("addr", 0)),
                           r.get("selected", 1))
    with open(out_path, "wb") as f:
        f.write(buf)
    return out_path

def read_config_cfg(path):
    """Round-trip reader (for verification/round-trips)."""
    b = open(path, "rb").read()
    n = b[0x16]; rows = []
    for i in range(n):
        base = CFG_HDR + i*CFG_REC
        name = b[base+2:base+82].decode("utf-16-le").rstrip("\x00")
        p = b[base+82:base+602].decode("utf-16-le").rstrip("\x00")
        addr = struct.unpack_from("<I", b, base+602)[0]
        sel = struct.unpack_from("<I", b, base+606)[0]
        rows.append({"name": name, "path": p, "addr": addr, "selected": sel})
    return rows


# ----------------------------------------------------------------------------- carve
def carve_partition(dump, part, out_path, log=None, chunk=8*2**20, plan=False):
    log = log or (lambda *a, **k: None)
    total = min(part["bytes"], dump.total - part["start_byte"])
    if plan:
        log(f"PLAN carve {part['name']}: {total} bytes from "
            f"0x{part['start_byte']:x} -> {out_path}")
        return {"name": part["name"], "bytes": total, "planned": True}
    off, written, h = part["start_byte"], 0, hashlib.sha256()
    with open(out_path, "wb") as f:
        while written < total:
            data = dump.read(off, min(chunk, total-written))
            f.write(data); h.update(data)
            off += len(data); written += len(data)
    log(f"carved {part['name']}: {written} bytes, sha256={h.hexdigest()[:16]}…")
    return {"name": part["name"], "bytes": written, "sha256": h.hexdigest()}


# ----------------------------------------------------------------------------- password patch
IDENTITY_HINTS = ["uni", "userdata"]           # partitions that hold per-device identity
SECRET_PATHS = ["/etc/ssh", "/etc/shadow", "/unitree/etc/key",
                "/unitree/etc/ds", "/etc/machine-id", "/etc/NetworkManager"]

def make_hash(password, method="sha512"):
    """Ubuntu-20.04-compatible crypt hash ($6$ = sha512).
    Prefers openssl/mkpasswd (in the offline bundle) so we don't depend on the
    `crypt` stdlib module, which was removed in Python 3.13."""
    tag = "6" if method == "sha512" else "5"
    # 1) openssl passwd -6  (openssl pkg)
    try:
        out = subprocess.run(["openssl", "passwd", f"-{tag}", password],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip().startswith(f"${tag}$"):
            return out.stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    # 2) mkpasswd (whois pkg)
    try:
        m = "sha-512" if method == "sha512" else "sha-256"
        out = subprocess.run(["mkpasswd", "-m", m, password],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip().startswith(f"${tag}$"):
            return out.stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    # 3) crypt module, if this Python still has it (<=3.12)
    try:
        import crypt as _c
        scheme = _c.METHOD_SHA512 if method == "sha512" else _c.METHOD_SHA256
        return _c.crypt(password, _c.mksalt(scheme))
    except Exception:
        return f"(hash unavailable — install openssl or whois; ${tag}$ target)"

def plan_password_patch(target_desc, accounts, password, log=None, apply=False):
    """Produce a patch plan for /etc/shadow. In a real run this must go through
    debugfs/mount (journal-replay + metadata_csum safe) — NEVER raw byte-splice.
    The mock returns the plan; `apply` is intentionally unimplemented here."""
    log = log or (lambda *a, **k: None)
    h = make_hash(password)
    plan = {
        "target": target_desc,
        "accounts": accounts,
        "new_hash": h,
        "method": "$6$ sha512-crypt",
        "engine": "debugfs write (journal-replay + csum-safe)",
        "safety": ["copy-on-write: source dump untouched",
                   "replay/clear ext4 journal (INCOMPAT_RECOVER) first",
                   "re-read /etc/shadow after write to confirm",
                   "backup original shadow into the session log dir"],
        "applied": False,
    }
    for a in accounts:
        log(f"PLAN patch shadow: account '{a}' -> new {plan['method']} hash")
    if apply:
        log("apply=True but the mock refuses real writes; use the production "
            "engine (debugfs) with an explicit --i-understand flag", "WARN")
    return plan


# ----------------------------------------------------------------------------- selftest
def selftest(dump_arg=None, out_dir=None, log=None):
    log = log or Log()
    log("=== rkcore selftest ===")
    # 1) config round-trip (no dump needed)
    rows = [
        {"name": "Loader", "addr": 0, "path": r"C:\img\idbloader.img"},
        {"name": "uboot",  "addr": 0x4000, "path": r"C:\img\uboot.img"},
        {"name": "rootfs", "addr": 0x79000, "path": r"C:\img\rootfs.img"},
    ]
    tmp = os.path.join(out_dir or ".", "_selftest_config.cfg")
    write_config_cfg(rows, tmp)
    back = read_config_cfg(tmp)
    ok = (len(back) == 3 and back[1]["name"] == "uboot"
          and back[1]["addr"] == 0x4000)
    log(f"config.cfg round-trip: {'PASS' if ok else 'FAIL'} "
        f"({os.path.getsize(tmp)} bytes)")
    os.remove(tmp)
    # 2) live dump parse, if given
    if dump_arg:
        parts = SplitDump.autodetect(dump_arg, log)
        log(f"autodetected {len(parts)} part(s): {[os.path.basename(p) for p in parts]}")
        d = SplitDump(parts, log)
        info, plist = parse_gpt(d, log)
        for row in partition_status(d, plist, log):
            log(f"  {row['name']:10} {row['bytes']/2**20:9.1f} MiB  "
                f"start=0x{row['start_byte']:x}  {row['note']}")
        d.close()
    log("=== selftest done ===")
    return True


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="rkcore backend selftest")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--dump", help="dump file / glob / directory to parse")
    ap.add_argument("--out", default=".", help="scratch output dir")
    a = ap.parse_args()
    if a.selftest or a.dump:
        selftest(a.dump, a.out)
    else:
        ap.print_help()
