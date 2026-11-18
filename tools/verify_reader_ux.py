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


def reader_identity(pid: int) -> tuple[int, int, int, int, int]:
    path = Path("/proc") / str(pid)
    fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
    return (int(fields[19]), int(fields[1]), int(fields[2]),
            int(fields[3]), path.stat().st_uid)


class OwnedReaderProcess:
    """A held pidfd for the directly launched TUI, never a process group."""
    def __init__(self, pid: int):
        self.pid = pid
        self.fd = os.pidfd_open(pid)
        try:
            self.identity = reader_identity(pid)
            require(self.identity[1:] == (os.getpid(), pid, pid, os.getuid()),
                    "Reader process ownership differs at launch")
        except BaseException:
            os.close(self.fd)
            raise

    def send(self, signum: int) -> bool:
        try:
            if reader_identity(self.pid) != self.identity:
                return False
            signal.pidfd_send_signal(self.fd, signum)
            return True
        except (FileNotFoundError, ProcessLookupError):
            return False

    def close(self) -> None:
        os.close(self.fd)


class ReaderPty:
    def __init__(self, binary: Path, root: Path, width: int, rows: int,
                 output: Path, timeout: float, budget_end: float, pyte_module, *,
                 force_color: bool = False, language: str | None = "English", kind: str = "language",
                 tui_args: tuple[str, ...] = ()):
        require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"),
                "pidfd signaling is required for Reader ownership")
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
        self.projected = 0
        self.snapshots = []
        self.cli_calls = []
        self.checks = []
        self.closed = False
        self.binary, self.root, self.kind = binary, root, kind
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, width, 0, 0))
        self.original_termios = termios.tcgetattr(self.slave)
        self.env = os.environ.copy()
        self.env.update(DICT_ROOT=str(root), TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8")
        if language is None:
            self.env.pop("DICT_LANGUAGE", None)
        else:
            self.env["DICT_LANGUAGE"] = language
        for name, directory in (("XDG_CONFIG_HOME", "config"),
                                ("XDG_DATA_HOME", "data"),
                                ("XDG_CACHE_HOME", "cache")):
            target = root.parent / directory
            target.mkdir(exist_ok=True)
            self.env[name] = str(target)

        def child_terminal() -> None:
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        argv = [str(binary)]
        if force_color or kind != "language" or tui_args:
            argv.append("tui")
        if kind != "language":
            argv.extend(("--kind", kind))
        if force_color:
            argv.extend(("--color", "always"))
        argv.extend(tui_args)
        self.launch = {"argv": argv, "color_mode": "always" if force_color else "auto",
                       "NO_COLOR_present": "NO_COLOR" in self.env, "TERM": self.env.get("TERM")}
        self.process = subprocess.Popen(
            argv, stdin=self.slave, stdout=self.slave, stderr=self.slave,
            cwd=root, env=self.env, preexec_fn=child_terminal, close_fds=True)
        try:
            self.owned_process = OwnedReaderProcess(self.process.pid)
        except BaseException as error:
            # poll() reaps an already-exited direct child without sending a signal.
            returncode = self.process.poll()
            # Unknown ownership is never repaired by signalling an unverified PID.
            os.close(self.master)
            os.close(self.slave)
            raise CheckFailure(
                f"Reader ownership capture failed; direct child returncode={returncode!r}") from error
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
        old_length = len(self.raw)
        self.raw.extend(data)
        # One read can end midway through the *next* redraw. A predicate must
        # see only committed synchronized frames, even if a marker was split.
        last = self.raw.rfind(FRAME_END, max(self.projected, old_length - len(FRAME_END) + 1))
        if last >= 0:
            end = last + len(FRAME_END)
            self.frames += self.raw.count(FRAME_END, self.projected, end)
            self.stream.feed(self.decoder.decode(self.raw[self.projected:end]))
            self.projected = end
        return True

    def text(self) -> str:
        return "\n".join(line.rstrip() for line in self.screen.display)

    def header(self) -> tuple[str, int, int, int] | None:
        match = re.search(r"\b(search|saved|history|learn)\s*/\s*(\d+) words?\s*/\s*(\d+)/(\d+)",
                          self.screen.display[1])
        return (match[1], *map(int, match.groups()[1:])) if match else None

    def entry_focused(self) -> bool:
        # The split view also shows READING while only previewing a match.
        # Only entry focus emits readingHints. Match its complete footer and
        # width choice, rather than accepting a heading or a partial hint.
        wide = "Esc results  / search  ↑↓ scroll  PgUp/PgDn page  [ ] section  e fold  d all  s save  ? help"
        compact = "Esc back ↑↓ e fold d details ? help"
        # Every scalar in these two fixed hints occupies one terminal cell.
        expected = wide if len(wide) <= max(0, self.width - 4) else compact
        return self.screen.display[self.rows - 2].strip() == expected

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
        deadline = min(time.monotonic() + self.timeout, self.budget_end)
        while view:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CheckFailure(f"Timed out sending Reader input ({len(view)} bytes remaining)")
            try:
                written = os.write(self.master, view)
                view = view[written:]
            except BlockingIOError:
                # A Reader flushing its frame cannot consume more keystrokes
                # until the master drains output. Keep complete frames for wait().
                readable, _, _ = select.select([self.master], [self.master], [], remaining)
                if readable:
                    self.read(0)
                if self.process.poll() is not None:
                    raise CheckFailure(f"Reader exited {self.process.returncode} while receiving input")
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

    def cli(self, command: str, word: str | None = None, *options: str) -> list[str]:
        argv = [str(self.binary), command]
        if word is not None:
            argv.append(word)
        argv.extend(options)
        argv += ["--root", str(self.root)]
        if self.kind != "language":
            argv.extend(("--kind", self.kind))
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
        require(self.owned_process.send(signal.SIGWINCH),
                "Reader identity unavailable during resize")
        return before

    def finish(self, key: bytes) -> None:
        self.send(key)
        deadline = min(time.monotonic() + self.timeout, self.budget_end)
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read(0.05)
        require(self.process.poll() is not None, "Reader did not exit on its quit key")
        while self.read(0):
            pass
        self.stream.feed(self.decoder.decode(self.raw[self.projected:], final=True))
        self.projected = len(self.raw)
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
        try:
            if self.process.poll() is None:
                try:
                    self.owned_process.send(signal.SIGTERM)
                    self.process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    self.owned_process.send(signal.SIGKILL)
                    self.process.wait(timeout=1)
                except ProcessLookupError:
                    pass
        finally:
            try:
                while self.read(0):
                    pass
            finally:
                self.owned_process.close()
                os.close(self.master)
                os.close(self.slave)
                (self.output / "terminal.ansi").write_bytes(self.raw)
                (self.output / "last-screen.txt").write_text(self.text() + "\n", encoding="utf-8")
                (self.output / "cli.json").write_text(json.dumps(self.cli_calls, ensure_ascii=False, indent=2) + "\n",
                                                     encoding="utf-8")


def exercise(reader: ReaderPty, initial_width: int) -> None:
    reader.wait(lambda: reader.page_is("search", 1, len(TITLES)) and "cat" in reader.text()
                and "Enter read" in reader.screen.display[-2]
                and ("Ctrl-C quit" if reader.width >= 81 else "^C quit") in reader.screen.display[-2],
                "no-argument startup through DICT_ROOT")
    reader.snapshot("startup")
    require(reader.cli("saved") == [], "Fixture copy started with saved words")
    require(reader.cli("history") == [], "Preview unexpectedly recorded history before opening a word")

    reader.action(b"\x15missing-fixture-word", lambda: reader.page_is("search", count=0)
                  and reader.text().count("No matching words.") == 1,
                  "empty search shows one explanation")
    reader.search("CAT", 2, "catfish")
    reader.action(DOWN, lambda: reader.page_is("search", 1, 2)
                  and reader.screen.cursor.hidden,
                  "first Down focuses the first match without skipping it")
    reader.action(ENTER, lambda: reader.page_is("search", 1, 2)
                  and "READING" in reader.text() and reader.entry_focused(),
                  "Enter reads first CAT match")
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
    reader.action(ENTER, lambda: "READING" in reader.text() and reader.entry_focused(),
                  "open second word")
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


def latest_rendered_query_frame(raw: bytes | bytearray, after_frame: int = -1) -> tuple[bytes, str] | None:
    """Read the exact UTF-8 search field from the last complete Reader frame."""
    raw = bytes(raw)
    if raw.count(FRAME_END) <= after_frame:
        return None
    end = raw.rfind(FRAME_END)
    if end < 0:
        return None
    start = raw.rfind(b"\x1b[?2026h", 0, end)
    if start < 0:
        return None
    frame = raw[start:end + len(FRAME_END)]
    if FRAME_END in frame[:-len(FRAME_END)]:
        return None
    field = b"\x1b[4;13H"
    at = frame.find(field)
    if at < 0:
        return None
    # State.draw writes this field once via put(): cursor, base/style SGR, UTF-8.
    # The later caret placement may reuse the same coordinates; use the first.
    match = re.match(rb"(?:\x1b\[[0-9;:]*m)*([^\x1b]*)", frame[at + len(field):])
    if match is None:
        return None
    try:
        query = match[1].decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None
    return frame, query


def exercise_spacing_mark_editing(reader: ReaderPty) -> None:
    """Use raw query frames because pinned pyte drops zero-cell Mc characters."""
    initial_width = reader.width
    cluster = "\u0915\u093e"
    last_watermark = -1

    def query_is(expected: str, after_frame: int) -> bool:
        captured = latest_rendered_query_frame(reader.raw, after_frame)
        return (captured is not None and captured[1] == expected
                and reader.page_is("search") and "Searching..." not in reader.text()
                and (not expected.isascii() or reader.query() == expected))

    def action(keys: bytes | str, expected: str, label: str, all_results: bool = False) -> None:
        nonlocal last_watermark
        last_watermark = reader.send(keys)
        reader.wait(lambda: query_is(expected, last_watermark)
                    and (not all_results or reader.page_is("search", 1, len(TITLES))),
                    label, after=last_watermark)

    def snapshot(label: str, expected: str) -> None:
        captured = latest_rendered_query_frame(reader.raw, last_watermark)
        require(captured is not None and captured[1] == expected, "raw query spelling changed before capture")
        prefix = f"{len(reader.snapshots):02d}-{label}"
        frame_file, query_file = prefix + ".query-frame.ansi", prefix + ".query.txt"
        (reader.output / frame_file).write_bytes(captured[0])
        (reader.output / query_file).write_text(captured[1] + "\n", encoding="utf-8")
        reader.snapshot(label)
        reader.snapshots[-1].update(query_frame=frame_file, query_text=query_file,
                                   after_frame=last_watermark,
                                   completed_frame_count=bytes(reader.raw).count(FRAME_END),
                                   query_oracle="exact UTF-8 from completed raw PTY frame",
                                   pyte_query_projection_authoritative=False)

    for width in (80, 40, 120):
        if width != reader.width:
            before = reader.resize(width)
            reader.wait(lambda: query_is("", before) and reader.page_is("search", 1, len(TITLES)),
                        f"empty query survives resize to {width}", after=before)
        action(cluster + "x", cluster + "x",
               "enter Devanagari spacing-mark cluster with exact raw query spelling")
        action(b"\x1b[H\x1b[CQ", cluster + "Qx",
               "Home Right inserts after the complete spacing-mark cluster")
        snapshot(f"spacing-mark-right-insert-{width}", cluster + "Qx")
        action(b"\x15" + (cluster + "x").encode("utf-8"), cluster + "x",
               "reset spacing-mark delete query")
        action(b"\x1b[H" + DELETE, "x",
               "Home Delete removes the complete spacing-mark cluster")
        snapshot(f"spacing-mark-delete-{width}", "x")
        action(b"\x15" + cluster.encode("utf-8"), cluster,
               "reset spacing-mark backspace query")
        action(b"\x1b[F\x7f", "",
               "End Backspace removes the complete cluster and restores all results", all_results=True)
        snapshot(f"spacing-mark-backspace-{width}", "")
    if reader.width != initial_width:
        before = reader.resize(initial_width)
        reader.wait(lambda: query_is("", before) and reader.page_is("search", 1, len(TITLES)),
                    "restore initial width after spacing-mark editing", after=before)


def latest_query_projection(raw: bytes | bytearray, after_frame: int = -1) -> tuple[bytes, str, int] | None:
    """Bind exact safe query spelling and the visible caret to one fresh frame."""
    captured = latest_rendered_query_frame(raw, after_frame)
    if captured is None:
        return None
    frame, query = captured
    # Search draw terminates with its explicit caret placement and frame end.
    caret = re.search(rb"\x1b\[4;([0-9]+)H\x1b\[\?25h\x1b\[\?2026l$", frame)
    if caret is None:
        return None
    return frame, query, int(caret[1])


def exercise_escaped_query_editing(reader: ReaderPty) -> None:
    """Edit original UTF-8 controls while observing their safe display projection."""
    initial_width = reader.width
    control = "\u009b"
    escaped = r"\u{9b}"
    accent = "\u0301"
    last_watermark = -1

    def query_is(expected: str, column: int, after_frame: int) -> bool:
        captured = latest_query_projection(reader.raw, after_frame)
        return (captured is not None and captured[1:] == (expected, column)
                and reader.page_is("search") and "Searching..." not in reader.text()
                and not reader.screen.cursor.hidden
                and (reader.screen.cursor.y, reader.screen.cursor.x) == (3, column - 1))

    def action(keys: bytes | str, expected: str, column: int, label: str,
               all_results: bool = False) -> None:
        nonlocal last_watermark
        last_watermark = reader.send(keys)
        reader.wait(lambda: query_is(expected, column, last_watermark)
                    and (not all_results or reader.page_is("search", 1, len(TITLES))),
                    label, after=last_watermark)

    def snapshot(label: str, expected: str, column: int, source_query: str) -> None:
        captured = latest_query_projection(reader.raw, last_watermark)
        require(captured is not None and captured[1:] == (expected, column),
                "query projection or caret changed before capture")
        prefix = f"{len(reader.snapshots):02d}-{label}"
        frame_file, query_file = prefix + ".query-frame.ansi", prefix + ".query.txt"
        input_file = prefix + ".expected-source-query.utf8"
        (reader.output / frame_file).write_bytes(captured[0])
        (reader.output / query_file).write_text(captured[1] + "\n", encoding="utf-8")
        (reader.output / input_file).write_bytes(source_query.encode("utf-8"))
        reader.snapshot(label)
        reader.snapshots[-1].update(query_frame=frame_file, query_text=query_file,
                                   expected_source_query=input_file, caret_row=4,
                                   caret_column=column, after_frame=last_watermark,
                                   completed_frame_count=bytes(reader.raw).count(FRAME_END),
                                   query_oracle="exact safe UTF-8 and caret from same completed raw PTY frame",
                                   source_query_oracle="expected test input; original-byte editing checked by actions",
                                   pyte_query_projection_authoritative=False)

    for width, count, visible_count, caret in ((80, 12, 10, 74), (40, 4, 3, 32)):
        if width != reader.width:
            before = reader.resize(width)
            reader.wait(lambda: query_is("", 13, before)
                        and reader.page_is("search", 1, len(TITLES)),
                        f"empty query survives escaped-query resize to {width}", after=before)
        query = "a" + control + "b"
        action(query, "a" + escaped + "b", 21,
               "escaped C1 query caret follows its safe display cells")
        snapshot(f"escaped-query-caret-{width}", "a" + escaped + "b", 21, query)
        action(b"\x1b[H\x1b[C\x1b[CQ", "a" + escaped + "Qb", 21,
               "Home Right Right inserts after one original C1 scalar")
        action(b"\x1b[H\x1b[C" + DELETE, "aQb", 14,
               "Delete removes the original C1 scalar, not an escape spelling character")
        snapshot(f"escaped-query-source-delete-{width}", "aQb", 14, "aQb")
        query = control * count + "x"
        action(b"\x15" + query.encode("utf-8"), escaped * visible_count + "x", caret,
               "escaped query viewport clips only complete original clusters")
        snapshot(f"escaped-query-viewport-{width}", escaped * visible_count + "x", caret, query)
        query = control + accent + "x"
        action(b"\x15" + query.encode("utf-8"), escaped + accent + "x", 20,
               "escaped control and combining mark share a complete display cluster")
        snapshot(f"escaped-query-combining-{width}", escaped + accent + "x", 20, query)
        action(b"\x1b[F\x7f", escaped + accent, 19,
               "End Backspace removes following ASCII without changing escaped cluster")
        action(b"\x7f", "", 13,
               "Backspace removes the original control plus combining mark together", all_results=True)
        snapshot(f"escaped-query-combining-backspace-{width}", "", 13, "")
    if reader.width != initial_width:
        before = reader.resize(initial_width)
        reader.wait(lambda: query_is("", 13, before) and reader.page_is("search", 1, len(TITLES)),
                    "restore initial width after escaped-query editing", after=before)


def exercise_swatch(reader: ReaderPty, initial_width: int) -> None:
    """One actual typed-fixture PTY route; historical UX workflow is not replayed."""
    reader.wait(lambda: reader.page_is("search", 1, len(TITLES)), "swatch fixture startup")
    exercise_spacing_mark_editing(reader)
    exercise_escaped_query_editing(reader)
    reader.search("CAT", 2, "catfish")
    reader.action(DOWN, lambda: reader.screen.cursor.hidden, "focus first swatch fixture result")
    reader.action(ENTER, lambda: reader.entry_focused(), "read swatch fixture cat")
    label = "Color sample #ffff00"
    reader.action("d", lambda: label in reader.text(), "details exposes typed swatch")

    def sample_and_reset() -> bool:
        label_cells = []
        sample = False
        for y, line in enumerate(reader.screen.display):
            start = line.find(label)
            if start >= 0:
                label_cells.extend(reader.screen.buffer[y][x] for x in range(start, start + len(label)))
                if start >= 5:
                    cells = reader.screen.buffer[y]
                    sample = (cells[start - 5].data == "[" and cells[start - 2].data == "]"
                              and cells[start - 4].data == cells[start - 3].data == " "
                              and cells[start - 4].bg == cells[start - 3].bg == "ffff00")
        return (sample and len(label_cells) == len(label)
                and all(cell.bg != "ffff00" for cell in label_cells)
                and reader.text().count(label) == 1
                and "Valid swatch fallback" not in reader.text()
                and "Malformed swatch fallback" in reader.text()
                and "Unknown swatch fallback" in reader.text())

    reader.wait(sample_and_reset, "actual pyte yellow sample and reset readable label/fallbacks")
    reader.snapshot("swatch-yellow-reset")
    for width in (40, 120, initial_width):
        if width == reader.width:
            continue
        before = reader.resize(width)
        reader.wait(lambda: reader.entry_focused() and sample_and_reset(),
                    f"swatch sample, label and fallback survive resize to {width}", after=before)
        reader.snapshot(f"swatch-resize-{width}")
    # Reuse this session and its marked fixture; no historical workflow replay.
    def parent_selected(title: str) -> bool:
        return any(line.rsplit("│", 1)[-1].strip() == f"> {title}" for line in reader.screen.display)

    reader.action("]", lambda: "> Noun" in reader.text(), "navigate original compiled section 2 Noun")
    reader.action("]", lambda: parent_selected("Personal"), "navigate anchored empty parent at compiled section 3")
    reader.action("e", lambda: parent_selected("Personal") and "Personal table token" in reader.text(),
                  "empty Personal parent has no fold marker and does not fold its child")
    reader.action("]", lambda: "> 1st" in reader.text(), "next section is Personal child at compiled index 4")
    reader.action("e", lambda: "> 1st  [+]" in reader.text() and "Personal table token" not in reader.text()
                  and "Demonstrative table token" in reader.text(), "child toggle uses original index 4 and leaves other child open")
    reader.action("[", lambda: parent_selected("Personal"), "previous section returns to empty Personal parent")
    reader.action("]]", lambda: parent_selected("Demonstratives"), "navigate empty Demonstratives parent at compiled index 5")
    reader.action("e", lambda: parent_selected("Demonstratives") and "Demonstrative table token" in reader.text(),
                  "empty Demonstratives parent has no fold marker and leaves child visible")
    reader.action("]", lambda: "> That, those, the" in reader.text(), "next section is Demonstratives child at original index 6")
    reader.action("e", lambda: "> That, those, the  [+]" in reader.text()
                  and "Demonstrative table token" not in reader.text(), "second child toggle uses original index 6")
    reader.action("[", lambda: parent_selected("Demonstratives"), "return to second empty parent")
    reader.action("d[]", lambda: parent_selected("Demonstratives") and "Demonstrative table token" not in reader.text(),
                  "compact details preserve empty parent and default child folding")
    reader.action("d[]", lambda: parent_selected("Demonstratives") and "Demonstrative table token" in reader.text(),
                  "details reset second child fold without losing parent heading")
    reader.action("[[", lambda: parent_selected("Personal") and "Personal table token" in reader.text(),
                  "details reset first child fold at original compiled index 4")
    reader.action("]]", lambda: parent_selected("Demonstratives"), "return to second parent before narrow resize")
    before = reader.resize(40)
    reader.wait(lambda: reader.entry_focused() and parent_selected("Demonstratives")
                and "Demonstrative table token" in reader.text(), "empty parent navigation survives narrow terminal", after=before)
    reader.snapshot("anchored-parent-narrow")
    reader.action("[[", lambda: parent_selected("Personal"), "narrow previous navigation skips neither parent nor child")
    reader.snapshot("anchored-parent-personal")
    reader.finish(b"q")


def exercise_abbreviations(reader: ReaderPty) -> None:
    """Additional real native-fixture checks; never included in the historical 132."""
    title = "Acupuncture abbreviation sample"
    legacy = "Legacy format abbreviation control"
    meanings = ("derived terms", "uncertain", "learned borrowing", "feminine gender",
                "common gender", "masculine gender", "neuter gender")
    reader.wait(lambda: reader.page_is("search", 1, 2), "native abbreviation fixture startup")
    reader.search("Acupuncture", 1, title)
    reader.action(ENTER, lambda: reader.entry_focused() and "> Abbreviations  [+]" in reader.text(),
                  "native DPR3 authored section opens in focused reading")
    reader.action("e", lambda: "der. ? lbor. f c m n" in reader.text(),
                  "ordinary section unfold exposes native DPR3 compact labels")
    require(all(value not in reader.text() for value in meanings), "Compact view unexpectedly expands explanations")
    reader.snapshot("native-abbreviations-compact")
    reader.action("d", lambda: "Abbreviations" in reader.text()
                  and all(value in reader.text() for value in meanings),
                  "d exposes all seven native abbreviation explanations")
    require("der. ? lbor. f c m n" in reader.text(), "Details replaced compact authored labels")
    reader.snapshot("native-abbreviations-details")
    reader.action("d", lambda: all(value not in reader.text() for value in meanings)
                  and "> Abbreviations  [+]" in reader.text(), "d restores compact section folding")
    reader.action("e", lambda: "der. ? lbor. f c m n" in reader.text()
                  and all(value not in reader.text() for value in meanings),
                  "ordinary unfold restores compact labels without explanations")
    reader.action(ESCAPE, lambda: reader.page_is("search", 1, 1)
                  and not reader.entry_focused(), "Escape returns from abbreviation reading")
    reader.search("Legacy", 1, legacy)
    reader.action(ENTER, lambda: reader.entry_focused() and "Plain control." in reader.text(),
                  "normal navigation reads legacy-format DPR2 control")
    reader.action("d", lambda: "Plain control." in reader.text()
                  and "Abbreviations" not in reader.text()
                  and all(value not in reader.text() for value in meanings),
                  "legacy details contain no stale abbreviation explanations")
    reader.snapshot("native-abbreviations-legacy")
    reader.finish(b"q")


def exercise_unscored_study(reader: ReaderPty, initial_width: int) -> None:
    """Missing structured clues never score; source bullets remain readable."""
    reader.wait(lambda: reader.page_is("search", 1, 2), "study fixture startup")
    original = reader.cli("lookup", "bullet", "--format", "json")

    def scores():
        states = list((reader.root / ".dict-state").glob("*.json"))
        require(len(states) == 1, "one owned study state expected")
        state = json.loads(states[0].read_text())
        return state.get("right", 0), state.get("wrong", 0)

    def unavailable():
        text = reader.text()
        return ("No structured meaning" in text and "o Open entry" in text
                and "Your answer:" not in text and "6  " not in text)

    reader.search("bullet", 1, "bullet")
    reader.action(ENTER, lambda: reader.entry_focused() and "Ουσιαστικό" in reader.text(), "open folded Greek section")
    reader.action("d", lambda: "συνώνυμο" in reader.text(), "ordinary details reveals original Greek bullet")
    reader.action("d", lambda: "συνώνυμο" not in reader.text(), "restore ordinary folding before study")
    reader.cli("save", "bullet")
    reader.action("5", lambda: "Settings" in reader.text(), "select bounded study pool")
    reader.action(DOWN * 13, lambda: "Study pool" in reader.text(), "study pool setting")
    reader.action(b"\x1b[C" * 2, lambda: "Saved words" in reader.text(), "study only saved bullet")
    reader.action(ESCAPE, lambda: reader.page_is("search"), "leave study settings")
    reader.action(DOWN, lambda: reader.screen.cursor.hidden, "leave query for study")
    reader.action("4", lambda: "No structured meaning" in reader.text(), "unscored Cards state")
    reader.action(b"\t", unavailable, "quiz explicitly has no structured clue")
    for event, label in (("6", "quiz digit cannot grade"), (ENTER, "Enter cannot grade missing clue"),
                         (b"\x1b[200~\xce\xbb\x1b[201~", "pasted Unicode cannot answer missing clue")):
        reader.action(event, unavailable, label)
        require(scores() == (0, 0), label + " changed persisted scores")
    before = reader.resize(40, 12)
    reader.wait(lambda: "c Cards  o Open  n Skip" in reader.text(),
                "minimum terminal keeps unscored actions reachable", after=before)
    reader.snapshot("unscored-minimum-terminal")
    before = reader.resize(initial_width, 32)
    reader.wait(unavailable, "restore missing-clue prompt after resize", after=before)
    reader.action("o", lambda: "Unscored entry" in reader.text() and "Ουσιαστικό" in reader.text(),
                  "Open entry honors normal section folding")
    reader.action("d", lambda: "Unscored entry" in reader.text() and "συνώνυμο" in reader.text(),
                  "ordinary details reveals unscored Greek bullet")
    # Each resize must change geometry before requiring a new synchronized frame.
    widths = (80, 40, 120) if initial_width == 40 else (40, 80, 120)
    for width in widths:
        before = reader.resize(width)
        reader.wait(lambda: "Unscored entry" in reader.text() and "συνώνυμο" in reader.text(),
                    f"unscored body survives resize {width}", after=before)
    reader.snapshot("unscored-body")
    reader.action("c", lambda: "Space reveals the entry" in reader.text(), "Cards keeps same unscored entry")
    reader.action(" ", lambda: "συνώνυμο" in reader.text(), "Cards reveals bullet body")
    reader.action("y", lambda: "Unscored entry" in reader.text(), "manual grade cannot score missing meaning")
    reader.action("n", lambda: "No structured meaning" in reader.text(), "Cards skips without scoring")
    reader.action(b"\t", unavailable, "quiz returns to unavailable clue")
    reader.action(" ", unavailable, "quiz skip remains unscored")
    reader.action(b"\t", unavailable, "typing has explicit missing-clue state")
    reader.action("é", unavailable, "typing does not accumulate a hidden answer")
    reader.action(ENTER, unavailable, "typing cannot submit missing clue")
    require(scores() == (0, 0), "missing-clue routes changed right or wrong totals")
    reader.action(ESCAPE, lambda: reader.page_is("search"), "leave unscored study")
    reader.cli("unsave", "bullet")
    reader.cli("save", "café")
    # An ordinary settings save merges bookmarks from the concurrent CLI.
    reader.action(DOWN, lambda: reader.screen.cursor.hidden, "focus before refreshing saved pool")
    reader.action("5", lambda: "Study pool" in reader.text(), "refresh changed saved pool")
    reader.action(b"\x1b[C", lambda: "All words" in reader.text(), "temporarily select all words")
    reader.action(b"\x1b[D", lambda: "Saved words" in reader.text(), "merge and restore saved pool")
    reader.action(ESCAPE, lambda: reader.page_is("search"), "return with current saved pool")
    reader.action(DOWN, lambda: reader.screen.cursor.hidden, "leave query for ordinary study")
    reader.action("4", lambda: "Your answer:" in reader.text(), "ordinary structured meaning restores typing")
    reader.action("café", lambda: "Your answer: café" in normalized(reader.text()), "ordinary Unicode answer")
    reader.action(ENTER, lambda: "Space: next word" in reader.text(), "ordinary typing scores correct answer")
    require(scores() == (1, 0), "ordinary correct typing did not score exactly once")
    reader.action(" ", lambda: "Your answer:" in reader.text(), "next ordinary question")
    reader.action("wrong", lambda: "Your answer: wrong" in reader.text(), "ordinary wrong answer")
    reader.action(ENTER, lambda: "Space: next word" in reader.text(), "ordinary wrong answer graded")
    require(scores() == (1, 1), "ordinary incorrect typing did not score exactly once")
    reader.action(b"\t", lambda: "Recall the meaning." in reader.text(), "ordinary Cards unchanged")
    reader.action(b"\t", lambda: "6  café" in normalized(reader.text()), "ordinary quiz choices restored")
    reader.action("6", lambda: "Space: next word" in reader.text(), "ordinary quiz grades")
    require(scores() == (2, 1), "ordinary quiz did not score exactly once")
    require(reader.cli("lookup", "bullet", "--format", "json") == original,
            "Study changed compiled bullet body or organization")
    reader.snapshot("ordinary-study-restored")
    reader.finish(b"q")


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
    parser.add_argument("--abbreviation-root", type=Path, help="Explicitly marked owned copy of genuine native abbreviation-interop output")
    parser.add_argument("--abbreviation-only", action="store_true", help="Run only the three native abbreviation cases; historical132 are not rerun")
    parser.add_argument("--swatch-only", action="store_true", help="Run only the synthetic typed swatch actual CLI/PTY screen checks and terminal restoration")
    parser.add_argument("--study-only", action="store_true", help="Run only marked missing-meaning and ordinary graded study CLI/PTY controls")
    parser.add_argument("--study-width", type=int, choices=(40, 80, 120),
                        help="Run one initial width with --study-only (default: all three)")
    args = parser.parse_args()
    require(args.study_width is None or args.study_only, "--study-width requires --study-only")
    require(not args.study_only or (not args.swatch_only and not args.abbreviation_only and args.abbreviation_root is None), "--study-only cannot combine with other selections")
    require(not args.swatch_only or (not args.abbreviation_only and args.abbreviation_root is None), "--swatch-only cannot combine with abbreviation selection")
    require(not args.abbreviation_only or args.abbreviation_root is not None, "--abbreviation-only requires --abbreviation-root")
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
    report["historical_cases_executed"] = not (args.abbreviation_only or args.swatch_only or args.study_only)
    report["swatch_only"] = args.swatch_only
    report["study_only"] = args.study_only
    started = time.monotonic()
    budget_end = started + 110
    study_widths = (args.study_width,) if args.study_width is not None else (40, 80, 120)
    for width in (() if args.abbreviation_only else (80,) if args.swatch_only else study_widths):
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
                                   args.timeout, budget_end, pyte, force_color=args.swatch_only)
                if args.swatch_only:
                    case["launch"] = reader.launch
                (exercise_unscored_study if args.study_only else exercise_swatch if args.swatch_only else exercise)(reader, width)
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
    report["abbreviation_cases"] = []
    if args.abbreviation_root is not None:
        annotated_source = args.abbreviation_root.resolve(strict=True)
        require((annotated_source / ".reader-fixture").is_file(), "Unmarked abbreviation fixture refused")
        require(parent != annotated_source and annotated_source not in parent.parents,
                "Reports must remain outside original abbreviation fixture")
        for width in (40, 80, 120):
            case = {"width": width, "status": "passed", "checks": [], "snapshots": []}
            reader = None
            with tempfile.TemporaryDirectory(prefix=f"abbreviations-{width}-", dir=report_dir) as owned:
                root = Path(owned) / "root"
                try:
                    require(time.monotonic() < budget_end, "110-second test budget exhausted")
                    copy_fixture(annotated_source, root)
                    reader = ReaderPty(binary, root, width, 32, report_dir / f"abbreviations-width-{width}",
                                       args.timeout, budget_end, pyte)
                    exercise_abbreviations(reader)
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
            report["abbreviation_cases"].append(case)
    report["elapsed_seconds"] = round(time.monotonic() - started, 3)
    (report_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                            encoding="utf-8")
    print(json.dumps({"status": report["status"], "report": str(report_dir / "report.json"),
                      "cases": [{"width": case["width"], "status": case["status"],
                                  "checks": len(case["checks"]),
                                  **({"error": case["error"]} if "error" in case else {})}
                                 for case in report["cases"]],
                      "elapsed_seconds": report["elapsed_seconds"]}, ensure_ascii=False))
    if args.swatch_only and report["status"] == "passed":
        print("CLI_SWATCH_PTY_PASS", flush=True)
        print("CLI_ANCHORED_PARENT_PTY_PASS", flush=True)
    if args.study_only and report["status"] == "passed":
        print("CLI_UNSCORED_STUDY_PTY_PASS", flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CheckFailure, OSError) as error:
        print(json.dumps({"status": "error", "error": str(error)}), file=sys.stderr)
        raise SystemExit(2)
