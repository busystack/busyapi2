"""Regression coverage for the native timing observer's content attribution."""
import unittest
from native_paint_detector import templates, matches

def image(glyph, caret=0, status=0, channels=4):
    pixels = [glyph] * 20 + [(caret, 0, 0)] * 2 + [(status, 0, 0)] * 30
    return b''.join(bytes(p + ((255,) if channels == 4 else ())) for p in pixels), channels

class NativePaintDetectorTest(unittest.TestCase):
    def test_color_independent_actual_text_states(self):
        for channels in [3, 4]:
            # Both dark and light palettes, neither requiring red string glyphs.
            for a, b in [((230,230,230),(50,50,50)), ((0,180,255),(0,130,220))]:
                before, after = image(a, channels=channels), image(b, channels=channels)
                t = templates([before,after,before,after])
                self.assertTrue(matches(before,t,0))
                self.assertTrue(matches(after,t,1))
                self.assertFalse(matches(before,t,1))

    def test_caret_and_status_changes_do_not_satisfy_text(self):
        a, b = (70,90,110), (140,160,180)
        t = templates([image(a,0,0),image(b,255,100),image(a,255,50),image(b,0,150)])
        self.assertFalse(matches(image(a,255,255),t,1))
        self.assertTrue(matches(image(b,77,222),t,1))
        self.assertEqual(len(t[0]),60)

    def test_phase_aligned_warmup_caret_is_excluded_by_idle_controls(self):
        a,b=(70,90,110),(140,160,180)
        warm=[image(a,0),image(b,255)]*2
        idle=[image(a,255),image(b,0)]*2
        t=templates(warm,idle)
        self.assertEqual(len(t[0]),60)
        self.assertTrue(matches(image(b,0),t,1))
        self.assertFalse(matches(image(a,255),t,1))

    def test_validated_caret_rectangles_are_excluded_even_if_phase_stable(self):
        a,b=(70,90,110),(140,160,180)
        t=templates([image(a,0),image(b,255)]*2,ignored=[20,21])
        self.assertEqual(len(t[0]),60)
        self.assertTrue(matches(image(b,0),t,1))
        self.assertFalse(matches(image(a,255),t,1))

    def test_insufficient_stable_content_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError,'stable changed text'):
            templates([image((10,10,10),0),image((10,10,10),255)]*2)
        with self.assertRaises(RuntimeError):
            templates([image((10,10,10)),image((20,20,20)),image((30,30,30)),image((40,40,40))])

    def test_arbitrary_repaint_is_not_the_expected_text(self):
        t = templates([image((10,10,10)),image((20,20,20))]*2)
        self.assertFalse(matches(image((21,20,20)),t,1))

if __name__ == '__main__': unittest.main()
