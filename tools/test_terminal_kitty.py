import unittest

import terminal_kitty


class KittyProjectionTests(unittest.TestCase):
    def screen(self, columns=90, lines=30):
        try:
            screen = terminal_kitty.Screen(columns, lines)
        except RuntimeError as error:
            self.skipTest(str(error))
        self.addCleanup(screen.close)
        return screen

    def test_native_parser_cursor_erase_and_alternate_screen(self):
        screen = self.screen()
        screen.feed(b'main\x1b[?1049h\x1b[2;3H\x1b[31mALTERNATE\x1b[0m\x1b[?25l')
        self.assertIn('ALTERNATE', screen.display[1])
        self.assertEqual((11, 1, True), (screen.cursor.x, screen.cursor.y, screen.cursor.hidden))
        screen.feed(b'\x1b[2;3H\x1b[2K\x1b[?1049l\x1b[?25h')
        self.assertTrue(screen.display[0].startswith('main'))
        self.assertNotIn('ALTERNATE', '\n'.join(screen.display))
        self.assertFalse(screen.cursor.hidden)

    def test_arbitrary_byte_chunks_preserve_full_vt_and_utf8_state(self):
        whole = self.screen()
        chunks = self.screen()
        data = '\x1b[?2026h\x1b[4;8H猫é\x1b[?25l\x1b[?2026l'.encode()
        whole.feed(data)
        for byte in data:
            chunks.feed(bytes([byte]))
        self.assertEqual(whole.cell_rows(), chunks.cell_rows())
        self.assertEqual(vars(whole.cursor), vars(chunks.cursor))
        row = chunks.cell_rows()[3]
        self.assertEqual(('猫', 2, False), (row[7]['text'], row[7]['width'], row[7]['continuation']))
        self.assertEqual(('', 0, True), (row[8]['text'], row[8]['width'], row[8]['continuation']))
        self.assertEqual('é', row[9]['text'])

    def test_native_resize_and_own_cursor_coordinates(self):
        screen = self.screen()
        previous = screen.cell_rows()
        self.assertIs(previous, screen.cell_rows())
        screen.resize(lines=24, columns=45)
        self.assertIsNot(previous, screen.cell_rows())
        previous = screen.cell_rows()
        screen.feed(b'\x1b[24;40HEND')
        self.assertIsNot(previous, screen.cell_rows())
        self.assertEqual((24, 45), (len(screen.cell_rows()), len(screen.cell_rows()[0])))
        self.assertEqual('END', screen.display[23][39:42])
        self.assertEqual((42, 23), (screen.cursor.x, screen.cursor.y))

    def test_genuine_shan_witness_stays_inside_reading_pane(self):
        screen = self.screen()
        witness = 'တူဝ်ထိသၢမ် ၼႂ်းတူဝ်မႄႈလိၵ်ႈတႆး သိပ်းၵဝ်ႈတူဝ်၊ ဢၢၼ်ႇ ဝႃႈ ငႃႉ။'
        # Exact cursor operation and complete text emitted in the retained PTY.
        screen.feed(('\x1b[14;33H  1. ' + witness + '\x1b[?25l').encode())
        self.assertEqual(' ' * 32, screen.display[13][:32])
        self.assertIn(witness, screen.display[13][32:])
        self.assertFalse(screen.display[14].strip())
        self.assertLess(screen.cursor.x, 90)
        self.assertTrue(screen.cursor.hidden)


if __name__ == '__main__':
    unittest.main()
