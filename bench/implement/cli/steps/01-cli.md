file: cli.py
test: python3 -m unittest test_cli
---
Module cli.py: a command-line word counter.

count_words(text): a dict from word to count, where words are the matches of the regex [a-z0-9']+ in text.lower().
Examples: count_words("A a b") == {"a": 2, "b": 1}.

main(argv): argv is a list without the program name. Parse it with exactly these lines:
parser = argparse.ArgumentParser(prog="wc")
parser.add_argument("file")
parser.add_argument("--json", action="store_true")
parser.add_argument("--top", type=int, default=3)
Read the file, count its words, and take the top N words by count descending, ties broken by word ascending. With --json print json.dumps(dict(top)); otherwise print one "word count" line per word. Return 0.
Examples: for a file containing "b a a c b a", main([path, "--top", "2"]) prints "a 3" then "b 2".
