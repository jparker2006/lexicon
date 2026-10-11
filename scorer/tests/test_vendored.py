import hashlib
import unittest
from importlib.metadata import version
from pathlib import Path

VENDOR = Path(__file__).resolve().parent.parent / "lexicon_scorer" / "vendor" / "open_asr_normalizer"

# Open ASR Leaderboard at d0f986b28fbb3035f7c27b4b24071ef0bc79f059. See VENDORED.md.
UPSTREAM = {
    "normalizer.py": "490b56393484ef386b486f3679cc2261264af280b3512154431e0bdcf2778295",
    "english_abbreviations.py": "52997cc963e0bd6568d15554ad8d5fb0759f20f361483632a22f90d2d0e07db1",
    "LICENSE": "5ee13882fce0975f0ad3c3d5c2042af4896c2a669be2d6df5b3d256811267c85",
}


class Pins(unittest.TestCase):
    def test_vendored_normalizer_is_unchanged_from_its_commit(self):
        for name, sha in UPSTREAM.items():
            with self.subTest(name):
                self.assertEqual(hashlib.sha256((VENDOR / name).read_bytes()).hexdigest(), sha)

    def test_packages_are_the_pinned_versions(self):
        self.assertEqual(version("jiwer"), "4.0.0")
        self.assertEqual(version("regex"), "2026.9.10")


if __name__ == "__main__":
    unittest.main()
