import csv

def load_rows(path):
    with open(path, newline="") as f:
        return [dict(r) for r in csv.DictReader(f)]

def count_by(rows, key):
    out = {}
    for r in rows:
        out[r[key]] = out.get(r[key], 0) + 1
    return out

def mean_of(rows, key):
    return sum(float(r[key]) for r in rows) / len(rows) if rows else 0.0
