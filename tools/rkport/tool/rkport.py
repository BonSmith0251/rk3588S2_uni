#!/usr/bin/env python3
# rkport — GUI for the RK3588S2 SOM porter (REAL operations).
# Target: Ubuntu 22.04 amd64 with python3-pyqt5.
#
#   GUI:       python3 rkport.py          (run destructive ops as root: `sudo rkport`)
#   Headless:  python3 rkport.py --selftest [--dump PATH]
#   CLI:       python3 rkport_cli.py ...   (scriptable equivalent)
#
# Analysis + config generation run as any user. Extract/rebuild/patch write
# real data: copy-on-write for patches, verified after. A dry-run toggle
# (default ON) lets you preview every action before arming it.

import sys, os, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rkcore

APP = "RK3588S2 SOM Porter"
LOGDIR = os.path.join(HERE, "..", "logs")

# ---- headless path (no Qt) --------------------------------------------------
if "--selftest" in sys.argv:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--dump"); ap.add_argument("--out", default=".")
    a = ap.parse_args()
    log = rkcore.Log(LOGDIR)
    rkcore.selftest(a.dump, a.out, log); log(f"log: {log.path}"); log.close()
    sys.exit(0)

try:
    from PyQt5 import QtWidgets, QtCore, QtGui
except ImportError:
    sys.stderr.write("PyQt5 not found: sudo apt install python3-pyqt5\n"
                     "Headless: python3 rkport.py --selftest --dump <path>\n")
    sys.exit(2)
import rkops


class Worker(QtCore.QThread):
    line = QtCore.pyqtSignal(str)
    done = QtCore.pyqtSignal(object)
    def __init__(self, fn): super().__init__(); self.fn = fn
    def run(self):
        try: self.done.emit(self.fn(lambda m, l="INFO": self.line.emit(f"{l}: {m}")))
        except Exception as e:
            self.line.emit(f"ERROR: {e}"); self.done.emit(None)


class Main(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(APP + ("  [root]" if rkops.is_root() else "  [user]"))
        self.resize(1120, 800)
        self.dump = None; self.parts = []; self.info = {}
        self.log = rkcore.Log(LOGDIR, sink=self._logline)

        top = QtWidgets.QWidget(); tv = QtWidgets.QVBoxLayout(top)
        # safety bar
        bar = QtWidgets.QHBoxLayout()
        self.dry = QtWidgets.QCheckBox("Dry run (preview only, write nothing)")
        self.dry.setChecked(True)
        bar.addWidget(self.dry)
        if not rkops.is_root():
            warn = QtWidgets.QLabel("⚠ not root — extract/rebuild/patch need "
                                    "`sudo rkport`")
            warn.setStyleSheet("color:#c0392b;")
            bar.addWidget(warn)
        bar.addStretch(1)
        tv.addLayout(bar)

        tabs = QtWidgets.QTabWidget()
        tabs.addTab(self._tab_dump(), "1 · Dump")
        tabs.addTab(self._tab_analyze(), "2 · Analyze")
        tabs.addTab(self._tab_project(), "3 · Project")
        tabs.addTab(self._tab_patch(), "4 · Password")
        tv.addWidget(tabs)
        self.setCentralWidget(top)

        dock = QtWidgets.QDockWidget("Log (saved to logs/)", self)
        self.logview = QtWidgets.QPlainTextEdit(); self.logview.setReadOnly(True)
        self.logview.setStyleSheet("font-family:monospace;font-size:12px;")
        dock.setWidget(self.logview)
        self.addDockWidget(QtCore.Qt.BottomDockWidgetArea, dock)
        self.log(f"{APP} started ({'root' if rkops.is_root() else 'user'}); "
                 f"log {self.log.path}")

    # ---- infra
    def _logline(self, s):
        self.logview.appendPlainText(s)
        self.logview.verticalScrollBar().setValue(
            self.logview.verticalScrollBar().maximum())

    def _busy(self, on):
        self.setEnabled(not on)
        QtWidgets.QApplication.setOverrideCursor(
            QtCore.Qt.WaitCursor) if on else QtWidgets.QApplication.restoreOverrideCursor()

    def _run(self, fn, done=None):
        self._busy(True)
        self._w = Worker(fn)
        self._w.line.connect(lambda s: self.log(s.split(": ", 1)[-1],
                             s.split(":", 1)[0] if ":" in s else "INFO"))
        def _fin(r):
            self._busy(False)
            if done: done(r)
        self._w.done.connect(_fin); self._w.start()

    def _confirm(self, what):
        if self.dry.isChecked(): return True
        if not rkops.is_root():
            QtWidgets.QMessageBox.warning(self, "Need root",
                "Destructive operations require running as root (sudo rkport).")
            return False
        return QtWidgets.QMessageBox.question(self, "Confirm write",
            f"{what}\n\nThis writes real data. Continue?",
            QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No
            ) == QtWidgets.QMessageBox.Yes

    # ---- tab 1
    def _tab_dump(self):
        w = QtWidgets.QWidget(); v = QtWidgets.QVBoxLayout(w)
        row = QtWidgets.QHBoxLayout()
        self.dump_edit = QtWidgets.QLineEdit()
        self.dump_edit.setPlaceholderText("split-dump folder, a single .BIN/.img, or a glob…")
        bf = QtWidgets.QPushButton("File…"); bd = QtWidgets.QPushButton("Folder…")
        bf.clicked.connect(lambda: self._pick(self.dump_edit, False))
        bd.clicked.connect(lambda: self._pick(self.dump_edit, True))
        row.addWidget(self.dump_edit); row.addWidget(bf); row.addWidget(bd)
        v.addLayout(row)
        b = QtWidgets.QPushButton("Detect + open parts"); b.clicked.connect(self._open)
        v.addWidget(b)
        self.dump_info = QtWidgets.QPlainTextEdit(); self.dump_info.setReadOnly(True)
        v.addWidget(self.dump_info)
        return w

    def _pick(self, edit, folder):
        p = (QtWidgets.QFileDialog.getExistingDirectory(self, "Folder") if folder
             else QtWidgets.QFileDialog.getOpenFileName(self, "File")[0])
        if p: edit.setText(p)

    def _open(self):
        arg = self.dump_edit.text().strip()
        if not arg: return
        parts = rkcore.SplitDump.autodetect(arg, self.log)
        if not parts: self.log("no dump parts found", "WARN"); return
        if self.dump: self.dump.close()
        self.dump = rkcore.SplitDump(parts, self.log)
        t = [f"parts ({len(parts)}):"] + [
            f"  {os.path.basename(p):32} {os.path.getsize(p):>14,} B" for p in parts]
        t.append(f"\nvirtual device: {self.dump.total:,} B "
                 f"({self.dump.total/2**30:.2f} GiB)")
        self.dump_info.setPlainText("\n".join(t))

    # ---- tab 2
    def _tab_analyze(self):
        w = QtWidgets.QWidget(); v = QtWidgets.QVBoxLayout(w)
        b = QtWidgets.QPushButton("Parse GPT + capture-completeness check")
        b.clicked.connect(self._analyze); v.addWidget(b)
        self.table = QtWidgets.QTableWidget(0, 6)
        self.table.setHorizontalHeaderLabels(
            ["#","Name","Start LBA","Size","Captured","Note"])
        self.table.horizontalHeader().setStretchLastSection(True)
        v.addWidget(self.table)
        self.sumlbl = QtWidgets.QLabel(""); v.addWidget(self.sumlbl)
        return w

    def _analyze(self):
        if not self.dump: self.log("open a dump first", "WARN"); return
        self.info, self.parts = rkcore.parse_gpt(self.dump, self.log)
        rows = rkcore.partition_status(self.dump, self.parts, self.log)
        self.table.setRowCount(len(rows)); good = 0
        for i, r in enumerate(rows):
            ok = r["raw_captured"] or "DATA-COMPLETE" in r["note"]; good += ok
            vals = [str(r["index"]), r["name"], str(r["start_lba"]),
                    f"{r['bytes']/2**20:.1f} MiB",
                    "yes" if r["raw_captured"] else
                    ("rebuild" if "DATA-COMPLETE" in r["note"] else "NO"), r["note"]]
            for c, val in enumerate(vals):
                it = QtWidgets.QTableWidgetItem(val)
                if c == 4 and not ok: it.setForeground(QtGui.QColor("#c0392b"))
                self.table.setItem(i, c, it)
        self.table.resizeColumnsToContents()
        cov = self.dump.total/self.info["device_bytes"]
        self.sumlbl.setText(f"device {self.info['device_bytes']/1e9:.2f} GB · "
                            f"captured {cov*100:.0f}% · {good}/{len(rows)} usable")

    # ---- tab 3
    def _tab_project(self):
        w = QtWidgets.QWidget(); v = QtWidgets.QVBoxLayout(w)
        row = QtWidgets.QHBoxLayout()
        self.proj_edit = QtWidgets.QLineEdit()
        self.proj_edit.setPlaceholderText("output project folder…")
        b = QtWidgets.QPushButton("Choose…")
        b.clicked.connect(lambda: self._pick(self.proj_edit, True))
        row.addWidget(self.proj_edit); row.addWidget(b); v.addLayout(row)
        hr = QtWidgets.QHBoxLayout()
        hr.addWidget(QtWidgets.QLabel("rootfs target size (GiB, 0 = full fs):"))
        self.tgt = QtWidgets.QDoubleSpinBox(); self.tgt.setRange(0, 64); self.tgt.setValue(8)
        hr.addWidget(self.tgt); hr.addStretch(1); v.addLayout(hr)
        self.sanitize = QtWidgets.QCheckBox(
            "Sanitize identity (unselect uni row) — fleet porting")
        v.addWidget(self.sanitize)
        b2 = QtWidgets.QPushButton("Generate RKDevTool project "
                                   "(carve + rebuild rootfs + config.cfg + verify)")
        b2.clicked.connect(self._generate); v.addWidget(b2)
        self.proj_out = QtWidgets.QPlainTextEdit(); self.proj_out.setReadOnly(True)
        v.addWidget(self.proj_out)
        return w

    def _generate(self):
        if not self.parts: self.log("analyze a dump first", "WARN"); return
        out = self.proj_edit.text().strip()
        if not out: self.log("choose a project folder", "WARN"); return
        if not self._confirm(f"Generate full project into {out} "
                             f"(carves partitions, rebuilds rootfs)."): return
        dry = self.dry.isChecked(); tgt = self.tgt.value(); san = self.sanitize.isChecked()
        os.makedirs(os.path.join(out, "Image"), exist_ok=True)
        parts, dump = self.parts, self.dump
        def job(log):
            rkcore.write_parameter_txt(parts, os.path.join(out, "parameter.txt"))
            log("wrote parameter.txt")
            rows = [{"name":"Loader","addr":0,"path":os.path.join(out,"Image","idbloader.img")},
                    {"name":"Parameter","addr":0,"path":os.path.join(out,"parameter.txt")}]
            for p in parts:
                if not p["name"] or p["name"] == "userdata": continue
                img = os.path.join(out, "Image", f"{p['name']}.img")
                rep = rkcore.ext4_capture_report(dump, p, log)
                if rep.get("ext4") and not rep.get("raw_complete") and rep.get("data_complete"):
                    size = int(tgt*2**30) if tgt else rep["fs_bytes"]
                    rkops.rebuild_rootfs_from_dump(dump, p, img, size, log, dry_run=dry)
                else:
                    rkops.carve(dump, p, img, log, dry_run=dry)
                rows.append({"name":p["name"],"addr":p["start_lba"],"path":img,
                             "selected":0 if (p["name"] in rkcore.IDENTITY_HINTS and san) else 1})
            rkcore.write_config_cfg(rows, os.path.join(out,"config.cfg"))
            log(f"wrote config.cfg ({len(rows)} rows)")
            if not dry: rkops.verify_images(os.path.join(out,"Image"), log)
            return rows
        self.proj_out.clear()
        self._run(job, lambda rows: self.proj_out.setPlainText(
            "config.cfg rows:\n" + "\n".join(
              f"  {r['name']:10} addr=0x{r['addr']:08x} sel={r.get('selected',1)}  "
              f"{os.path.basename(r['path'])}" for r in (rows or []))))

    # ---- tab 4
    def _tab_patch(self):
        w = QtWidgets.QWidget(); v = QtWidgets.QVBoxLayout(w)
        form = QtWidgets.QFormLayout()
        self.pt_mode = QtWidgets.QComboBox()
        self.pt_mode.addItems(["Patch an image file (rootfs.img)",
                               "Patch from the original dump (rootfs → new image)"])
        self.pt_image = QtWidgets.QLineEdit()
        bi = QtWidgets.QPushButton("…"); bi.clicked.connect(
            lambda: self._pick(self.pt_image, False))
        h = QtWidgets.QHBoxLayout(); h.addWidget(self.pt_image); h.addWidget(bi)
        self.pt_out = QtWidgets.QLineEdit(); self.pt_out.setPlaceholderText(
            "output image (dump mode only)")
        form.addRow("Mode:", self.pt_mode)
        form.addRow("Image (rootfs.img):", h)
        form.addRow("Output image:", self.pt_out)
        v.addLayout(form)

        # user enumeration
        ub = QtWidgets.QHBoxLayout()
        blist = QtWidgets.QPushButton("List users in image")
        blist.clicked.connect(self._list_users)
        ball = QtWidgets.QPushButton("Select all")
        blog = QtWidgets.QPushButton("Select login users")
        bnone = QtWidgets.QPushButton("Clear")
        ball.clicked.connect(lambda: self._check_users("all"))
        blog.clicked.connect(lambda: self._check_users("login"))
        bnone.clicked.connect(lambda: self._check_users("none"))
        for b in (blist, ball, blog, bnone): ub.addWidget(b)
        ub.addStretch(1); v.addLayout(ub)

        self.utable = QtWidgets.QTableWidget(0, 5)
        self.utable.setHorizontalHeaderLabels(
            ["✓", "User", "UID", "Password", "Shell"])
        self.utable.horizontalHeader().setStretchLastSection(True)
        self.utable.verticalHeader().setVisible(False)
        v.addWidget(self.utable)

        pf = QtWidgets.QFormLayout()
        self.pt_pw = QtWidgets.QLineEdit()
        pf.addRow("New password (applied to checked users):", self.pt_pw)
        v.addLayout(pf)
        b = QtWidgets.QPushButton("Patch checked accounts (copy-on-write, verified)")
        b.clicked.connect(self._patch); v.addWidget(b)
        self.pt_res = QtWidgets.QPlainTextEdit(); self.pt_res.setReadOnly(True)
        v.addWidget(self.pt_res)
        return w

    def _list_users(self):
        img = self.pt_image.text().strip()
        if not img:
            self.log("choose a rootfs.img first (dump mode: generate a project, "
                     "then point here at Image/rootfs.img)", "WARN"); return
        def job(log): return rkops.list_users(img, log)
        self._run(job, self._fill_users)

    def _fill_users(self, users):
        if not users:
            self.log("no users read — is this a rootfs image?", "WARN"); return
        users = sorted(users, key=lambda u: u["uid"])
        self.utable.setRowCount(len(users))
        for i, u in enumerate(users):
            chk = QtWidgets.QTableWidgetItem()
            chk.setFlags(QtCore.Qt.ItemIsUserCheckable | QtCore.Qt.ItemIsEnabled)
            login = u["has_shell"]
            chk.setCheckState(QtCore.Qt.Checked if u["uid"] == 0
                              else QtCore.Qt.Unchecked)
            chk.setData(QtCore.Qt.UserRole, u["name"])
            self.utable.setItem(i, 0, chk)
            cells = [u["name"], str(u["uid"]), u["shadow_status"], u["shell"]]
            for c, val in enumerate(cells, start=1):
                it = QtWidgets.QTableWidgetItem(val)
                if c == 3 and u["shadow_status"] in ("empty",):
                    it.setForeground(QtGui.QColor("#c0392b"))
                if not login:
                    it.setForeground(QtGui.QColor("#8a8a8a"))
                self.utable.setItem(i, c, it)
        self.utable.resizeColumnsToContents()
        self.log(f"listed {len(users)} accounts; root pre-checked")

    def _check_users(self, which):
        for i in range(self.utable.rowCount()):
            it = self.utable.item(i, 0)
            shell = self.utable.item(i, 4).text()
            login = shell not in (
                "", "/usr/sbin/nologin", "/sbin/nologin", "/bin/false",
                "/usr/bin/false", "/bin/sync", "/usr/bin/sync")
            if which == "all": it.setCheckState(QtCore.Qt.Checked)
            elif which == "none": it.setCheckState(QtCore.Qt.Unchecked)
            elif which == "login":
                it.setCheckState(QtCore.Qt.Checked if login else QtCore.Qt.Unchecked)

    def _checked_accounts(self):
        out = []
        for i in range(self.utable.rowCount()):
            it = self.utable.item(i, 0)
            if it and it.checkState() == QtCore.Qt.Checked:
                out.append(it.data(QtCore.Qt.UserRole) or self.utable.item(i, 1).text())
        return out

    def _patch(self):
        accts = self._checked_accounts()
        pw = self.pt_pw.text()
        if not pw: self.log("enter a password", "WARN"); return
        if not accts:
            self.log("check at least one account (use 'List users' first)", "WARN")
            return
        dry = self.dry.isChecked()
        dump_mode = self.pt_mode.currentIndex() == 1
        if not self._confirm(f"Patch {len(accts)} account(s): {', '.join(accts)} "
                             f"({'from dump' if dump_mode else 'in image'})."): return
        def job(log):
            if dump_mode:
                if not self.parts: raise rkops.OpError("analyze a dump first")
                p = next((x for x in self.parts if x["name"] == "rootfs"), None)
                if not p: raise rkops.OpError("no rootfs partition")
                out = self.pt_out.text().strip() or os.path.join(
                    os.path.dirname(self.dump.paths[0]), "rootfs_patched.img")
                return rkops.patch_shadow_in_dump(self.dump, p, out, accts, pw, log,
                                                  dry_run=dry)
            else:
                img = self.pt_image.text().strip()
                if not img: raise rkops.OpError("choose an image")
                return rkops.patch_shadow(img, accts, pw, log, cow=True, dry_run=dry)
        self.pt_res.clear()
        self._run(job, lambda r: self.pt_res.setPlainText(
            json.dumps({k: r[k] for k in r if k != "hash"}, indent=2) if r
            else "failed — see log"))


def main():
    app = QtWidgets.QApplication(sys.argv)
    Main().show()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main()
