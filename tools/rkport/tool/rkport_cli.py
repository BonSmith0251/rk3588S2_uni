#!/usr/bin/env python3
# rkport_cli — real command-line driver for the RK3588S2 SOM porter.
# Every subcommand does real work and logs to logs/ + stdout.
#
#   rkport-cli analyze       --dump DIR
#   rkport-cli project       --dump DIR --out PROJ [--target-gib N] [--sanitize] [--dry-run]
#   rkport-cli extract       --dump DIR --name boot --out boot.img
#   rkport-cli rebuild-rootfs --dump DIR --out rootfs.img [--target-gib 8]
#   rkport-cli patch         --image rootfs.img --accounts root,unitree --password PW
#   rkport-cli patch-dump    --dump DIR --out rootfs_patched.img --accounts root --password PW
#   rkport-cli verify        --dir PROJ/Image
#   rkport-cli chroot-test   --image rootfs.img
import os, sys, argparse, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rkcore, rkops

LOGDIR = os.path.join(HERE, "..", "logs")

def _dump(arg, log):
    parts = rkcore.SplitDump.autodetect(arg, log)
    if not parts:
        raise SystemExit(f"no dump parts found under: {arg}")
    return rkcore.SplitDump(parts, log)

def _gpt(dump, log):
    info, parts = rkcore.parse_gpt(dump, log)
    return info, parts

def cmd_analyze(a, log):
    dump = _dump(a.dump, log)
    info, parts = _gpt(dump, log)
    rows = rkcore.partition_status(dump, parts, log)
    print(json.dumps({"device_bytes": info["device_bytes"],
                      "captured_bytes": dump.total,
                      "partitions": [{k: r[k] for k in
                         ("name","start_lba","bytes","raw_captured","note")}
                         for r in rows]}, indent=2))
    dump.close()

def cmd_extract(a, log):
    dump = _dump(a.dump, log)
    _, parts = _gpt(dump, log)
    p = next((x for x in parts if x["name"] == a.name), None)
    if not p: raise SystemExit(f"no partition named {a.name}")
    rkops.carve(dump, p, a.out, log, dry_run=a.dry_run)
    dump.close()

def cmd_rebuild_rootfs(a, log):
    dump = _dump(a.dump, log)
    _, parts = _gpt(dump, log)
    p = next((x for x in parts if x["name"] == a.name), None)
    if not p: raise SystemExit(f"no partition named {a.name}")
    size = int(a.target_gib * 2**30) if a.target_gib else p["bytes"]
    res = rkops.rebuild_rootfs_from_dump(dump, p, a.out, size, log, dry_run=a.dry_run)
    print(json.dumps(res, indent=2)); dump.close()

def cmd_project(a, log):
    dump = _dump(a.dump, log)
    info, parts = _gpt(dump, log)
    os.makedirs(os.path.join(a.out, "Image"), exist_ok=True)
    rows = [{"name": "Loader", "addr": 0,
             "path": os.path.join(a.out, "Image", "idbloader.img")},
            {"name": "Parameter", "addr": 0,
             "path": os.path.join(a.out, "parameter.txt")}]
    rkcore.write_parameter_txt(parts, os.path.join(a.out, "parameter.txt"))
    log(f"wrote parameter.txt")
    for p in parts:
        if not p["name"] or p["name"] == "userdata":
            continue
        img = os.path.join(a.out, "Image", f"{p['name']}.img")
        rep = rkcore.ext4_capture_report(dump, p, log)
        if (rep.get("ext4") and not rep.get("raw_complete")
                and rep.get("data_complete")):
            size = int(a.target_gib*2**30) if a.target_gib else rep["fs_bytes"]
            rkops.rebuild_rootfs_from_dump(dump, p, img, size, log, dry_run=a.dry_run)
        else:
            rkops.carve(dump, p, img, log, dry_run=a.dry_run)
        sel = 0 if (p["name"] in rkcore.IDENTITY_HINTS and a.sanitize) else 1
        rows.append({"name": p["name"], "addr": p["start_lba"],
                     "path": img, "selected": sel})
    rkcore.write_config_cfg(rows, os.path.join(a.out, "config.cfg"))
    log(f"wrote config.cfg ({len(rows)} rows)")
    if not a.dry_run:
        rkops.verify_images(os.path.join(a.out, "Image"), log)
    print(f"project ready: {a.out}")
    dump.close()

def cmd_list_users(a, log):
    users = rkops.list_users(a.image, log)
    if a.login_only:
        users = rkops.login_users(users)
    print(f"{'USER':<20} {'UID':>6}  {'PWD STATUS':<10} {'SHELL':<20} LOGIN")
    print("-" * 68)
    for u in sorted(users, key=lambda x: x["uid"]):
        login = "yes" if u["has_shell"] else ""
        print(f"{u['name']:<20} {u['uid']:>6}  {u['shadow_status']:<10} "
              f"{u['shell']:<20} {login}")
    print(f"\n{len(users)} accounts. Patch any with: "
          f"--accounts name1,name2  (or --accounts all)")

def cmd_patch(a, log):
    accounts = [x.strip() for x in a.accounts.split(",") if x.strip()]
    res = rkops.patch_shadow(a.image, accounts, a.password, log,
                             cow=not a.in_place, dry_run=a.dry_run)
    print(json.dumps({k: res[k] for k in res if k != "hash"}, indent=2))

def cmd_patch_dump(a, log):
    dump = _dump(a.dump, log)
    _, parts = _gpt(dump, log)
    p = next((x for x in parts if x["name"] == (a.name or "rootfs")), None)
    if not p: raise SystemExit("rootfs partition not found")
    accounts = [x.strip() for x in a.accounts.split(",") if x.strip()]
    size = int(a.target_gib*2**30) if a.target_gib else None
    res = rkops.patch_shadow_in_dump(dump, p, a.out, accounts, a.password, log,
                                     target_size=size, dry_run=a.dry_run)
    print(json.dumps({k: res[k] for k in res if k != "hash"}, indent=2))
    dump.close()

def cmd_verify(a, log):
    r = rkops.verify_images(a.dir, log)
    print(json.dumps(r, indent=2))

def cmd_chroot_test(a, log):
    out = rkops.chroot_test(a.image, log)
    print(json.dumps({k: v[1] for k, v in out.items()}, indent=2))

def main():
    ap = argparse.ArgumentParser(prog="rkport-cli",
        description="RK3588S2 SOM porter — real operations")
    ap.add_argument("--dry-run", action="store_true",
                    help="show what would happen; write nothing")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("analyze"); s.add_argument("--dump", required=True)
    s.set_defaults(fn=cmd_analyze)

    s = sub.add_parser("extract"); s.add_argument("--dump", required=True)
    s.add_argument("--name", required=True); s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_extract)

    s = sub.add_parser("rebuild-rootfs"); s.add_argument("--dump", required=True)
    s.add_argument("--name", default="rootfs"); s.add_argument("--out", required=True)
    s.add_argument("--target-gib", type=float, default=0)
    s.set_defaults(fn=cmd_rebuild_rootfs)

    s = sub.add_parser("project"); s.add_argument("--dump", required=True)
    s.add_argument("--out", required=True); s.add_argument("--target-gib", type=float, default=0)
    s.add_argument("--sanitize", action="store_true",
                   help="unselect identity partitions (uni) for fleet porting")
    s.set_defaults(fn=cmd_project)

    s = sub.add_parser("list-users"); s.add_argument("--image", required=True)
    s.add_argument("--login-only", action="store_true",
                   help="only real login accounts (uid 0 or >=1000 with a shell)")
    s.set_defaults(fn=cmd_list_users)

    s = sub.add_parser("patch"); s.add_argument("--image", required=True)
    s.add_argument("--accounts", default="root",
                   help="comma list, or 'all' for every account in shadow")
    s.add_argument("--password", required=True)
    s.add_argument("--in-place", action="store_true",
                   help="edit the image itself (default: copy-on-write to .patched)")
    s.set_defaults(fn=cmd_patch)

    s = sub.add_parser("patch-dump"); s.add_argument("--dump", required=True)
    s.add_argument("--name", default="rootfs"); s.add_argument("--out", required=True)
    s.add_argument("--accounts", default="root"); s.add_argument("--password", required=True)
    s.add_argument("--target-gib", type=float, default=0)
    s.set_defaults(fn=cmd_patch_dump)

    s = sub.add_parser("verify"); s.add_argument("--dir", required=True)
    s.set_defaults(fn=cmd_verify)

    s = sub.add_parser("chroot-test"); s.add_argument("--image", required=True)
    s.set_defaults(fn=cmd_chroot_test)

    a = ap.parse_args()
    log = rkcore.Log(LOGDIR)
    log(f"rkport-cli {a.cmd} {'(dry-run)' if a.dry_run else ''}")
    try:
        a.fn(a, log)
    except (rkops.OpError, SystemExit) as e:
        log(f"{e}", "ERROR"); log.close(); sys.exit(1)
    log(f"done; log: {log.path}"); log.close()

if __name__ == "__main__":
    main()
