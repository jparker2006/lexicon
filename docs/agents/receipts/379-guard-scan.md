# Guard scan CLI evidence

Refs #379. Every input in these runs is a temporary synthetic fixture.

The CLI test was committed first as `cc69d44`. Against main's `fbd207a`
implementation, `guardScanCountsPresentTextAndPrintsOnlyAggregateCounts` failed:
the public dispatch and built executable returned usage exit 2.

After the implementation, this command passed at `9877a16`:

```sh
scripts/test.sh --filter 'guardScan|SecretGuard|scriptedTextEqualToGuardScanFlag'
```

The executable assertions cover exact aggregate output `scanned=3 matched=1`,
nonexistent audio paths, ignored review and split metadata, unchanged scratch
contents, zero matches, empty input, usage exit 2, and fixed failure exit 1.
Expanded tests first exposed a CRLF parsing failure. The scripted-text regression
also failed at `7522d49` before the parser correction in `9877a16`.

The full `scripts/check.sh` run at `9877a16` exited 0 before the FIFO coverage was
added. The final content needs its own full check and exact-head CI.

## FIFO finding

The review predicted that reading a named pipe would hang. The verifier supplied
`guardScanRejectsFIFOManifests`. Swift rejects a semaphore wait inside its async
test, so the test uses an AsyncStream completion signal instead.

The supplied test passed against the unchanged scanner from `9877a16`: public
dispatch returned failure exit 1. Extending the test to invoke the built executable
on the same pipe with no writer also passed, with failure exit 1 and the exact
fixed diagnostic. The child has a cancellation limit that bounds a hang.

```sh
scripts/test.sh --filter guardScanRejectsFIFOManifests
```

This command exited 0. The FIFO finding has no failing reproducer on this Mac.
No scanner code was changed for it. Review must reconcile the finding with this
execution evidence before Ready.
