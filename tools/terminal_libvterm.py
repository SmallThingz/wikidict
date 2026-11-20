"""Optional libvterm.so.0 screen adapter for the existing ReaderPty driver.

Only terminal cells and cursor state are projected. No text is recovered from
escape-sequence payloads or substituted for cells that libvterm rendered.
"""

import ctypes as C
import ctypes.util
from types import SimpleNamespace


class _Pos(C.Structure):
    _fields_ = [('row', C.c_int), ('col', C.c_int)]


class _Rect(C.Structure):
    _fields_ = [('start_row', C.c_int), ('end_row', C.c_int),
                ('start_col', C.c_int), ('end_col', C.c_int)]


class _CellAttrs(C.Structure):
    # Leading native bitfields of VTermScreenCellAttrs in the SONAME 0 ABI.
    _fields_ = [('bold', C.c_uint, 1), ('underline', C.c_uint, 2), ('italic', C.c_uint, 1)]


class _Cell(C.Structure):
    _fields_ = [('chars', C.c_uint32 * 6), ('width', C.c_byte),
                ('attrs', _CellAttrs), ('fg', C.c_ubyte * 4), ('bg', C.c_ubyte * 4)]


_MoveCursor = C.CFUNCTYPE(C.c_int, _Pos, _Pos, C.c_int, C.c_void_p)
_SetProperty = C.CFUNCTYPE(C.c_int, C.c_int, C.c_void_p, C.c_void_p)


class _Callbacks(C.Structure):
    _fields_ = [('damage', C.c_void_p), ('moverect', C.c_void_p),
                ('movecursor', _MoveCursor), ('settermprop', _SetProperty),
                ('bell', C.c_void_p), ('resize', C.c_void_p),
                ('sb_pushline', C.c_void_p), ('sb_popline', C.c_void_p),
                ('sb_clear', C.c_void_p)]


def _load_library():
    name = ctypes.util.find_library('vterm')
    if not name:
        raise RuntimeError('The libvterm projection requires libvterm.so.0')
    if name.rsplit('/', 1)[-1] != 'libvterm.so.0':
        raise RuntimeError(f'Unsupported libvterm ABI: {name}')
    lib = C.CDLL(name)
    signatures = {
        'vterm_new': (C.c_void_p, [C.c_int, C.c_int]),
        'vterm_free': (None, [C.c_void_p]),
        'vterm_set_utf8': (None, [C.c_void_p, C.c_int]),
        'vterm_set_size': (None, [C.c_void_p, C.c_int, C.c_int]),
        'vterm_input_write': (C.c_size_t, [C.c_void_p, C.c_char_p, C.c_size_t]),
        'vterm_obtain_screen': (C.c_void_p, [C.c_void_p]),
        'vterm_obtain_state': (C.c_void_p, [C.c_void_p]),
        'vterm_state_get_cursorpos': (None, [C.c_void_p, C.POINTER(_Pos)]),
        'vterm_screen_enable_altscreen': (None, [C.c_void_p, C.c_int]),
        'vterm_screen_set_callbacks': (None, [C.c_void_p, C.POINTER(_Callbacks), C.c_void_p]),
        'vterm_screen_reset': (None, [C.c_void_p, C.c_int]),
        'vterm_screen_get_cell': (C.c_int, [C.c_void_p, _Pos, C.POINTER(_Cell)]),
        'vterm_screen_get_text': (C.c_size_t, [C.c_void_p, C.c_void_p, C.c_size_t, _Rect]),
        'vterm_screen_is_eol': (C.c_int, [C.c_void_p, _Pos]),
    }
    for symbol, (result, arguments) in signatures.items():
        function = getattr(lib, symbol)
        function.restype, function.argtypes = result, arguments
    return lib


class Screen:
    def __init__(self, columns, lines):
        self._vt = None
        self._lib = _load_library()
        self.columns, self.lines = columns, lines
        self._hidden = False
        self._cells = None
        self._display = None
        self._vt = self._lib.vterm_new(lines, columns)
        if not self._vt:
            raise MemoryError('libvterm could not allocate a screen')
        self._lib.vterm_set_utf8(self._vt, 1)
        self._screen = self._lib.vterm_obtain_screen(self._vt)
        self._state = self._lib.vterm_obtain_state(self._vt)
        self._callbacks = _Callbacks(movecursor=_MoveCursor(self._move_cursor),
                                     settermprop=_SetProperty(self._set_property))
        self._lib.vterm_screen_set_callbacks(self._screen, C.byref(self._callbacks), None)
        self._lib.vterm_screen_enable_altscreen(self._screen, 1)
        self._lib.vterm_screen_reset(self._screen, 1)

    def _move_cursor(self, position, old_position, visible, user):
        self._hidden = not bool(visible)
        return 1

    def _set_property(self, prop, value, user):
        if prop == 1:  # VTERM_PROP_CURSORVISIBLE; VTermValue.boolean is an int.
            self._hidden = not bool(C.cast(value, C.POINTER(C.c_int))[0])
        return 1

    @property
    def cursor(self):
        pos = _Pos()
        self._lib.vterm_state_get_cursorpos(self._state, C.byref(pos))
        return SimpleNamespace(x=pos.col, y=pos.row, hidden=self._hidden)

    def _cell_row(self, row):
        cells = []
        for column in range(self.columns):
            cell = _Cell()
            if not self._lib.vterm_screen_get_cell(self._screen, _Pos(row, column), C.byref(cell)):
                raise RuntimeError(f'libvterm did not return cell ({row}, {column})')
            scalars = []
            for scalar in cell.chars:
                if scalar == 0:
                    break
                scalars.append(scalar)
            # For a wide glyph's second cell only the leading sentinel
            # is meaningful. libvterm can retain the old combining tail.
            continuation = cell.chars[0] == 0xffffffff
            text = '' if continuation else ''.join(map(chr, scalars)) or ' '
            projected = dict(text=text, width=int(cell.width), continuation=continuation)
            if cell.attrs.bold:
                projected['bold'] = True
            if cell.attrs.italic:
                projected['italic'] = True
            if cell.attrs.underline:
                projected['underline'] = cell.attrs.underline
            cells.append(projected)
        return cells

    def cell_rows(self):
        if self._cells is None:
            self._cells = [self._cell_row(row) for row in range(self.lines)]
        return self._cells

    @property
    def display(self):
        if self._display is None:
            if self._cells is not None:
                self._display = [''.join(cell['text'] for cell in row) for row in self._cells]
            else:
                # Six Unicode scalars per native cell, up to four UTF-8 bytes each.
                buf = C.create_string_buffer(self.columns * 6 * 4)
                self._display = [self._row_text(row, buf) for row in range(self.lines)]
        return self._display.copy()

    def _row_text(self, row, buf):
        rect = _Rect(row, row + 1, 0, self.columns)
        size = self._lib.vterm_screen_get_text(self._screen, buf, len(buf), rect)
        text = buf[:size]
        # ASCII normally occupies one cell per byte. An erased half of a wide
        # glyph can leave a continuation at the end that get_text omits.
        if text.isascii() and (size == self.columns or
                (size < self.columns and self._lib.vterm_screen_is_eol(self._screen, _Pos(row, size)))):
            return text.decode('ascii').ljust(self.columns)
        return ''.join(cell['text'] for cell in self._cell_row(row))

    def resize(self, *, lines, columns):
        self._lib.vterm_set_size(self._vt, lines, columns)
        self.lines, self.columns = lines, columns
        self._cells = None
        self._display = None

    def feed(self, text):
        data = text.encode('utf-8')
        consumed = self._lib.vterm_input_write(self._vt, data, len(data))
        if consumed != len(data):
            raise RuntimeError(f'libvterm consumed {consumed} of {len(data)} input bytes')
        self._cells = None
        self._display = None

    def close(self):
        if self._vt:
            self._lib.vterm_free(self._vt)
            self._vt = None

    def __del__(self):
        self.close()


class Stream:
    def __init__(self, screen):
        self.screen = screen

    def feed(self, text):
        self.screen.feed(text)
