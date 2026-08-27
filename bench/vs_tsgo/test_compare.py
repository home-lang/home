"""Report formatting regressions; measurements are never filtered or changed."""

import unittest

import compare


class ComparisonTests(unittest.TestCase):
    def test_exact_tie_is_not_a_win(self):
        self.assertEqual("1.00× (near tie)", compare.format_comparison(100, 100))

    def test_rounded_ties_are_symmetric(self):
        for home, competitor in [(100, 100.4), (100.4, 100)]:
            with self.subTest(home=home, competitor=competitor):
                self.assertEqual("1.00× (near tie)", compare.format_comparison(home, competitor))

    def test_lower_mean_keeps_direction(self):
        self.assertEqual("**2.00× faster**", compare.format_comparison(100, 200))

    def test_higher_mean_keeps_direction(self):
        self.assertEqual("2.00× slower", compare.format_comparison(200, 100))

    def test_two_decimal_boundary_is_symmetric(self):
        for home, competitor in [(100, 100.49), (100.49, 100)]:
            self.assertEqual("1.00× (near tie)", compare.format_comparison(home, competitor))
        self.assertEqual("**1.01× faster**", compare.format_comparison(100, 100.51))
        self.assertEqual("1.01× slower", compare.format_comparison(100.51, 100))


if __name__ == "__main__":
    unittest.main()
