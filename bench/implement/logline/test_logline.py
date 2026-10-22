import unittest
from logline import parse_line, filter_level, count_levels

class T(unittest.TestCase):
    def test_parse(self):
        self.assertEqual(parse_line("2026-10-22T10:00:00 INFO worker-3 batch 7 done"),
                         {"ts": "2026-10-22T10:00:00", "level": "INFO", "worker": "worker-3", "message": "batch 7 done"})
    def test_parse_short(self):
        with self.assertRaises(ValueError): parse_line("t INFO w")
    def test_filter(self):
        got = filter_level(["t INFO w a", "", "t ERROR w b c", "t INFO w d"], "ERROR")
        self.assertEqual(got, [{"ts": "t", "level": "ERROR", "worker": "w", "message": "b c"}])
    def test_count(self):
        self.assertEqual(list(count_levels(["t INFO w a", "t ERROR w b", "", "t INFO w c"]).items()), [("ERROR", 1), ("INFO", 2)])
