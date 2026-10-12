import Foundation

/// True only in a timing run: `LEXICON_TIMING=1 scripts/test.sh --filter <test>`,
/// best on a quiet Mac (`scripts/lib/heavy.sh --quiet`). A test that measures
/// speed against a budget says `@Test(.enabled(if: timingRun))`, so the check,
/// which must not depend on machine speed, never runs it, and
/// scripts/check-tests.swift skips its body.
public let timingRun = ProcessInfo.processInfo.environment["LEXICON_TIMING"] != nil
