"""Optional Kitty native VT screen projection for ReaderPty.

Uses Kitty's ordinary restore_scrollback byte parser and native cell inventory.
No window, display server, PTY, ANSI reconstruction, or font rasterizer is used.
The cell geometry is native terminal layout, not a pixel screenshot.
"""

import importlib
from pathlib import Path
import sys
from types import SimpleNamespace


def _native_screen():
    try:
        module = importlib.import_module('kitty.fast_data_types')
    except ImportError:
        # Distribution installs keep Kitty's Python modules outside site-packages.
        paths = [str(p) for p in (Path('/usr/lib/kitty'), Path('/usr/local/lib/kitty'))
                 if (p / 'kitty/fast_data_types.so').is_file()]
        original = sys.path[:]
        try:
            sys.path[:0] = paths
            module = importlib.import_module('kitty.fast_data_types')
        except ImportError as error:
            raise RuntimeError('Kitty projection requires its installed native Python module') from error
        finally:
            sys.path[:] = original
    for method in ('restore_scrollback', 'cpu_cells', 'resize'):
        if not hasattr(module.Screen, method):
            raise RuntimeError(f'Unsupported Kitty Screen API: missing {method}')
    return module.Screen


class Screen:
    def __init__(self, columns, lines):
        self.columns, self.lines = columns, lines
        # Native default cell geometry, also used by Kitty's Screen constructor.
        self.cell_width, self.cell_height = 10, 20
        self._screen = _native_screen()(None, lines, columns, 1000,
                                        self.cell_width, self.cell_height)
        self._cells = None

    @property
    def cursor(self):
        cursor = self._screen.cursor
        return SimpleNamespace(x=cursor.x, y=cursor.y,
                               hidden=not self._screen.cursor_visible)

    def feed(self, text):
        data = text.encode('utf-8') if isinstance(text, str) else bytes(text)
        # Kitty window.py uses this parser for saved child output. It commits
        # bytes to the native VT parser then calls the same parse_worker as I/O.
        # This Screen has no child thread or competing parser-buffer writer.
        self._screen.restore_scrollback(data)
        self._cells = None

    def cell_rows(self):
        if self._cells is not None:
            return self._cells
        rows = []
        for row in range(self.lines):
            cells = []
            for cell in self._screen.cpu_cells(row):
                geometry = cell['mcd']
                continuation = bool(geometry and (cell['x'] or cell['y']))
                width = geometry['width'] * geometry['scale'] if geometry else 1
                cells.append(dict(text='' if continuation else cell['text'] or ' ',
                                  width=0 if continuation else width,
                                  continuation=continuation))
            rows.append(cells)
        self._cells = rows
        return rows

    @property
    def display(self):
        return [''.join(cell['text'] for cell in row) for row in self.cell_rows()]

    def resize(self, *, lines, columns):
        self._screen.resize(lines, columns)
        self.lines, self.columns = lines, columns
        self._cells = None

    def close(self):
        self._screen = None
        self._cells = None


class Stream:
    def __init__(self, screen):
        self.screen = screen

    def feed(self, text):
        self.screen.feed(text)
