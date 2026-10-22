import unittest
from textfmt import slugify, truncate, wrap

class T(unittest.TestCase):
    def test_slug(self): self.assertEqual(slugify("Hello, World!"), "hello-world")
    def test_slug_underscore(self): self.assertEqual(slugify("a_b  c"), "a-b-c")
    def test_slug_empty(self): self.assertEqual(slugify("!!!"), "")
    def test_truncate(self): self.assertEqual(truncate("hello world", 8), "hello...")
    def test_truncate_exact(self): self.assertEqual(truncate("hello", 5), "hello")
    def test_wrap(self): self.assertEqual(wrap("the quick brown fox", 10), ["the quick", "brown fox"])
    def test_wrap_long_word(self): self.assertEqual(wrap("a extraordinary b", 5), ["a", "extraordinary", "b"])
    def test_wrap_empty(self): self.assertEqual(wrap("", 5), [])
