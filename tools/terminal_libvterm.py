"""Optional libvterm.so.0 screen adapter for the existing ReaderPty driver.

Only terminal cells and cursor state are projected. No text is recovered from
escape-sequence payloads or substituted for cells that libvterm rendered.
"""

import ctypes as C
import ctypes.util
from types import SimpleNamespace


class _Pos(C.Structure):
    _fields_ = [('row', C.c_int), ('col', C.c_int)]


class _Cell(C.Structure):
    # Public VTermScreenCell layout in libvterm's SONAME 0 API. Attributes and
    # colours are opaque here; only the native character array/width are used.
    _fields_ = [('chars', C.c_uint32 * 6), ('width', C.c_byte),
                ('attrs', C.c_uint), ('fg', C.c_ubyte * 4), ('bg', C.c_ubyte * 4)]


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

    def cell_rows(self):
        if self._cells is None:
            rows = []
            for row in range(self.lines):
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
                    continuation = scalars == [0xffffffff]
                    text = '' if continuation else ''.join(map(chr, scalars)) or ' '
                    cells.append(dict(text=text, width=int(cell.width), continuation=continuation))
                rows.append(cells)
            self._cells = rows
        return self._cells

    @property
    def display(self):
        # A wide-cell continuation contributes no second character; native
        # blank cells contribute spaces. Cell coordinates remain in cell_rows.
        return [''.join(cell['text'] for cell in row) for row in self.cell_rows()]

    def resize(self, *, lines, columns):
        self._lib.vterm_set_size(self._vt, lines, columns)
        self.lines, self.columns = lines, columns
        self._cells = None

    def feed(self, text):
        data = text.encode('utf-8')
        consumed = self._lib.vterm_input_write(self._vt, data, len(data))
        if consumed != len(data):
            raise RuntimeError(f'libvterm consumed {consumed} of {len(data)} input bytes')
        self._cells = None

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
