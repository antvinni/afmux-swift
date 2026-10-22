file: csvstats.py
test: python3 -m unittest test_csvstats
---
Module csvstats.py.

load_rows(path): read the CSV file at path with csv.DictReader and return a list of dicts, one per row, values as strings.
Examples: a file containing "a,b\n1,2\n" gives [{"a": "1", "b": "2"}].

count_by(rows, key): a dict from each distinct value of row[key] to how many rows have it, in first-seen order.
Examples: count_by([{"k": "x"}, {"k": "y"}, {"k": "x"}], "k") == {"x": 2, "y": 1}.

mean_of(rows, key): the arithmetic mean of float(row[key]) over all rows; 0.0 when there are no rows.
Examples: mean_of([{"v": "1"}, {"v": "2"}], "v") == 1.5; mean_of([], "v") == 0.0.
