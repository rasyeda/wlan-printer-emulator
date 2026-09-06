#!/usr/bin/env python3
"""
WLAN / LAN thermal printer emulator (ESC/POS raw port 9100).

Emulates a network receipt printer well enough for a real point-of-sale app to
pair with and print to: a subnet connect-scan finds it (plain TCP on :9100), and
any ESC/POS client streams bytes into it.

This is the headless counterpart to the macOS app in this repository. Use it for
CI, for a Linux box, or when you want the decoded output as files rather than in
a window.

Opens a desktop window (Tk) showing each receipt as it prints - no browser
needed. Falls back to writing files only, with --no-gui.

Usage:
    python3 wlan_printer_emulator.py                     # GUI, 0.0.0.0:9100
    python3 wlan_printer_emulator.py --no-gui            # headless
    python3 wlan_printer_emulator.py --port 9101 --out ./jobs
    python3 wlan_printer_emulator.py --ports 9100 9101   # two virtual printers
    python3 wlan_printer_emulator.py --open              # pop each receipt in the browser
    python3 wlan_printer_emulator.py --hang-after 512    # simulate stalled printer
    python3 wlan_printer_emulator.py --reject            # simulate offline printer

Each job writes to --out:
    job-0001.bin        raw bytes exactly as sent
    job-0001.txt        decoded command trace + plain-text receipt
    job-0001.html       paper-like rendering, images inline (browser, optional)
    job-0001-imgN.png   each image, as the printer would burn it

Renders both image paths:
    ESC *   (GS-less bit image) - what printer.image() sends, in 24-dot bands
            that this decoder stitches back into one picture
    GS v 0  (raster) - what printer.imageRaster() sends

Stdlib only. No pip install.
"""

import argparse
import base64
import html
import queue
import shutil
import subprocess
import tempfile
import os
import socket
import struct
import sys
import threading
import time
import webbrowser
import zlib

ESC, GS, FS, DLE = 0x1B, 0x1D, 0x1C, 0x10

_counter_lock = threading.Lock()
_counter = 0


def next_job_id():
    global _counter
    with _counter_lock:
        _counter += 1
        return _counter


def png_from_bits(width, height, bits, scale=1):
    """Encode a 1bpp bitmap (1 = ink) as an 8-bit greyscale PNG. Stdlib only."""
    row_bytes = (width + 7) // 8
    raw = bytearray()
    for y in range(height):
        for _ in range(scale):
            raw.append(0)  # filter type 0
            base = y * row_bytes
            for x in range(width):
                idx = base + (x >> 3)
                byte = bits[idx] if idx < len(bits) else 0
                px = 0 if (byte >> (7 - (x & 7))) & 1 else 255
                raw.extend(bytes([px]) * scale)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB",
                                         width * scale, height * scale, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + chunk(b"IEND", b""))


def ppm_from_bits(width, height, bits, scale=1):
    """Encode a 1bpp bitmap (1 = ink) as a binary P6 PPM.

    Tk 8.5 - which /usr/bin/python3 ships on macOS - cannot read PNG into a
    PhotoImage, but PPM is handled by every Tk build, so the GUI uses this.
    """
    row_bytes = (width + 7) // 8
    out = bytearray(b"P6\n%d %d\n255\n" % (width * scale, height * scale))
    for y in range(height):
        row = bytearray()
        base = y * row_bytes
        for x in range(width):
            idx = base + (x >> 3)
            byte = bits[idx] if idx < len(bits) else 0
            px = b"\x00" if (byte >> (7 - (x & 7))) & 1 else b"\xff"
            row += px * 3 * scale
        out += row * scale
    return bytes(out)


class Style:
    __slots__ = ("align", "bold", "w", "h", "underline", "invert")

    def __init__(self):
        self.align, self.bold, self.w, self.h = "left", False, 1, 1
        self.underline, self.invert = False, False

    def copy(self):
        s = Style()
        s.align, s.bold, s.w, s.h = self.align, self.bold, self.w, self.h
        s.underline, s.invert = self.underline, self.invert
        return s


class EscPosDecoder:
    """Walks an ESC/POS stream into a command trace plus renderable blocks."""

    def __init__(self, data, out_dir, job_name):
        self.d = data
        self.i = 0
        self.out_dir = out_dir
        self.job_name = job_name
        self.trace = []
        self.blocks = []          # ("text", str, Style) | ("img", file, w, h) | ("cut",)
        self.line = ""
        self.style = Style()
        self.line_style = self.style.copy()
        self.images = 0
        # ESC * band accumulator
        self._band_bits = bytearray()
        self._band_w = 0
        self._band_h = 0

    # ---------- helpers ----------

    def log(self, msg):
        self.trace.append(msg)

    def byte(self):
        b = self.d[self.i]
        self.i += 1
        return b

    def take(self, n):
        b = self.d[self.i:self.i + n]
        self.i += n
        return b

    def flush_line(self):
        self.blocks.append(("text", self.line, self.line_style))
        self.line = ""
        self.line_style = self.style.copy()

    def emit_png(self, width, height, bits, kind):
        self.images += 1
        name = f"{self.job_name}-img{self.images}.png"
        with open(os.path.join(self.out_dir, name), "wb") as f:
            f.write(png_from_bits(width, height, bits))
        # sibling PPM so the Tk GUI can display it without PNG support
        with open(os.path.join(self.out_dir, name[:-4] + ".ppm"), "wb") as f:
            f.write(ppm_from_bits(width, height, bits))
        self.blocks.append(("img", name, width, height))
        self.log(f"    -> {kind} {width}x{height} rendered to {name}")
        return name

    # ---------- ESC * band stitching ----------

    def band_add(self, m, n, payload):
        """One ESC * chunk = a 24- (or 8-) dot tall band, n columns wide."""
        bpc = 3 if m in (32, 33) else 1
        rows = bpc * 8
        if self._band_w and self._band_w != n:
            self.band_flush()
        self._band_w = n
        row_bytes = (n + 7) // 8
        for r in range(rows):
            row = bytearray(row_bytes)
            for x in range(n):
                idx = x * bpc + (r >> 3)
                if idx >= len(payload):
                    continue
                if (payload[idx] >> (7 - (r & 7))) & 1:
                    row[x >> 3] |= 0x80 >> (x & 7)
            self._band_bits += row
        self._band_h += rows

    def band_flush(self):
        if not self._band_w:
            return
        self.emit_png(self._band_w, self._band_h, self._band_bits, "ESC * bit image")
        self._band_bits = bytearray()
        self._band_w = self._band_h = 0

    # ---------- main loop ----------

    def run(self):
        d = self.d
        while self.i < len(d):
            c = self.byte()
            if c == ESC:
                self.esc()
            elif c == GS:
                self.band_flush()
                self.gs()
            elif c == FS:
                self.band_flush()
                self.log(f"FS {self.take(1).hex()} (kanji mode)")
            elif c == DLE:
                self.log(f"DLE {self.take(3).hex()} (real-time status request)")
            elif c == 0x0A:
                # the ESC * encoder emits \n after every band; don't break the image
                if not self._band_w:
                    self.flush_line()
            elif c == 0x0D:
                pass
            elif c == 0x09:
                self.line += "\t"
            else:
                self.band_flush()
                self.line += bytes([c]).decode("cp437", "replace")
        self.band_flush()
        if self.line:
            self.flush_line()
        return self

    def esc(self):
        c = self.byte()
        # line-spacing tweaks bracket the image bands; they must not flush them
        if c == 0x33:
            self.log(f"ESC 3 {self.byte()}      line spacing")
            return
        if c == 0x32:
            self.log("ESC 2        default line spacing")
            return
        if c == 0x2A:
            m, nl, nh = self.take(3)
            n = nl | (nh << 8)
            payload = self.take(n * (3 if m in (32, 33) else 1))
            self.log(f"ESC * m={m} n={n}  bit-image band ({len(payload)} bytes)")
            self.band_add(m, n, payload)
            return

        self.band_flush()
        if c == 0x40:
            self.style = Style()
            self.line_style = self.style.copy()
            self.log("ESC @        initialize printer")
        elif c == 0x61:
            n = self.byte()
            self.style.align = ["left", "center", "right"][n] if n < 3 else "left"
            if not self.line:
                self.line_style = self.style.copy()
            self.log(f"ESC a {n}      align {self.style.align}")
        elif c == 0x21:
            n = self.byte()
            self.style.bold = bool(n & 0x08)
            self.style.w = 2 if n & 0x20 else 1
            self.style.h = 2 if n & 0x10 else 1
            self.style.underline = bool(n & 0x80)
            if not self.line:
                self.line_style = self.style.copy()
            self.log(f"ESC ! {n:#04x}   print mode (bold={self.style.bold} "
                     f"w{self.style.w} h{self.style.h})")
        elif c == 0x45:
            self.style.bold = bool(self.byte())
            if not self.line:
                self.line_style = self.style.copy()
            self.log(f"ESC E        bold {self.style.bold}")
        elif c == 0x47:
            self.log(f"ESC G {self.byte()}      double-strike")
        elif c == 0x2D:
            self.style.underline = bool(self.byte())
            self.log(f"ESC -        underline {self.style.underline}")
        elif c == 0x64:
            n = self.byte()
            self.log(f"ESC d {n}      feed {n} lines")
            for _ in range(n):
                self.flush_line()
        elif c == 0x4A:
            self.log(f"ESC J {self.byte()}      feed n dots")
        elif c == 0x74:
            self.log(f"ESC t {self.byte()}      select code page")
        elif c == 0x52:
            self.log(f"ESC R {self.byte()}      international char set")
        elif c == 0x4D:
            self.log(f"ESC M {self.byte()}      select font")
        elif c == 0x63:
            self.log(f"ESC c {self.take(2).hex()}   paper sensor cfg")
        elif c == 0x70:
            m, t1, t2 = self.take(3)
            self.log(f"ESC p {m} {t1} {t2}  *** OPEN CASH DRAWER (pin {m}) ***")
            self.blocks.append(("note", "cash drawer pulse", None))
        else:
            self.log(f"ESC {c:#04x}     (unhandled)")

    def gs(self):
        c = self.byte()
        if c == 0x21:
            n = self.byte()
            self.style.w = (n >> 4) + 1
            self.style.h = (n & 0x0F) + 1
            if not self.line:
                self.line_style = self.style.copy()
            self.log(f"GS ! {n:#04x}    char size w{self.style.w} h{self.style.h}")
        elif c == 0x56:
            m = self.byte()
            extra = ""
            if m in (65, 66):
                extra = f" feed={self.byte()}"
            self.log(f"GS V {m}{extra}     *** CUT PAPER ***")
            if self.line:
                self.flush_line()
            self.blocks.append(("cut",))
        elif c == 0x76:
            self.byte()  # '0'
            m = self.byte()
            xl, xh, yl, yh = self.take(4)
            wbytes = xl | (xh << 8)
            height = yl | (yh << 8)
            payload = self.take(wbytes * height)
            self.log(f"GS v 0 m={m}  raster {wbytes * 8}x{height}")
            self.emit_png(wbytes * 8, height, payload, "GS v 0 raster")
        elif c == 0x6B:
            m = self.byte()
            if m <= 6:
                data = bytearray()
                while self.i < len(self.d) and self.d[self.i] != 0:
                    data.append(self.byte())
                self.i += 1
            else:
                data = self.take(self.byte())
            text = bytes(data).decode("ascii", "replace")
            self.log(f"GS k m={m}    BARCODE '{text}'")
            self.blocks.append(("note", f"barcode: {text}", None))
        elif c == 0x28:
            fn = self.byte()
            pl, ph = self.take(2)
            body = self.take(pl | (ph << 8))
            if fn == 0x6B:
                self.log(f"GS ( k   QR/2D code, {len(body)} bytes")
                if len(body) > 3 and body[:2] == b"1P":
                    self.blocks.append(
                        ("note", "QR: " + body[3:].decode("utf-8", "replace"), None))
            else:
                self.log(f"GS ( {chr(fn)}   graphics, {len(body)} bytes")
        elif c == 0x42:
            self.style.invert = bool(self.byte())
            self.log(f"GS B         reverse {self.style.invert}")
        elif c == 0x4C:
            self.log(f"GS L {self.take(2).hex()}   left margin")
        elif c == 0x57:
            self.log(f"GS W {self.take(2).hex()}   print area width")
        elif c in (0x72, 0x61, 0x66, 0x48, 0x68, 0x77):
            self.log(f"GS {chr(c)} {self.byte()}      parameter")
        else:
            self.log(f"GS {c:#04x}      (unhandled)")


PAGE_CSS = """
body{background:#4a4a4a;margin:0;padding:32px;font-family:-apple-system,sans-serif}
.paper{background:#fff;width:%(px)dpx;margin:0 auto 28px;padding:18px 14px;
  box-shadow:0 4px 18px rgba(0,0,0,.4);
  font-family:"Menlo","DejaVu Sans Mono",monospace;font-size:12px;line-height:1.35;
  color:#111;white-space:pre;overflow-x:auto}
.tear{width:%(px)dpx;margin:0 auto;height:12px;
  background:repeating-linear-gradient(135deg,#fff 0 6px,transparent 6px 12px)}
.b{font-weight:700}.u{text-decoration:underline}
.c{text-align:center}.r{text-align:right}
.inv{background:#111;color:#fff}
img{display:block;margin:8px auto;image-rendering:pixelated;max-width:100%%}
.note{color:#a00;font-style:italic;white-space:normal}
.meta{color:#ddd;font-family:monospace;font-size:12px;text-align:center;margin-bottom:18px}
"""


def render_html(job, decoder, meta, paper_px=380):
    """Lay the blocks out as paper; each CUT starts a new sheet."""
    sheets, cur = [], []
    for block in decoder.blocks:
        kind = block[0]
        if kind == "cut":
            sheets.append(cur)
            cur = []
            continue
        if kind == "text":
            _, text, st = block
            cls = []
            if st.align == "center":
                cls.append("c")
            elif st.align == "right":
                cls.append("r")
            if st.bold:
                cls.append("b")
            if st.underline:
                cls.append("u")
            if st.invert:
                cls.append("inv")
            style = ""
            if st.w > 1 or st.h > 1:
                # a thermal printer scales the glyph cell, so width and height
                # multipliers are independent - mimic with font-size + scaleX
                origin = "center" if st.align == "center" else "left"
                style = (f"font-size:{12 * st.h}px;line-height:1.1;"
                         f"transform:scaleX({st.w / st.h:.3f});"
                         f"transform-origin:{origin}")
            body = html.escape(text) if text.strip() else "&nbsp;"
            cur.append(f"<div class='{' '.join(cls)}' style='{style}'>{body}</div>")
        elif kind == "img":
            _, name, w, h = block
            with open(os.path.join(decoder.out_dir, name), "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            cur.append(f"<img alt='{name}' title='{name} ({w}x{h})' "
                       f"src='data:image/png;base64,{b64}'>")
        elif kind == "note":
            cur.append(f"<div class=note>[{html.escape(block[1])}]</div>")
    sheets.append(cur)

    def blank(sheet):
        return not any("<img" in c or "note" in c
                       or (">" in c and c.rsplit(">", 2)[-2].strip() not in ("", "&nbsp;"))
                       for c in sheet)

    while sheets and blank(sheets[-1]):
        sheets.pop()
    if not sheets:
        sheets = [["<div class=note>[no printable content]</div>"]]

    out = [f"<!doctype html><meta charset=utf-8><title>{job}</title>",
           "<style>" + PAGE_CSS % {"px": paper_px} + "</style>",
           f"<div class=meta>{html.escape(meta)}</div>"]
    for n, sheet in enumerate(sheets):
        out.append("<div class=paper>")
        out.extend(sheet)
        out.append("</div>")
        if n < len(sheets) - 1:
            out.append("<div class=tear title='GS V - cut'></div>")
    return "\n".join(out)


def render_text(decoder, width=48):
    lines = ["+" + "-" * width + "+"]
    for block in decoder.blocks:
        kind = block[0]
        if kind == "text":
            _, text, st = block
            t = text.upper() if st.w > 1 or st.h > 1 else text
            if st.align == "center":
                t = t.center(width)
            elif st.align == "right":
                t = t.rjust(width)
            lines.append("|" + t.ljust(width)[:width] + "|")
        elif kind == "img":
            _, name, w, h = block
            lines.append("|" + f"[image {w}x{h} -> {name}]".center(width)[:width] + "|")
        elif kind == "note":
            lines.append("|" + f"[{block[1]}]".ljust(width)[:width] + "|")
        elif kind == "cut":
            lines.append("+" + "-" * width + "+")
            lines.append(" " * 20 + "  scissors / cut")
            lines.append("+" + "-" * width + "+")
    lines.append("+" + "-" * width + "+")
    return "\n".join(lines)


def looks_like_tsc(data):
    head = data[:200].upper()
    return any(k in head for k in (b"SIZE ", b"GAP ", b"CLS\r\n", b"DIRECTION ", b"PRINT "))


class Job(object):
    """One finished print job, ready to display."""

    def __init__(self, name, addr, port, nbytes, elapsed):
        self.name, self.addr, self.port = name, addr, port
        self.nbytes, self.elapsed = nbytes, elapsed
        self.stamp = time.strftime("%H:%M:%S")
        self.decoder = None       # None for TSC jobs
        self.tsc_text = None
        self.trace = ""
        self.summary = ""

    def label(self):
        return "%s  %s  %5d B  %s" % (self.stamp, self.name, self.nbytes, self.addr)


def process(chunks, addr, port, name, args, started):
    """Write the job files and return a Job for display."""
    job = Job(name, addr[0], port, len(chunks), time.time() - started)

    with open(os.path.join(args.out, name + ".bin"), "wb") as f:
        f.write(chunks)

    meta = ("%s | from %s | port %s | %d bytes | %.2fs"
            % (name, addr[0], port, len(chunks), job.elapsed))
    lines = ["# " + meta, ""]

    if looks_like_tsc(bytes(chunks)):
        job.tsc_text = bytes(chunks).decode("cp437", "replace")
        lines += ["## TSC / TSPL label job (plain-text commands)", "", job.tsc_text]
        job.summary = "TSC label job"
    else:
        dec = EscPosDecoder(bytes(chunks), args.out, name).run()
        job.decoder = dec
        lines += ["## ESC/POS command trace", ""]
        lines += ["  " + t for t in dec.trace]
        lines += ["", "## Rendered receipt", "", render_text(dec)]
        job.summary = "ESC/POS receipt, %d image(s)" % dec.images
        with open(os.path.join(args.out, name + ".html"), "w", encoding="utf-8") as f:
            f.write(render_html(name, dec, meta, args.paper_px))

    job.trace = "\n".join(lines)
    with open(os.path.join(args.out, name + ".txt"), "w", encoding="utf-8") as f:
        f.write(job.trace + "\n")
    return job


def handle(conn, addr, args, port, sink=None):
    name = "job-%04d" % next_job_id()
    started = time.time()
    note = "[%s] :%s <- connection from %s:%s  (%s)" % (
        time.strftime("%H:%M:%S"), port, addr[0], addr[1], name)
    print("\n" + note)

    if args.reject:
        print("  %s: offline mode, closing immediately" % name)
        conn.close()
        return

    conn.settimeout(args.idle_timeout)
    chunks = bytearray()
    try:
        while True:
            if args.hang_after and len(chunks) >= args.hang_after:
                print("  %s: stall mode, no longer reading" % name)
                time.sleep(args.hang_seconds)
                break
            data = conn.recv(65536)
            if not data:
                break
            chunks += data
            if args.slow:
                time.sleep(args.slow)
    except socket.timeout:
        pass
    except OSError as exc:
        print("  %s: socket error %s" % (name, exc))
    finally:
        try:
            conn.close()
        except OSError:
            pass

    if not chunks:
        print("  %s: probe only, 0 bytes (this is how discovery/pairing looks)" % name)
        return

    job = process(chunks, addr, port, name, args, started)
    print("  %s: %d bytes, %s" % (name, job.nbytes, job.summary))
    if sink is not None:
        sink(job)
    elif not args.quiet:
        print(job.trace)


# --------------------------------------------------------------------------
# GUI
# --------------------------------------------------------------------------

class PrinterGUI(object):
    """Tk window that draws each receipt as the printer would lay it on paper."""

    BG = "#4a4a4a"
    PAPER = "#ffffff"
    INK = "#111111"

    def __init__(self, tk, args, ports):
        self.tk = tk
        self.args = args
        self.ports = ports
        self.jobs = []
        self.queue = queue.Queue()
        self._images = []          # PhotoImage refs; Tk garbage-collects otherwise
        self._fonts = {}

        import tkinter.font as tkfont
        self.tkfont = tkfont

        root = tk.Tk()
        self.root = root
        root.title("WLAN printer emulator")
        root.geometry("900x700")
        root.configure(bg=self.BG)

        bar = tk.Frame(root, bg="#2f2f2f", pady=6, padx=8)
        bar.pack(fill="x")
        tk.Label(bar, text="listening on  " + ", ".join(
            "%s:%d" % (ip, ports[0]) for ip in local_ips()) +
            ("  (+%s)" % ", ".join(str(p) for p in ports[1:]) if len(ports) > 1 else ""),
            bg="#2f2f2f", fg="#e8e8e8").pack(side="left")

        self.v_reject = tk.BooleanVar(value=args.reject)
        self.v_stall = tk.BooleanVar(value=bool(args.hang_after))
        tk.Checkbutton(bar, text="offline", variable=self.v_reject,
                       command=self._sync_faults, bg="#2f2f2f", fg="#e8e8e8",
                       selectcolor="#2f2f2f", activebackground="#2f2f2f",
                       activeforeground="#fff").pack(side="right", padx=4)
        tk.Checkbutton(bar, text="stall", variable=self.v_stall,
                       command=self._sync_faults, bg="#2f2f2f", fg="#e8e8e8",
                       selectcolor="#2f2f2f", activebackground="#2f2f2f",
                       activeforeground="#fff").pack(side="right", padx=4)
        tk.Button(bar, text="folder", command=self._reveal,
                  highlightbackground="#2f2f2f").pack(side="right", padx=4)
        tk.Button(bar, text="clear", command=self._clear,
                  highlightbackground="#2f2f2f").pack(side="right", padx=4)
        self.v_trace = tk.BooleanVar(value=False)
        tk.Checkbutton(bar, text="trace", variable=self.v_trace,
                       command=self._toggle_trace, bg="#2f2f2f", fg="#e8e8e8",
                       selectcolor="#2f2f2f", activebackground="#2f2f2f",
                       activeforeground="#fff").pack(side="right", padx=4)

        body = tk.Frame(root, bg=self.BG)
        body.pack(fill="both", expand=True)

        left = tk.Frame(body, bg=self.BG)
        left.pack(side="left", fill="y")
        self.listbox = tk.Listbox(left, width=34, activestyle="none",
                                  bg="#3a3a3a", fg="#e8e8e8",
                                  selectbackground="#0a84ff", highlightthickness=0,
                                  font=("Menlo", 11), borderwidth=0)
        self.listbox.pack(fill="y", expand=True, padx=(8, 4), pady=8)
        self.listbox.bind("<<ListboxSelect>>", self._on_select)

        right = tk.Frame(body, bg=self.BG)
        right.pack(side="left", fill="both", expand=True)

        wrap = tk.Frame(right, bg=self.BG)
        wrap.pack(fill="both", expand=True)
        self.canvas = tk.Canvas(wrap, bg=self.BG, highlightthickness=0)
        sb = tk.Scrollbar(wrap, orient="vertical", command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        self.canvas.pack(side="left", fill="both", expand=True)
        self.canvas.bind_all("<MouseWheel>",
                             lambda e: self.canvas.yview_scroll(-e.delta, "units"))

        self.trace_box = tk.Text(right, height=12, bg="#1f1f1f", fg="#d0d0d0",
                                 font=("Menlo", 10), borderwidth=0,
                                 insertbackground="#fff")

        self.status = tk.Label(root, text="waiting for a print job...",
                               bg="#2f2f2f", fg="#b0b0b0", anchor="w", padx=8)
        self.status.pack(fill="x")

        self._empty_message()
        root.after(120, self._poll)

    # -- plumbing ---------------------------------------------------------

    def submit(self, job):
        """Called from a socket thread; Tk itself is touched only in _poll."""
        self.queue.put(job)

    def _poll(self):
        try:
            while True:
                job = self.queue.get_nowait()
                self.jobs.append(job)
                self.listbox.insert("end", job.label())
                self.listbox.selection_clear(0, "end")
                self.listbox.selection_set("end")
                self.listbox.see("end")
                self._show(job)
        except queue.Empty:
            pass
        self.root.after(120, self._poll)

    def _sync_faults(self):
        self.args.reject = self.v_reject.get()
        self.args.hang_after = 512 if self.v_stall.get() else 0
        self.status.configure(text="printer state: %s" % (
            "offline (refusing jobs)" if self.args.reject else
            "stalling after 512 bytes" if self.args.hang_after else "ready"))

    def _toggle_trace(self):
        if self.v_trace.get():
            self.trace_box.pack(fill="x", side="bottom")
        else:
            self.trace_box.pack_forget()

    def _clear(self):
        self.jobs = []
        self.listbox.delete(0, "end")
        self._empty_message()

    def _reveal(self):
        subprocess.Popen(["open", os.path.abspath(self.args.out)])

    def _on_select(self, _event):
        sel = self.listbox.curselection()
        if sel:
            self._show(self.jobs[sel[0]])

    def _font(self, size, bold, underline):
        key = (size, bold, underline)
        if key not in self._fonts:
            self._fonts[key] = self.tkfont.Font(
                family="Menlo", size=size,
                weight="bold" if bold else "normal",
                underline=1 if underline else 0)
        return self._fonts[key]

    def _empty_message(self):
        self.canvas.delete("all")
        self._images = []
        self.canvas.create_text(
            20, 20, anchor="nw", fill="#9a9a9a", font=("Menlo", 12),
            text="No jobs yet.\n\nPair the app with this machine's IP on port %d,\n"
                 "then print. Receipts appear here." % self.ports[0])

    # -- drawing ----------------------------------------------------------

    def _show(self, job):
        c = self.canvas
        c.delete("all")
        self._images = []
        W = self.args.paper_px
        pad = 16
        x0 = 40
        y = 24

        self.status.configure(text="%s   %s   %d bytes   %.2fs   from %s:%d"
                              % (job.name, job.summary, job.nbytes, job.elapsed,
                                 job.addr, job.port))
        self.trace_box.delete("1.0", "end")
        self.trace_box.insert("1.0", job.trace)

        if job.decoder is None:
            c.create_rectangle(x0, y, x0 + W, y + 40, fill=self.PAPER, outline="")
            c.create_text(x0 + pad, y + 12, anchor="nw", fill=self.INK,
                          font=self._font(11, False, False),
                          text="TSC / TSPL label job - see trace")
            self._scroll(y + 60)
            return

        # split into sheets at each cut
        sheets, cur = [], []
        for b in job.decoder.blocks:
            if b[0] == "cut":
                sheets.append(cur)
                cur = []
            else:
                cur.append(b)
        sheets.append(cur)
        while len(sheets) > 1 and not self._has_content(sheets[-1]):
            sheets.pop()

        for n, sheet in enumerate(sheets):
            y = self._draw_sheet(sheet, x0, y, W, pad) + 6
            if n < len(sheets) - 1:
                c.create_line(x0, y, x0 + W, y, fill="#cfcfcf", dash=(6, 4))
                c.create_text(x0 + W + 8, y, anchor="w", fill="#9a9a9a",
                              font=("Menlo", 9), text="cut")
                y += 18
        self._scroll(y + 30)

    @staticmethod
    def _has_content(sheet):
        for b in sheet:
            if b[0] == "img" or b[0] == "note":
                return True
            if b[0] == "text" and b[1].strip():
                return True
        return False

    def _draw_sheet(self, sheet, x0, y, W, pad):
        c = self.canvas
        top = y
        bg = c.create_rectangle(x0, y, x0 + W, y + 10, fill=self.PAPER,
                                outline="", width=0)
        y += pad

        for b in sheet:
            kind = b[0]
            if kind == "text":
                _, text, st = b
                size = max(8, int(11 * st.h))
                font = self._font(size, st.bold, st.underline)
                if not text.strip():
                    y += font.metrics("linespace")
                    continue
                if st.align == "center":
                    x, anchor = x0 + W // 2, "n"
                elif st.align == "right":
                    x, anchor = x0 + W - pad, "ne"
                else:
                    x, anchor = x0 + pad, "nw"
                item = c.create_text(x, y, anchor=anchor, text=text,
                                     fill=self.INK, font=font)
                if st.invert:
                    bbox = c.bbox(item)
                    rect = c.create_rectangle(bbox, fill=self.INK, outline="")
                    c.tag_lower(rect, item)
                    c.itemconfigure(item, fill=self.PAPER)
                y += font.metrics("linespace")
            elif kind == "img":
                _, name, w, h = b
                ppm = os.path.join(self.args.out, name[:-4] + ".ppm")
                try:
                    img = self.tk.PhotoImage(file=ppm)
                except Exception:
                    c.create_text(x0 + pad, y, anchor="nw", fill="#a00",
                                  font=self._font(10, False, False),
                                  text="[image %dx%d - %s]" % (w, h, name))
                    y += 16
                    continue
                if w > W - 2 * pad:
                    img = img.subsample(int(w / float(W - 2 * pad)) + 1)
                self._images.append(img)
                c.create_image(x0 + W // 2, y + 4, anchor="n", image=img)
                y += img.height() + 10
            elif kind == "note":
                c.create_text(x0 + pad, y, anchor="nw", fill="#b00020",
                              font=self._font(10, False, False),
                              text="[%s]" % b[1])
                y += 16

        y += pad
        c.coords(bg, x0, top, x0 + W, y)
        return y

    def _scroll(self, height):
        self.canvas.configure(scrollregion=(0, 0, self.args.paper_px + 140, height))

    def run(self):
        self.root.mainloop()


def serve(port, args, sink=None):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, port))
    srv.listen(8)
    print("virtual printer listening on %s:%d" % (args.host, port))
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr, args, port, sink),
                         daemon=True).start()


def local_ips():
    ips = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            if info[4][0] not in ips:
                ips.append(info[4][0])
    except OSError:
        pass
    return ips


def load_tk():
    """Import tkinter, relaunching under a Python that has it if necessary."""
    try:
        import tkinter
        return tkinter
    except ImportError:
        pass
    alt = "/usr/bin/python3"          # macOS system Python ships Tk
    if (sys.executable != alt and os.path.exists(alt)
            and not os.environ.get("EMU_TK_RELAUNCH")):
        try:
            subprocess.check_call([alt, "-c", "import tkinter"],
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        except (subprocess.CalledProcessError, OSError):
            return None
        print("this Python has no tkinter; relaunching with %s" % alt)
        os.environ["EMU_TK_RELAUNCH"] = "1"
        os.execve(alt, [alt, os.path.abspath(__file__)] + sys.argv[1:], os.environ)
    return None


def main():
    p = argparse.ArgumentParser(description="ESC/POS WLAN printer emulator")
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=9100)
    p.add_argument("--ports", type=int, nargs="+",
                   help="listen on several ports = several virtual printers")
    p.add_argument("--out", default="./printer-jobs")
    p.add_argument("--no-gui", dest="gui", action="store_false",
                   help="headless: just write files and log to stdout")
    p.add_argument("--paper-px", type=int, default=380,
                   help="paper width in px (380 ~ 80mm, 300 ~ 58mm)")
    p.add_argument("--quiet", action="store_true",
                   help="headless mode: don't echo each receipt to stdout")
    p.add_argument("--idle-timeout", type=float, default=3.0,
                   help="seconds of silence before a job is considered finished")
    p.add_argument("--slow", type=float, default=0.0,
                   help="sleep this many seconds per recv (slow printer)")
    p.add_argument("--hang-after", type=int, default=0,
                   help="stop reading after N bytes (stalled printer)")
    p.add_argument("--hang-seconds", type=float, default=30.0)
    p.add_argument("--reject", action="store_true",
                   help="accept then instantly close (offline printer)")
    args = p.parse_args()

    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass

    os.makedirs(args.out, exist_ok=True)
    ports = args.ports or [args.port]

    print("jobs -> %s" % os.path.abspath(args.out))
    for ip in local_ips():
        print("reachable at %s:%d" % (ip, ports[0]))

    tk = load_tk() if args.gui else None
    if args.gui and tk is None:
        print("\n! tkinter is unavailable, falling back to --no-gui.")
        print("! fix with:  brew install python-tk   (or run with /usr/bin/python3)")

    if tk is not None:
        gui = PrinterGUI(tk, args, ports)
        for port in ports:
            threading.Thread(target=serve, args=(port, args, gui.submit),
                             daemon=True).start()
        try:
            gui.run()          # Tk must own the main thread on macOS
        except KeyboardInterrupt:
            pass
        return

    print("Ctrl-C to stop\n")
    for port in ports[1:]:
        threading.Thread(target=serve, args=(port, args), daemon=True).start()
    try:
        serve(ports[0], args)
    except KeyboardInterrupt:
        print("\nbye")
        sys.exit(0)


if __name__ == "__main__":
    main()
