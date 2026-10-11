import unittest

from lexicon_scorer.score import (
    EntryScore,
    paired_bootstrap,
    score_entry,
    term_counts,
    totals,
)

# The research's measured example (docs/research/head-to-head.md on branch
# research/head-to-head, scoring section).
GOLD = "Deploy the Supabase edge function with kubectl, then run useEffect in App.tsx."
TERMS = ["Supabase", "kubectl", "useEffect", "App.tsx"]
HYP_A = "Deploy the super base edge function with cube cuddle, then run use effect in app.tsx."
HYP_B = "deploy the supabase edge function with kubectl then run useeffect in app tsx"


def entry(id, session, gold, speech, inserted=None, terms=()):
    return score_entry(
        id=id, session=session, gold=gold, speech_text=speech,
        inserted_text=speech if inserted is None else inserted, terms=terms,
    )


class ResearchExample(unittest.TestCase):
    def test_lowercased_code_terms_score_perfect_words_but_fail_terms(self):
        s = entry("b", "s1", GOLD, HYP_B, terms=TERMS)
        self.assertEqual(s.word_errors, 0)
        self.assertEqual(s.term_refs, 4)
        self.assertEqual(s.term_misses, 3)
        self.assertEqual(s.missed_terms, ["App.tsx", "Supabase", "useEffect"])
        t = totals([s])
        self.assertEqual(t["wer"], 0.0)
        self.assertEqual(t["formatted_wer"], 0.5)
        self.assertEqual(t["term_error_rate"], 0.75)

    def test_split_words_fail_both(self):
        t = totals([entry("a", "s1", GOLD, HYP_A, terms=TERMS)])
        self.assertAlmostEqual(t["wer"], 6 / 13)
        self.assertAlmostEqual(t["formatted_wer"], 7 / 12)
        self.assertEqual(t["term_error_rate"], 1.0)

    def test_perfect_text_scores_zero_everywhere(self):
        t = totals([entry("p", "s1", GOLD, GOLD, terms=TERMS)])
        self.assertEqual((t["wer"], t["formatted_wer"], t["term_error_rate"], t["term_false_alarms"]),
                         (0.0, 0.0, 0.0, 0))


class WordsHeardRight(unittest.TestCase):
    def test_words_use_speech_text_and_terms_use_inserted_text(self):
        s = entry("x", "s1", "open App.tsx", speech="open app tsx", inserted="open App.tsx", terms=["App.tsx"])
        self.assertEqual(s.word_errors, 0)
        self.assertEqual(s.term_misses, 0)
        s = entry("y", "s1", "open App.tsx", speech="open App.tsx", inserted="open app.tsx", terms=["App.tsx"])
        self.assertEqual(s.term_misses, 1)

    def test_corpus_rate_is_total_errors_over_total_words_not_a_mean(self):
        ten = "red green blue cyan pink gray gold teal navy plum"
        long = entry("l", "s1", ten, ten)
        short = entry("s", "s1", "hello", "goodbye")
        self.assertAlmostEqual(totals([long, short])["wer"], 1 / 11)

    def test_normalizer_forgives_case_punctuation_and_fillers(self):
        s = entry("n", "s1", "Okay, let's ship it.", "um ok let's ship it")
        self.assertEqual(s.word_errors, 0)
        self.assertGreater(s.formatted_errors, 0)

    def test_a_newline_does_not_fuse_words(self):
        s = entry("w", "s1", "ship it now", "ship\nit now")
        self.assertEqual((s.word_errors, s.formatted_errors), (0, 0))

    def test_words_inserted_where_gold_has_none_are_errors(self):
        # The leaderboard drops entries whose gold normalizes to nothing. Lexicon
        # keeps them: typing words that were never said is a dictation error.
        t = totals([entry("a", "s1", "ship it", "ship it"), entry("b", "s1", "(laughs)", "hello there")])
        self.assertEqual(t["wer"], 1.0)

    def test_empty_hypothesis_is_all_deletions(self):
        s = entry("e", "s1", "ship it now", "")
        self.assertEqual((s.word_errors, s.ref_words), (3, 3))


class TermMatching(unittest.TestCase):
    def test_case_sensitive(self):
        self.assertEqual(term_counts("supabase and Supabase", ["Supabase"]), {"Supabase": 1})

    def test_whole_tokens_only(self):
        self.assertEqual(term_counts("useEffects and myuseEffect", ["useEffect"]), {})
        self.assertEqual(term_counts("open App.tsx.", ["App.tsx"]), {"App.tsx": 1})
        self.assertEqual(term_counts("(kubectl), kubectl's", ["kubectl"]), {"kubectl": 2})
        self.assertEqual(term_counts("\"App.tsx\"; then App.tsx?!", ["App.tsx"]), {"App.tsx": 2})

    def test_code_punctuation_and_dashes_end_a_term(self):
        self.assertEqual(term_counts("Run useEffect() on mount.", ["useEffect"]), {"useEffect": 1})
        self.assertEqual(term_counts("see App.tsx:12", ["App.tsx"]), {"App.tsx": 1})
        self.assertEqual(term_counts("I use Claude Code\u2026", ["Claude Code"]), {"Claude Code": 1})
        self.assertEqual(term_counts("Supabase\u2014and kubectl", ["Supabase"]), {"Supabase": 1})
        self.assertEqual(term_counts("fast\u2014Supabase", ["Supabase"]), {"Supabase": 1})

    def test_overlapping_occurrences_of_one_term_all_count(self):
        self.assertEqual(term_counts("ha ha ha", ["ha ha"]), {"ha ha": 2})

    def test_a_term_inside_a_longer_identifier_is_not_found(self):
        for text, term in [("use Node.js", "Node"), ("run lexicon-eval-v2", "lexicon-eval"),
                           ("open App.tsx.map", "App.tsx"), ("I write C++", "C"),
                           ("Next.jsx", "Next.js"), ("ASP.NET", ".NET"), ("pre-useEffect", "useEffect")]:
            with self.subTest(text):
                self.assertEqual(term_counts(text, [term]), {})
        self.assertEqual(term_counts("I write C++ and .NET", ["C++", ".NET"]), {"C++": 1, ".NET": 1})

    def test_casing_slip_on_a_longer_word_is_not_a_phantom_miss(self):
        s = entry("n", "s1", "use Node.js", "use node.js", terms=["Node"])
        self.assertEqual((s.term_refs, s.term_misses), (0, 0))

    def test_each_term_is_counted_on_its_own(self):
        counts = term_counts("SupabaseClient wraps Supabase", ["Supabase", "SupabaseClient"])
        self.assertEqual(counts, {"SupabaseClient": 1, "Supabase": 1})
        self.assertEqual(term_counts("Next.js app", ["Next", "Next.js"]), {"Next.js": 1})
        s = entry("o", "s1", "Claude Code Review", "Cloud Code Review", terms=["Claude Code", "Code Review"])
        self.assertEqual((s.term_refs, s.term_misses, s.term_false_alarms), (2, 1, 0))
        s = entry("t", "s1", "I use Claude Code", "I use Claude", terms=["Claude", "Claude Code"])
        self.assertEqual((s.term_misses, s.term_false_alarms), (1, 0))

    def test_nfc_and_nfd_spellings_are_one_term(self):
        self.assertEqual(term_counts("Beyonc\u00e9 sings", ["Beyonc\u00e9", "Beyonce\u0301"]), {"Beyonc\u00e9": 1})

    def test_unicode_is_compared_in_nfc(self):
        self.assertEqual(term_counts("Claude\u0301 is", ["Claude"]), {})
        self.assertEqual(term_counts("Beyonce\u0301 sings", ["Beyonc\u00e9"]), {"Beyonc\u00e9": 1})

    def test_repeats_count_each_occurrence(self):
        s = entry("r", "s1", "kubectl then kubectl", "kubectl then cube cuddle", terms=["kubectl"])
        self.assertEqual((s.term_refs, s.term_misses), (2, 1))

    def test_false_alarm_when_a_term_is_written_where_it_was_not_said(self):
        s = entry("f", "s1", "a super quick fix", "a Supabase quick fix", terms=["Supabase"])
        self.assertEqual((s.term_refs, s.term_misses, s.term_false_alarms), (0, 0, 1))
        self.assertEqual(s.false_alarm_terms, ["Supabase"])

    def test_extra_occurrence_is_a_false_alarm_not_a_hit(self):
        s = entry("x", "s1", "use Supabase", "use Supabase Supabase", terms=["Supabase"])
        self.assertEqual((s.term_misses, s.term_false_alarms), (0, 1))

    def test_no_terms_means_no_term_rate(self):
        t = totals([entry("n", "s1", "hello there", "hello there")])
        self.assertIsNone(t["term_error_rate"])

    def test_empty_or_padded_term_is_rejected(self):
        for bad in ["", "  ", " useEffect"]:
            with self.subTest(bad), self.assertRaises(ValueError):
                term_counts("x", [bad])


TEN = "red green blue cyan pink gray gold teal navy plum"


def run(n_sessions, per_session, errors):
    """Synthetic run: each entry has a 10-word gold; `errors(s, i)` words are wrong."""
    out = []
    for s in range(n_sessions):
        for i in range(per_session):
            k = errors(s, i)
            hyp = " ".join(["oops"] * k + TEN.split()[k:])
            out.append(entry(f"{s}-{i}", f"s{s}", TEN, hyp))
    return out


class PairedBootstrap(unittest.TestCase):
    def test_same_seed_same_interval(self):
        a = run(8, 3, lambda s, i: (s * 7 + i) % 4)
        b = run(8, 3, lambda s, i: (s * 3 + i) % 3)
        self.assertEqual(paired_bootstrap(a, b, seed=7, resamples=500),
                         paired_bootstrap(a, b, seed=7, resamples=500))

    def test_different_seed_moves_the_interval(self):
        a = run(20, 3, lambda s, i: (s * s + i) % 7)
        b = run(20, 3, lambda s, i: (s * 3 + i) % 5)
        one = paired_bootstrap(a, b, seed=1, resamples=500)["wer"]
        two = paired_bootstrap(a, b, seed=2, resamples=500)["wer"]
        self.assertEqual(one["diff"], two["diff"])
        self.assertNotEqual((one["low"], one["high"]), (two["low"], two["high"]))

    def test_identical_runs_tie_at_zero(self):
        a = run(10, 2, lambda s, i: s % 3)
        r = paired_bootstrap(a, a, seed=0, resamples=200)["wer"]
        self.assertEqual((r["diff"], r["low"], r["high"], r["verdict"]), (0.0, 0.0, 0.0, "tie"))

    def test_a_clearly_better_run_wins_outside_the_interval(self):
        a = run(10, 3, lambda s, i: 0)
        b = run(10, 3, lambda s, i: 2 + (s + i) % 2)
        r = paired_bootstrap(a, b, seed=0, resamples=1000)["wer"]
        self.assertLess(r["high"], 0)
        self.assertEqual(r["verdict"], "a_lower")
        self.assertEqual(paired_bootstrap(b, a, seed=0, resamples=1000)["wer"]["verdict"], "b_lower")

    def test_resamples_whole_sessions_not_entries(self):
        # One session: every resample draws that whole session, so the interval
        # collapses to the point. Resampling entries would spread it out.
        a = run(1, 6, lambda s, i: i % 2 * 4)
        b = run(1, 6, lambda s, i: 1)
        r = paired_bootstrap(a, b, seed=0, resamples=300)["wer"]
        self.assertEqual(r["low"], r["diff"])
        self.assertEqual(r["high"], r["diff"])

    def test_too_few_sessions_gives_no_verdict(self):
        a = run(9, 3, lambda s, i: 0)
        b = run(9, 3, lambda s, i: 3)
        r = paired_bootstrap(a, b, seed=0, resamples=300)["wer"]
        self.assertLess(r["high"], 0)
        self.assertEqual(r["verdict"], "too_few_sessions")

    def test_a_rare_term_gives_no_verdict(self):
        a = run(12, 2, lambda s, i: 0)
        b = list(a)
        a[0] = entry("0-0", "s0", "run kubectl", "run cube cuddle", terms=["kubectl"])
        b[0] = entry("0-0", "s0", "run kubectl", "run kubectl", terms=["kubectl"])
        r = paired_bootstrap(a, b, seed=0, resamples=500)["term_error_rate"]
        self.assertGreater(r["skipped"], 25)
        self.assertEqual(r["verdict"], "too_few_refs")

    def test_term_metrics_are_compared(self):
        a = [entry(f"{s}", f"s{s}", "run kubectl", "run kubectl", terms=["kubectl"]) for s in range(10)]
        b = [entry(f"{s}", f"s{s}", "run kubectl", "run cube cuddle", terms=["kubectl"]) for s in range(10)]
        r = paired_bootstrap(a, b, seed=0, resamples=200)
        self.assertEqual(r["term_error_rate"]["diff"], -1.0)
        self.assertEqual(r["term_error_rate"]["verdict"], "a_lower")
        self.assertEqual(r["term_false_alarms"]["diff"], 0)

    def test_runs_must_cover_the_same_entries(self):
        a = run(2, 2, lambda s, i: 0)
        with self.assertRaises(ValueError):
            paired_bootstrap(a, a[:-1], seed=0, resamples=10)

    def test_every_entry_needs_a_session(self):
        for session in (None, ""):
            a = [entry("1", session, "hi there", "hi there")]
            with self.subTest(session), self.assertRaises(ValueError):
                paired_bootstrap(a, a, seed=0, resamples=10)

    def test_runs_must_share_the_gold(self):
        a = run(2, 2, lambda s, i: 0)
        b = [EntryScore(**{**vars(e), "ref_words": 4}) for e in a]
        with self.assertRaises(ValueError):
            paired_bootstrap(a, b, seed=0, resamples=10)

    def test_resamples_must_be_positive(self):
        a = run(2, 2, lambda s, i: 0)
        with self.assertRaises(ValueError):
            paired_bootstrap(a, a, seed=0, resamples=0)

    def test_entries_in_a_session_must_agree_across_runs(self):
        a = run(2, 2, lambda s, i: 0)
        b = [EntryScore(**{**vars(e), "session": "other"}) for e in a]
        with self.assertRaises(ValueError):
            paired_bootstrap(a, b, seed=0, resamples=10)


if __name__ == "__main__":
    unittest.main()
