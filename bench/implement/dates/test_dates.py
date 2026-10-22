import unittest
from dates import parse_date, is_leap, days_in_month, add_months

class T(unittest.TestCase):
    def test_parse(self): self.assertEqual(parse_date("2026-01-07"), (2026, 1, 7))
    def test_parse_bad(self):
        for s in ("2026-1-7", "26-01-07", "2026-13-01", "2026-00-10", "2026-01-32", "2026-01-0a", "2026/01/07"):
            with self.assertRaises(ValueError, msg=s): parse_date(s)
    def test_leap(self): self.assertEqual([is_leap(y) for y in (2024, 1900, 2000, 2026)], [True, False, True, False])
    def test_days(self): self.assertEqual([days_in_month(2024, 2), days_in_month(2026, 2), days_in_month(2026, 4), days_in_month(2026, 12)], [29, 28, 30, 31])
    def test_add_clamp(self): self.assertEqual(add_months(2026, 1, 31, 1), (2026, 2, 28))
    def test_add_back(self): self.assertEqual(add_months(2026, 1, 15, -1), (2025, 12, 15))
    def test_add_year(self): self.assertEqual(add_months(2026, 11, 30, 3), (2027, 2, 28))
    def test_add_many_back(self): self.assertEqual(add_months(2026, 3, 31, -13), (2025, 2, 28))
