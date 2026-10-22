file: logline.py
test: python3 -m unittest test_logline
---
Module logline.py.

parse_line(line): a log line is "<timestamp> <LEVEL> <worker> <message>" separated by single spaces; the message is everything after the third space and may itself contain spaces. Return a dict with keys "ts", "level", "worker", "message". A line with fewer than four fields raises ValueError.
Examples: parse_line("2026-10-22T10:00:00 INFO worker-3 batch 7 done") == {"ts": "2026-10-22T10:00:00", "level": "INFO", "worker": "worker-3", "message": "batch 7 done"}.

filter_level(lines, level): parse every non-empty line and return, in order, the parsed dicts whose level equals level.

count_levels(lines): a dict from level to count over all non-empty lines, with keys in sorted order.
Examples: count_levels(["t INFO w a", "t ERROR w b", "t INFO w c"]) == {"ERROR": 1, "INFO": 2}.
