import os, tempfile, unittest
from csvstats import load_rows, count_by, mean_of

class T(unittest.TestCase):
    def test_load(self):
        d = tempfile.mkdtemp(); p = os.path.join(d, "x.csv")
        with open(p, "w") as f: f.write("a,b\n1,2\n3,x y\n")
        self.assertEqual(load_rows(p), [{"a": "1", "b": "2"}, {"a": "3", "b": "x y"}])
    def test_count_order(self):
        self.assertEqual(list(count_by([{"k": "y"}, {"k": "x"}, {"k": "y"}], "k").items()), [("y", 2), ("x", 1)])
    def test_count_empty(self): self.assertEqual(count_by([], "k"), {})
    def test_mean(self): self.assertEqual(mean_of([{"v": "1"}, {"v": "2"}], "v"), 1.5)
    def test_mean_empty(self): self.assertEqual(mean_of([], "v"), 0.0)
