import datetime
import os
import stat
import tempfile
import unittest
from pathlib import Path

from lexicon_scorer.testset import (
    TestSetError,
    assign_sessions,
    choose_held_back,
    group_sessions,
    lock_down,
    manifest_line,
    not_owner_only,
    parse_lexicon,
    review_reasons,
    wispr_run_line,
)

UTC = datetime.timezone.utc
LEX = parse_lexicon("""
# Terms, and Rules as heard -> written
Supabase
GitHub
gstack
kubectl
cube cuddle -> kubectl
codecs -> Codec
""")


def at(minutes: float) -> datetime.datetime:
    """A time `minutes` after 09:00 UTC on 2026-10-01."""
    return datetime.datetime(2026, 10, 1, 9, tzinfo=UTC) + datetime.timedelta(minutes=minutes)


def clip(hhmmss: str) -> dict:
    """A clip logged at `hhmmss` UTC on 2026-10-01, in Wispr's timestamp format."""
    return {"timestamp": f"2026-10-01 {hhmmss}.123 +00:00"}


def sessions_of(*sizes: int) -> list[list[str]]:
    """Sessions with the given numbers of clips, each clip with its own id."""
    return [[f"{s}-{i}" for i in range(size)] for s, size in enumerate(sizes)]


class ParseLexicon(unittest.TestCase):
    def test_a_line_with_an_arrow_is_a_rule_and_any_other_line_a_term(self):
        lexicon = parse_lexicon("Supabase\nuse effect -> useEffect\n")
        self.assertEqual(lexicon.terms, ("Supabase",))
        self.assertEqual(lexicon.rules, (("use effect", "useEffect"),))

    def test_blank_lines_and_comments_are_skipped(self):
        lexicon = parse_lexicon("\n# a comment\n   \n  # an indented comment\nkubectl\n")
        self.assertEqual(lexicon.terms, ("kubectl",))

    def test_a_hash_inside_a_term_is_not_a_comment(self):
        self.assertEqual(parse_lexicon("C#\n#C++\n").terms, ("C#",))

    def test_whitespace_around_each_side_is_stripped(self):
        lexicon = parse_lexicon("  kubectl  \n  cube cuddle  ->   kubectl  \n")
        self.assertEqual((lexicon.terms, lexicon.rules), (("kubectl",), (("cube cuddle", "kubectl"),)))

    def test_only_the_first_arrow_splits(self):
        self.assertEqual(parse_lexicon("a -> b -> c\n").rules, (("a", "b -> c"),))

    def test_a_rule_with_an_empty_side_is_dropped_not_made_a_term(self):
        lexicon = parse_lexicon("-> orphan\nempty ->\n  ->  \n")
        self.assertEqual((lexicon.terms, lexicon.rules, lexicon.written), ((), (), []))

    def test_written_is_the_sorted_forms_of_terms_and_rules_without_repeats(self):
        lexicon = parse_lexicon("kubectl\nSupabase\ncube cuddle -> kubectl\nuse effect -> useEffect\n")
        self.assertEqual(lexicon.written, ["Supabase", "kubectl", "useEffect"])


class ReviewReasons(unittest.TestCase):
    def test_a_rule_matches_whatever_unicode_form_the_lexicon_file_uses(self):
        decomposed = parse_lexicon("Beyonce\u0301 -> Beyonce")
        self.assertEqual(review_reasons("Beyonc\u00e9 sings", "Beyonc\u00e9 sings", decomposed), ["rule"])

    def test_texts_that_differ_only_in_case_or_punctuation_agree(self):
        self.assertEqual(review_reasons("Ship it now.", "Ship it now.", LEX), [])
        self.assertEqual(review_reasons("Ship it now.", "ship it now", LEX), [])
        self.assertEqual(review_reasons("Ship it, now!", "ship it now", LEX), [])

    def test_different_words_need_review(self):
        self.assertEqual(review_reasons("ship it now", "ship it later", LEX), ["words"])

    def test_one_empty_text_needs_review_and_two_empty_texts_agree(self):
        self.assertEqual(review_reasons("ship it now", "", LEX), ["words"])
        self.assertEqual(review_reasons("", "", LEX), [])

    def test_a_term_written_differently_in_the_two_texts_needs_review(self):
        self.assertEqual(review_reasons("Use Supabase.", "Use supabase.", LEX), ["terms", "variant"])

    def test_a_term_in_another_case_or_spacing_in_both_texts_is_only_a_variant(self):
        for spelling in ("Github", "Git Hub", "git-hub"):
            with self.subTest(spelling):
                self.assertEqual(review_reasons(f"Push to {spelling}.", f"Push to {spelling}.", LEX), ["variant"])
        self.assertEqual(review_reasons("Run G stack.", "Run G stack.", LEX), ["variant"])

    def test_the_exact_term_in_both_texts_needs_no_review(self):
        self.assertEqual(review_reasons("Deploy GitHub.", "deploy GitHub", LEX), [])

    def test_a_rule_heard_side_in_either_text_needs_review(self):
        self.assertEqual(review_reasons("run cube cuddle now", "run cube cuddle now", LEX), ["rule"])
        self.assertIn("rule", review_reasons("run cube cuddle now", "run kubectl now", LEX))
        self.assertIn("rule", review_reasons("run kubectl now", "run cube cuddle now", LEX))

    def test_a_rule_heard_side_matches_in_any_case_and_spacing(self):
        self.assertEqual(review_reasons("run CUBE   cuddle now", "run CUBE   cuddle now", LEX), ["rule"])

    def test_a_rule_heard_side_counts_only_as_a_whole_word(self):
        self.assertEqual(review_reasons("run codecs now", "run codecs now", LEX), ["rule"])
        self.assertEqual(review_reasons("run codecsx now", "run codecsx now", LEX), [])


class GroupSessions(unittest.TestCase):
    def test_clips_are_in_recording_order(self):
        self.assertEqual(group_sessions({"late": at(20), "early": at(0), "middle": at(10)}),
                         [["early", "middle", "late"]])

    def test_a_gap_over_30_minutes_starts_a_new_session(self):
        self.assertEqual(group_sessions({"a": at(0), "b": at(30), "c": at(61)}), [["a", "b"], ["c"]])

    def test_a_session_follows_the_gap_between_neighbours(self):
        times = {f"c{m}": at(m) for m in range(0, 121, 20)}
        self.assertEqual(group_sessions(times), [["c0", "c20", "c40", "c60", "c80", "c100", "c120"]])

    def test_clips_at_the_same_time_are_ordered_by_id(self):
        self.assertEqual(group_sessions({"c": at(0), "a": at(0), "b": at(0)}), [["a", "b", "c"]])


class ChooseHeldBack(unittest.TestCase):
    def test_holds_back_exactly_size_clips_in_whole_sessions(self):
        sessions = sessions_of(3, 5, 2, 7, 1, 4, 6, 2, 1, 9)
        held = choose_held_back(sessions, 10, seed=1)
        self.assertEqual(sum(len(sessions[i]) for i in held), 10)
        self.assertNotIn(len(sessions) - 1, held)

    def test_never_holds_back_the_latest_session_even_if_it_would_fit(self):
        with self.assertRaises(TestSetError):
            choose_held_back(sessions_of(1, 2), 2)

    def test_skips_sessions_larger_than_max_session(self):
        self.assertEqual(choose_held_back(sessions_of(5, 1, 1, 1, 1), 3, max_session=4), {1, 2, 3})

    def test_a_session_of_exactly_max_session_clips_may_be_held_back(self):
        self.assertEqual(choose_held_back(sessions_of(4, 1), 4, max_session=4), {0})

    def test_the_same_seed_gives_the_same_sessions(self):
        sessions = sessions_of(3, 5, 2, 7, 1, 4, 6, 2, 1, 9)
        self.assertEqual(choose_held_back(sessions, 10, seed=5), choose_held_back(sessions, 10, seed=5))

    def test_raises_when_no_whole_sessions_make_exactly_size(self):
        with self.assertRaises(TestSetError):
            choose_held_back(sessions_of(3, 2, 1), 4)

    def test_finds_an_exact_total_whatever_order_the_seed_draws(self):
        # Taking the small sessions first reaches 3 and gets stuck; {0} makes 4.
        for seed in range(50):
            self.assertEqual(choose_held_back(sessions_of(4, 1, 1, 1, 1), 4, seed=seed), {0})


class AssignSessions(unittest.TestCase):
    def setUp(self):
        self.existing = {
            "a": {"session": "s001", "split": "held-back"},
            "b": {"session": "s001", "split": "held-back"},
            "c": {"session": "s004", "split": "everyday"},
        }
        self.clips = {"a": clip("09:00:00"), "b": clip("09:10:00"), "c": clip("10:00:00")}

    def test_a_first_build_numbers_sessions_in_recording_order_and_holds_back_size_clips(self):
        clips = {  # sessions: a, b; c, d, e; f. Inserted out of order.
            "f": clip("11:30:00"), "d": clip("10:05:00"), "a": clip("09:00:00"),
            "e": clip("10:20:00"), "b": clip("09:10:00"), "c": clip("10:00:00"),
        }
        self.assertEqual(assign_sessions(clips, {}, held_back=2), {
            "a": ("s001", "held-back"), "b": ("s001", "held-back"),
            "c": ("s002", "everyday"), "d": ("s002", "everyday"), "e": ("s002", "everyday"),
            "f": ("s003", "everyday"),
        })

    def test_a_new_clip_within_the_gap_joins_the_session_and_split_of_an_existing_clip(self):
        self.clips |= {"near-held": clip("09:25:00"), "near-everyday": clip("10:20:00")}
        self.assertEqual(assign_sessions(self.clips, self.existing, held_back=2), {
            "near-held": ("s001", "held-back"),
            "near-everyday": ("s004", "everyday"),
        })

    def test_a_first_build_with_no_clips_assigns_nothing(self):
        self.assertEqual(assign_sessions({}, {}), {})

    def test_a_new_clip_far_from_the_existing_ones_starts_an_everyday_session_after_the_highest(self):
        self.clips["far"] = clip("13:00:00")
        self.assertEqual(assign_sessions(self.clips, self.existing, held_back=2), {
            "far": ("s005", "everyday"),
        })


class WisprRunLine(unittest.TestCase):
    def test_wispr_run_holds_its_raw_text_its_pasted_text_and_its_logged_lag(self):
        line = wispr_run_line("c1", {"asrText": "ship it now", "pastedText": "  Ship it now.\n", "e2eLatency": 812.6})
        self.assertEqual(line, {"id": "c1", "speech_text": "ship it now", "inserted_text": "Ship it now.",
                                "status": "inserted", "lag_ms": 813, "engine": "wispr", "lost": False})

    def test_a_clip_with_no_pasted_text_failed_and_has_no_lag_when_none_was_logged(self):
        line = wispr_run_line("c2", {"asrText": None, "pastedText": " ", "e2eLatency": None})
        self.assertEqual(line, {"id": "c2", "speech_text": "", "inserted_text": "", "status": "failed",
                                "lag_ms": None, "engine": "wispr", "lost": False})


class ManifestLine(unittest.TestCase):
    def test_an_agreed_clip_is_gold_as_it_is_with_its_fields(self):
        wispr = {"audio_filepath": "wispr-2026-10-01/audio/c1.wav", "duration": 4.5,
                 "speechDuration": 3.25, "app": "Slack"}
        self.assertEqual(manifest_line("c1", wispr, "Use Supabase and kubectl.", [], "s001", "everyday", LEX), {
            "id": "c1", "audio_filepath": "wispr-2026-10-01/audio/c1.wav", "duration": 4.5,
            "text": "Use Supabase and kubectl.", "gold": "agreed", "terms": ["Supabase", "kubectl"],
            "speech_end": 3.25, "context": "Slack", "session": "s001", "split": "everyday"})

    def test_a_clip_with_reasons_needs_review_and_lists_only_exact_terms(self):
        wispr = {"audio_filepath": "a.wav", "duration": 2.0}
        line = manifest_line("c2", wispr, "supabase and Supabase, then kubectl", ["variant"],
                             "s002", "held-back", LEX)
        self.assertEqual((line["gold"], line["terms"]), ("review", ["Supabase", "kubectl"]))

    def test_speech_end_falls_back_to_the_duration_and_context_to_none(self):
        wispr = {"audio_filepath": "a.wav", "duration": 2.0, "speechDuration": None}
        line = manifest_line("c3", wispr, "ship it", [], "s001", "everyday", LEX)
        self.assertEqual((line["speech_end"], line["context"]), (2.0, None))


class Permissions(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "test-set"
        (self.root / "sub" / "deep").mkdir(parents=True)
        for folder in (self.root, self.root / "sub", self.root / "sub" / "deep"):
            os.chmod(folder, 0o755)
        for name in ("a.jsonl", "sub/b.wav", "sub/deep/c.txt"):
            (self.root / name).write_text("x", encoding="utf-8")
            os.chmod(self.root / name, 0o644)

    def test_before_lock_down_every_loose_entry_counts_root_included(self):
        # The root, two folders and three files.
        self.assertEqual(not_owner_only(self.root), 6)

    def test_lock_down_leaves_no_group_or_other_bits_anywhere(self):
        self.assertEqual(lock_down(self.root), (3, 3))
        self.assertEqual(not_owner_only(self.root), 0)
        paths = [self.root, *(Path(dirpath, name)
                              for dirpath, dirnames, filenames in os.walk(self.root)
                              for name in (*dirnames, *filenames))]
        for path in paths:
            with self.subTest(path.name):
                self.assertEqual(stat.S_IMODE(path.lstat().st_mode) & 0o077, 0)

    def test_lock_down_keeps_the_owner_read_and_write(self):
        lock_down(self.root)
        self.assertEqual(stat.S_IMODE(self.root.lstat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.root / "sub" / "b.wav").lstat().st_mode), 0o600)

    def test_lock_down_does_not_chmod_a_file_outside_the_tree_through_a_symlink(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        outside = Path(tmp.name) / "outside.txt"
        outside.write_text("x", encoding="utf-8")
        os.chmod(outside, 0o644)
        (self.root / "link.txt").symlink_to(outside)
        lock_down(self.root)
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o644)
        self.assertEqual(not_owner_only(self.root), 0)


if __name__ == "__main__":
    unittest.main()
