// Every file in LexiconTests sees Tests/TestSupport (writeWAV, compile,
// TestClock, runChild) without importing it: an exported import reaches the
// whole module.
@_exported import TestSupport
