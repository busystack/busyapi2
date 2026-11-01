import unittest
from native_ximage import rgb32


class XImageTest(unittest.TestCase):
    def test_little_big_endian_and_row_padding_have_identical_rgb(self):
        expected = (bytes([10, 20, 30, 40, 50, 60]), 3)
        self.assertEqual(rgb32(bytes([30, 20, 10, 255, 8, 8, 8, 8,
                                     60, 50, 40, 255, 9, 9, 9, 9]), 1, 2, 8, 0), expected)
        self.assertEqual(rgb32(bytes([255, 10, 20, 30, 8, 8, 8, 8,
                                     255, 40, 50, 60, 9, 9, 9, 9]), 1, 2, 8, 1), expected)

    def test_invalid_storage_and_unknown_order_are_rejected(self):
        for raw, width, height, stride, order in [
                (b'', 1, 1, 4, 0), (b'1234', 1, 1, 3, 0),
                (b'1234', 1, 1, 4, 2), (b'', 0, 1, 0, 0)]:
            with self.assertRaises(RuntimeError):
                rgb32(raw, width, height, stride, order)


if __name__ == '__main__':
    unittest.main()
