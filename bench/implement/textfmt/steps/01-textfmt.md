file: textfmt.py
test: python3 -m unittest test_textfmt
---
Module textfmt.py.

slugify(s): lowercase, each run of characters other than a-z and 0-9 becomes one hyphen, strip hyphens from both ends.
Examples: slugify("Hello, World!") == "hello-world"; slugify("!!!") == "".

truncate(s, n): if len(s) <= n return s unchanged; otherwise the first n-3 characters followed by "...". n is at least 3.
Examples: truncate("hello world", 8) == "hello..."; truncate("hi", 8) == "hi".

wrap(s, width): split s on whitespace into words and pack them into lines of at most width characters, words separated by one space; a word longer than width gets a line of its own. Return the list of lines.
Examples: wrap("the quick brown fox", 10) == ["the quick", "brown fox"]; wrap("", 5) == [].
