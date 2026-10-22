def parse_line(line):
    parts = line.split(" ", 3)
    if len(parts) < 4:
        raise ValueError(line)
    return {"ts": parts[0], "level": parts[1], "worker": parts[2], "message": parts[3]}

def filter_level(lines, level):
    return [p for p in (parse_line(l) for l in lines if l.strip()) if p["level"] == level]

def count_levels(lines):
    c = {}
    for l in lines:
        if l.strip():
            lv = parse_line(l)["level"]
            c[lv] = c.get(lv, 0) + 1
    return dict(sorted(c.items()))
