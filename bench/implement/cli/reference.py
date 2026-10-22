import argparse, json, re

def count_words(text):
    c = {}
    for w in re.findall(r"[a-z0-9']+", text.lower()):
        c[w] = c.get(w, 0) + 1
    return c

def main(argv):
    parser = argparse.ArgumentParser(prog="wc")
    parser.add_argument("file")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--top", type=int, default=3)
    a = parser.parse_args(argv)
    with open(a.file) as f:
        c = count_words(f.read())
    top = sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[:a.top]
    if a.json:
        print(json.dumps(dict(top)))
    else:
        for w, n in top:
            print("%s %d" % (w, n))
    return 0
