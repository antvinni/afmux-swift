def parse_date(s):
    p = s.split("-")
    if len(p) != 3 or [len(x) for x in p] != [4, 2, 2] or not all(x.isdigit() for x in p):
        raise ValueError(s)
    y, m, d = map(int, p)
    if not 1 <= m <= 12 or not 1 <= d <= 31:
        raise ValueError(s)
    return (y, m, d)

def is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)

def days_in_month(y, m):
    if m == 2:
        return 29 if is_leap(y) else 28
    return 30 if m in (4, 6, 9, 11) else 31

def add_months(y, m, d, n):
    i = y * 12 + (m - 1) + n
    y, m = divmod(i, 12)
    m += 1
    return (y, m, min(d, days_in_month(y, m)))
