import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from lexicon_scorer.__main__ import main

GOLD = [
    {"id": "1", "session": "s1", "audio_filepath": "audio/1.wav",
     "text": "Deploy the Supabase edge function with kubectl, then run useEffect in App.tsx.",
     "terms": ["Supabase", "kubectl", "useEffect", "App.tsx"]},
    {"id": "2", "session": "s2", "text": "Ship it after lunch."},
]
RUN_A = [
    {"id": "1", "speech_text": "deploy the supabase edge function with kubectl then run useeffect in app tsx",
     "inserted_text": "Deploy the Supabase edge function with kubectl, then run useEffect in App.tsx."},
    {"id": "2", "speech_text": "ship it after lunch", "inserted_text": "Ship it after lunch."},
]
RUN_B = [
    {"id": "1", "speech_text": "deploy the supabase edge function with kubectl then run useeffect in app tsx",
     "inserted_text": "deploy the supabase edge function with kubectl then run useeffect in app tsx"},
    {"id": "2", "speech_text": "ship it after lunch", "inserted_text": "Ship it after Lexicon."},
]


def write(dir: Path, name: str, rows) -> str:
    path = dir / name
    path.write_text("".join(json.dumps(r) + "\n" for r in rows) if isinstance(rows, list) else rows)
    return str(path)


def run(*argv) -> dict:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        main(list(argv))
    return json.loads(out.getvalue())


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.gold = write(d, "gold.jsonl", GOLD)
        self.a = write(d, "a.jsonl", RUN_A)
        self.b = write(d, "b.jsonl", RUN_B)
        self.terms = write(d, "terms.txt", "Supabase\nkubectl\n\nLexicon\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_score(self):
        out = run("score", "--gold", self.gold, "--run", self.b, "--terms", self.terms)
        self.assertEqual(out["totals"]["wer"], 0.0)
        self.assertEqual(out["totals"]["term_error_rate"], 0.75)
        self.assertEqual(out["totals"]["term_false_alarms"], 1)
        self.assertEqual(out["entries"][1]["false_alarm_terms"], ["Lexicon"])

    def test_compare_is_reproducible(self):
        args = ("compare", "--gold", self.gold, "--run-a", self.a, "--run-b", self.b,
                "--terms", self.terms, "--seed", "3", "--resamples", "1000")
        first = run(*args)
        self.assertEqual(first, run(*args))
        self.assertEqual(first["a_minus_b"]["term_error_rate"]["diff"], -0.75)
        self.assertEqual(first["a_minus_b"]["term_false_alarms"]["diff"], -1)
        self.assertEqual(first["sessions"], 2)
        self.assertEqual(first["a_minus_b"]["wer"]["verdict"], "too_few_sessions")

    def test_gold_term_missing_from_its_own_text_fails(self):
        for terms in (["Next.js"], [" kubectl"], [""]):
            with self.subTest(terms):
                gold = write(Path(self.tmp.name), "g2.jsonl",
                             [{"id": "1", "session": "s", "text": "run kubectl on next dot js", "terms": terms}])
                run_ = write(Path(self.tmp.name), "r2.jsonl",
                             [{"id": "1", "speech_text": "x", "inserted_text": "x"}])
                with self.assertRaises(SystemExit):
                    run("score", "--gold", gold, "--run", run_)

    def test_gold_term_in_nfd_matches_nfc_text(self):
        gold = write(Path(self.tmp.name), "nfd.jsonl",
                     [{"id": "1", "session": "s", "text": "Beyonc\u00e9 sings.", "terms": ["Beyonce\u0301"]}])
        run_ = write(Path(self.tmp.name), "r3.jsonl",
                     [{"id": "1", "speech_text": "beyonce sings", "inserted_text": "Beyonce sings."}])
        self.assertEqual(run("score", "--gold", gold, "--run", run_)["totals"]["term_error_rate"], 1.0)

    def test_lexicon_file_may_start_with_a_bom(self):
        terms = write(Path(self.tmp.name), "bom.txt", "\ufeffLexicon\n")
        out = run("score", "--gold", self.gold, "--run", self.b, "--terms", terms)
        self.assertEqual(out["entries"][1]["false_alarm_terms"], ["Lexicon"])

    def test_a_dictation_missing_from_the_run_fails(self):
        short = write(Path(self.tmp.name), "short.jsonl", RUN_A[:1])
        with self.assertRaises(SystemExit):
            run("score", "--gold", self.gold, "--run", short)

    def test_gold_still_awaiting_review_is_never_scored(self):
        # A Test set entry the two speech models disagreed on holds only a draft
        # until Jake reviews it (#50, #51); scoring it would favor one model.
        gold = write(Path(self.tmp.name), "draft.jsonl", [{**GOLD[0], "gold": "agreed"}, {**GOLD[1], "gold": "review"}])
        with self.assertRaises(SystemExit):
            run("score", "--gold", gold, "--run", self.a)
        reviewed = write(Path(self.tmp.name), "reviewed.jsonl", [{**GOLD[0], "gold": "agreed"}, {**GOLD[1], "gold": "reviewed"}])
        self.assertEqual(run("score", "--gold", reviewed, "--run", self.a)["totals"]["entries"], 2)

    def test_split_scores_only_that_split(self):
        gold = write(Path(self.tmp.name), "split.jsonl",
                     [{**GOLD[0], "split": "dev"}, {**GOLD[1], "split": "holdout"}])
        short = write(Path(self.tmp.name), "short.jsonl", RUN_A[:1])
        self.assertEqual(run("score", "--gold", gold, "--run", short, "--split", "dev")["totals"]["entries"], 1)
        with self.assertRaises(SystemExit):
            run("score", "--gold", gold, "--run", short, "--split", "holdout")
        with self.assertRaises(SystemExit):
            run("score", "--gold", gold, "--run", short, "--split", "nope")

    def test_malformed_input_is_a_clean_error(self):
        d = Path(self.tmp.name)
        bad = {
            "truncated": '{"id": "1", "speech_text": "x"\n',
            "not an object": '["1"]\n',
            "numeric id": '{"id": 1, "speech_text": "x", "inserted_text": "x"}\n',
            "not utf-8": b"\xff\xfe\x00bad",
        }
        for name, content in bad.items():
            with self.subTest(name):
                path = d / "bad.jsonl"
                path.write_bytes(content if isinstance(content, bytes) else content.encode())
                with self.assertRaises(SystemExit) as e:
                    run("score", "--gold", self.gold, "--run", str(path))
                self.assertIsInstance(e.exception.code, str)
        with self.assertRaises(SystemExit) as e:
            run("score", "--gold", str(d / "nope.jsonl"), "--run", self.a)
        self.assertIsInstance(e.exception.code, str)
        listed = write(d, "g4.jsonl", [{**GOLD[0], "session": ["s1"]}, GOLD[1]])
        with self.assertRaises(SystemExit) as e:
            run("compare", "--gold", listed, "--run-a", self.a, "--run-b", self.b)
        self.assertIsInstance(e.exception.code, str)

    def test_unknown_id_fails(self):
        bad = write(Path(self.tmp.name), "bad.jsonl", [{"id": "9", "speech_text": "", "inserted_text": ""}])
        with self.assertRaises(SystemExit):
            run("score", "--gold", self.gold, "--run", bad)


if __name__ == "__main__":
    unittest.main()
