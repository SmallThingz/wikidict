#!/usr/bin/env python3
"""Exercise dict's public CLI and TUI against disposable marked fixtures.

Usage: python3 verify_reader_ux.py --binary /path/to/dict --root ROOT
Requires pyte. The original fixture and existing user state are never modified.
"""

from __future__ import annotations

import argparse
import codecs
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata


DOWN = b"\x1b[B"
DELETE = b"\x1b[3~"
ESCAPE = b"\x1b"
ENTER = b"\r"
FRAME_END = b"\x1b[?2026l"
TITLES = ("cat", "catfish", "École", "ΣΊΣΥΦΟΣ", "МОСКВА")


class CheckFailure(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailure(message)


def normalized(text: str) -> str:
    return unicodedata.normalize("NFC", text)


class ReaderPty:
    def __init__(self, binary: Path, root: Path, width: int, rows: int,
                 output: Path, timeout: float, budget_end: float, pyte_module):
        self.output = output
        self.output.mkdir()
        self.timeout = timeout
        self.budget_end = budget_end
        self.width, self.rows = width, rows
        self.screen = pyte_module.Screen(width, rows)
        self.stream = pyte_module.Stream(self.screen)
        self.decoder = codecs.getincrementaldecoder("utf-8")("strict")
        self.raw = bytearray()
        self.frames = 0
        self.tail = b""
        self.snapshots = []
        self.cli_calls = []
        self.checks = []
        self.closed = False
        self.binary, self.root = binary, root
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, width, 0, 0))
        self.original_termios = termios.tcgetattr(self.slave)
        self.env = os.environ.copy()
        self.env.update(DICT_ROOT=str(root), DICT_LANGUAGE="English",
                        TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8")
        for name, directory in (("XDG_CONFIG_HOME", "config"),
                                ("XDG_DATA_HOME", "data"),
                                ("XDG_CACHE_HOME", "cache")):
            target = root.parent / directory
            target.mkdir(exist_ok=True)
            self.env[name] = str(target)

        def child_terminal() -> None:
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        # No command arguments: DICT_ROOT must be sufficient to start the reader.
        self.process = subprocess.Popen(
            [str(binary)], stdin=self.slave, stdout=self.slave, stderr=self.slave,
            cwd=root, env=self.env, preexec_fn=child_terminal, close_fds=True)
        os.set_blocking(self.master, False)

    def read(self, timeout: float = 0.05) -> bool:
        readable, _, _ = select.select([self.master], [], [], timeout)
        if not readable:
            return False
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            return False
        except OSError as error:
            if error.errno == errno.EIO:
                return False
            raise
        if not data:
            return False
        self.raw.extend(data)
        # Count complete synchronized frames even when a marker spans reads.
        combined = self.tail + data
        self.frames += combined.count(FRAME_END)
        self.tail = combined[-(len(FRAME_END) - 1):]
        self.stream.feed(self.decoder.decode(data))
        return True

    def text(self) -> str:
        return "\n".join(line.rstrip() for line in self.screen.display)

    def header(self) -> tuple[str, int, int, int] | None:
        match = re.search(r"\b(search|saved|history|learn)\s*/\s*(\d+) words\s*/\s*(\d+)/(\d+)",
                          self.screen.display[1])
        return (match[1], *map(int, match.groups()[1:])) if match else None

    def query(self) -> str:
        return normalized(self.screen.display[3][12:].rstrip())

    def page_is(self, page: str, selected: int | None = None,
                count: int | None = None) -> bool:
        header = self.header()
        return bool(header and header[0] == page
                    and (selected is None or header[2] == selected)
                    and (count is None or header[3] == count))

    def wait(self, predicate, label: str, after: int | None = None) -> None:
        deadline = min(time.monotonic() + self.timeout, self.budget_end)
        while time.monotonic() < deadline:
            self.read(min(0.05, max(0, deadline - time.monotonic())))
            if (after is None or self.frames > after) and predicate():
                # A full frame, not an arbitrary sleep, establishes screen state.
                self.checks.append(label)
                return
            if self.process.poll() is not None:
                raise CheckFailure(f"Reader exited {self.process.returncode} while waiting for {label}")
        raise CheckFailure(f"Timed out waiting for {label}\n{self.text()}")

    def send(self, data: bytes | str) -> int:
        before = self.frames
        if isinstance(data, str):
            data = data.encode("utf-8")
        view = memoryview(data)
        while view:
            try:
                written = os.write(self.master, view)
                view = view[written:]
            except BlockingIOError:
                select.select([], [self.master], [], self.timeout)
        return before

    def action(self, keys: bytes | str, predicate, label: str) -> None:
        before = self.send(keys)
        self.wait(predicate, label, after=before)

    def snapshot(self, label: str) -> None:
        require("\ufffd" not in self.text(), f"Replacement character in {label}")
        require(0 <= self.screen.cursor.x < self.width
                and 0 <= self.screen.cursor.y < self.rows,
                f"Cursor outside {self.width}x{self.rows} in {label}")
        name = f"{len(self.snapshots):02d}-{label}.txt"
        (self.output / name).write_text(self.text() + "\n", encoding="utf-8")
        self.snapshots.append({"name": label, "file": name,
                               "columns": self.width, "rows": self.rows})

    def cli(self, command: str, word: str | None = None) -> list[str]:
        argv = [str(self.binary), command]
        if word is not None:
            argv.append(word)
        argv += ["--root", str(self.root)]
        result = subprocess.run(argv, env=self.env, cwd=self.root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                encoding="utf-8", errors="strict",
                                timeout=max(0.01, min(self.timeout, self.budget_end - time.monotonic())))
        self.cli_calls.append({"argv": argv[1:], "returncode": result.returncode,
                               "stdout": result.stdout, "stderr": result.stderr})
        accepted = (0, 1) if command in ("saved", "history") else (0,)
        require(result.returncode in accepted,
                f"CLI {command} failed: {result.returncode}: {result.stderr}")
        words = [line for line in result.stdout.splitlines() if line.strip()]
        if command in ("saved", "history"):
            require(result.returncode == (0 if words else 1),
                    f"CLI {command} exit code disagrees with its result list")
        return words

    def search(self, query: str, count: int, title: str) -> None:
        self.action(b"\x15" + query.encode("utf-8"),
                    lambda: self.page_is("search", 1, count)
                    and self.query() == normalized(query)
                    and title in self.text() and "Searching..." not in self.text(),
                    f"search {query!r} returns {title!r} ({count} matches)")

    def resize(self, columns: int, rows: int | None = None) -> int:
        before = self.frames
        self.width, self.rows = columns, rows or self.rows
        self.screen.resize(lines=self.rows, columns=self.width)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", self.rows, self.width, 0, 0))
        os.killpg(self.process.pid, signal.SIGWINCH)
        return before

    def finish(self, key: bytes) -> None:
        self.send(key)
        deadline = min(time.monotonic() + self.timeout, self.budget_end)
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read(0.05)
        require(self.process.poll() is not None, "Reader did not exit on its quit key")
        while self.read(0):
            pass
        self.decoder.decode(b"", final=True)
        require(self.process.returncode == 0,
                f"Reader exit code was {self.process.returncode}")
        require(termios.tcgetattr(self.slave) == self.original_termios,
                "Reader did not restore the original terminal attributes")
        modes = {}
        entered = set()
        for match in re.finditer(rb"\x1b\[\?([0-9;]+)([hl])", self.raw):
            enabled = match[2] == b"h"
            for item in match[1].split(b";"):
                mode = int(item)
                modes[mode] = enabled
                if enabled:
                    entered.add(mode)
        alternate = entered.intersection({47, 1047, 1049})
        require(bool(alternate), "Reader never entered an alternate terminal screen")
        require(all(modes.get(mode) is False for mode in alternate),
                "Reader left an alternate terminal screen enabled")
        require(modes.get(25) is True, "Reader left the terminal cursor hidden")
        for mode in (2004, 2026):
            if mode in entered:
                require(modes.get(mode) is False, f"Reader left terminal mode {mode} enabled")
        self.checks.extend(["clean exit", "termios restored", "alternate screen restored",
                            "cursor visible", "input and synchronized modes restored"])

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=1)
            except ProcessLookupError:
                pass
        try:
            while self.read(0):
                pass
        finally:
            os.close(self.master)
            os.close(self.slave)
            (self.output / "terminal.ansi").write_bytes(self.raw)
            (self.output / "last-screen.txt").write_text(self.text() + "\n", encoding="utf-8")
            (self.output / "cli.json").write_text(json.dumps(self.cli_calls, ensure_ascii=False, indent=2) + "\n",
                                                 encoding="utf-8")


def exercise(reader: ReaderPty, initial_width: int) -> None:
    reader.wait(lambda: reader.page_is("search", 1, len(TITLES)) and "cat" in reader.text(),
                "no-argument startup through DICT_ROOT")
    reader.snapshot("startup")
    require(reader.cli("saved") == [], "Fixture copy started with saved words")
    require(reader.cli("history") == [], "Preview unexpectedly recorded history before opening a word")

    reader.search("CAT", 2, "catfish")
    reader.action(DOWN, lambda: reader.page_is("search", 1, 2)
                  and reader.screen.cursor.hidden,
                  "first Down focuses the first match without skipping it")
    reader.action(ENTER, lambda: reader.page_is("search", 1, 2)
                  and "READING" in reader.text(), "Enter reads first CAT match")
    require(reader.cli("history") == ["cat"], "First result navigation did not open cat")
    reader.action("s", lambda: "Saved. Press 1" in reader.text(), "save reports success")
    require(reader.cli("saved") == ["cat"], "Save was not persisted while TUI remained open")
    reader.action("1", lambda: reader.page_is("saved", 1, 1) and "cat" in reader.text(),
                  "Saved displays the new word immediately")
    reader.snapshot("saved-immediately")

    reader.cli("save", "catfish")
    reader.cli("unsave", "cat")
    require(reader.cli("saved") == ["catfish"], "Concurrent CLI save/remove did not take effect")

    reader.search("catfish", 1, "catfish")
    reader.action(ENTER, lambda: "READING" in reader.text(), "open second word")
    require(set(reader.cli("history")) == {"cat", "catfish"}, "Reading history missing opened words")
    reader.action("2", lambda: reader.page_is("history", 1, 2), "History displays opened words")
    require(reader.cli("history")[0] == "catfish", "History ordering is not most recent first")
    reader.action(DELETE, lambda: reader.page_is("history", 1, 1)
                  and "Removed from history." in reader.text(), "Delete removes selected history item")
    require(reader.cli("history") == ["cat"], "History deletion did not persist immediately")
    reader.snapshot("history-delete")

    reader.action("5", lambda: "Settings" in reader.text() and "Atmosphere" in reader.text(),
                  "Settings opens")
    reader.action(DOWN * 8, lambda: "Clear history" in reader.text(), "Clear history control reachable")
    reader.action(ENTER, lambda: "Clear history?" in reader.text(), "History clearing requires confirmation")
    require(reader.cli("history") == ["cat"], "History cleared before confirmation")
    reader.action("x", lambda: "History kept." in reader.text(), "History clear can be cancelled")
    require(reader.cli("history") == ["cat"], "Cancelled history clearing changed storage")
    reader.action(ENTER, lambda: "Clear history?" in reader.text(), "History clear can be retried")
    reader.action(ENTER, lambda: "History cleared." in reader.text(), "History clear confirms")
    require(reader.cli("history") == [], "Confirmed history clearing did not persist")
    require(reader.cli("saved") == ["catfish"], "Settings save lost concurrent bookmark changes")
    reader.snapshot("history-clear")

    reader.action("L", lambda: "Library" in reader.text()
                  and "Installed dictionaries" in reader.text()
                  and "English" in reader.text(), "Library lists installed dictionary")
    reader.snapshot("library")
    reader.action(ENTER, lambda: reader.page_is("search", 1, len(TITLES))
                  and reader.query() == "", "Installed dictionary chooser opens selection")

    reader.search("CAT", 2, "catfish")
    reader.action(DOWN, lambda: reader.screen.cursor.hidden, "leave search input for learning")
    reader.action("4", lambda: reader.page_is("learn") and "Recall the meaning." in reader.text(),
                  "Learning opens flashcards")
    reader.action(b"\t", lambda: "Tab changes game." in reader.text()
                  and "6  " in reader.text(), "Learning switches to quiz")
    reader.action(b"\t", lambda: "Your answer:" in reader.text(), "Learning switches to scramble")
    reader.action("é", lambda: "Your answer: é" in normalized(reader.text()),
                  "Scramble accepts its own UTF-8 answer")
    reader.snapshot("learning-answer")
    reader.action(ESCAPE, lambda: reader.page_is("search", 1, 2) and reader.query() == "CAT",
                  "Leaving Learning preserves original search query")

    for query, title in (("éco", "École"), ("σί", "ΣΊΣΥΦΟΣ"), ("мос", "МОСКВА")):
        reader.search(query, 1, title)
    reader.search("éco", 1, "École")
    reader.snapshot("unicode-search")
    for width in (40, 80, 120):
        if width == reader.width:
            continue
        before = reader.resize(width)
        reader.wait(lambda: reader.page_is("search", 1, 1)
                    and reader.query() == "éco" and "École" in reader.text(),
                    f"UTF-8 search survives resize to {width}", after=before)
        reader.snapshot(f"unicode-resize-{width}")
    before = reader.resize(39, 11)
    reader.wait(lambda: "resize to at least" in reader.text(),
                "Undersized terminal shows recovery instruction", after=before)
    before = reader.resize(initial_width, 32)
    reader.wait(lambda: reader.page_is("search", 1, 1) and reader.query() == "éco",
                "Reader recovers from undersized terminal", after=before)
    reader.snapshot("resize-recovered")

    quit_key = {40: b"q", 80: b"\x03", 120: b"\x04"}[initial_width]
    if quit_key == b"q":
        reader.action(DOWN, lambda: reader.screen.cursor.hidden, "q shortcut available outside search")
    reader.finish(quit_key)
    require(reader.cli("saved") == ["catfish"],
            "TUI exit overwrote concurrent CLI save/remove changes")
    reader.checks.extend(["save persisted before exit", "concurrent CLI save preserved",
                          "concurrent CLI removal preserved", "history deletion persisted",
                          "history clear confirmation respected"])


def copy_fixture(source: Path, destination: Path) -> None:
    # Only explicitly marked, non-symlinked fixtures can enter the write workflow.
    for path in source.rglob("*"):
        require(not path.is_symlink(), f"Fixture contains a symlink: {path}")
    ignored = shutil.ignore_patterns(".dict-state", ".dict-cache", ".dict-media")
    shutil.copytree(source, destination, ignore=ignored)
    require((destination / ".reader-fixture").is_file(), "Copied fixture marker missing")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--root", "--fixture-root", dest="fixture_root", type=Path, required=True)
    parser.add_argument("--report", "--report-dir", dest="report_dir", type=Path,
                        help="Parent directory for a new, uniquely named report folder")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="Per-state/CLI timeout in seconds (default: 5)")
    args = parser.parse_args()
    require(0.2 <= args.timeout <= 15, "Timeout must be between 0.2 and 15 seconds")
    binary, source = args.binary.resolve(strict=True), args.fixture_root.resolve(strict=True)
    require(binary.is_file() and os.access(binary, os.X_OK), "--binary is not executable")
    require((source / ".reader-fixture").is_file(), "Refusing an unmarked fixture root")
    require((source / "languages.tsv").is_file(), "Fixture languages.tsv is missing")
    require(any((source / "languages").glob("*.wikblb")), "Fixture contains no language blobs")
    try:
        import pyte
    except ImportError:
        parser.error("pyte is required; install it in the test Python environment")
    parent = args.report_dir.resolve() if args.report_dir else Path.cwd()
    # Never create test reports inside the input dataset or overwrite a report.
    require(parent != source and source not in parent.parents,
            "Report directory must be outside the original fixture")
    parent.mkdir(parents=True, exist_ok=True)
    report_dir = Path(tempfile.mkdtemp(prefix="reader-ux-", dir=parent))
    report = {"binary": str(binary), "fixture": str(source),
              "report_dir": str(report_dir), "status": "passed", "cases": []}
    started = time.monotonic()
    budget_end = started + 110
    for width in (40, 80, 120):
        case = {"width": width, "status": "passed", "checks": [], "snapshots": []}
        reader = None
        case_started = time.monotonic()
        # Only this context's owned copy is removed, including on failure.
        with tempfile.TemporaryDirectory(prefix=f"fixture-{width}-", dir=report_dir) as owned:
            root = Path(owned) / "root"
            try:
                require(time.monotonic() < budget_end, "110-second test budget exhausted")
                copy_fixture(source, root)
                reader = ReaderPty(binary, root, width, 32, report_dir / f"width-{width}",
                                   args.timeout, budget_end, pyte)
                exercise(reader, width)
            except Exception as error:
                case.update(status="failed", error=f"{type(error).__name__}: {error}")
                report["status"] = "failed"
            finally:
                if reader is not None:
                    case["checks"], case["snapshots"] = reader.checks, reader.snapshots
                    try:
                        reader.close()
                    except Exception as error:
                        case.update(status="failed", cleanup_error=f"{type(error).__name__}: {error}")
                        report["status"] = "failed"
        case["elapsed_seconds"] = round(time.monotonic() - case_started, 3)
        report["cases"].append(case)
    report["elapsed_seconds"] = round(time.monotonic() - started, 3)
    (report_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                            encoding="utf-8")
    print(json.dumps({"status": report["status"], "report": str(report_dir / "report.json"),
                      "cases": [{"width": case["width"], "status": case["status"],
                                  "checks": len(case["checks"]),
                                  **({"error": case["error"]} if "error" in case else {})}
                                 for case in report["cases"]],
                      "elapsed_seconds": report["elapsed_seconds"]}, ensure_ascii=False))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CheckFailure, OSError) as error:
        print(json.dumps({"status": "error", "error": str(error)}), file=sys.stderr)
        raise SystemExit(2)
