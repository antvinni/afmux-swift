file: dates.py
test: python3 -m unittest test_dates
---
Module dates.py. Do not import datetime or calendar.

parse_date(s): "YYYY-MM-DD" -> (year, month, day) as ints. The parts must be exactly 4, 2 and 2 digits; month 1-12, day 1-31; anything else raises ValueError.
Examples: parse_date("2026-01-07") == (2026, 1, 7); parse_date("2026-1-7") raises ValueError.

is_leap(year): True for years divisible by 4, except years divisible by 100 that are not divisible by 400.
Examples: is_leap(2024) is True; is_leap(1900) is False; is_leap(2000) is True.

days_in_month(year, month): 31, 30, or 28/29 for February using is_leap.
Examples: days_in_month(2024, 2) == 29; days_in_month(2026, 4) == 30.

add_months(year, month, day, n): move n months forward (n may be negative); if the day does not exist in the new month, use that month's last day. Returns (year, month, day).
Examples: add_months(2026, 1, 31, 1) == (2026, 2, 28); add_months(2026, 1, 15, -1) == (2025, 12, 15); add_months(2026, 11, 30, 3) == (2027, 2, 28).
