# Domain privacy and Secret guard policies

Refs #372.

## Source and evidence map

| Policy | Production seam | Synthetic tests |
|---|---|---|
| Lowercase random-shaped secrets | `SecretGuard.matches` in `Sources/LexiconDomain/SecretGuard.swift` | `lowercaseRandomShapedSecretsMatch`, `lowercaseHuggingFaceKeyMatchesAloneAndInProse`, existing key/password positives and prose/code negatives in `SecretGuardTests.swift` |
| Deny before credentials | `Preferences.cloudDenied` then the guard in `CloudAccess.granted`, both in `Sources/LexiconDomain/Preferences.swift` | `EvalPrivacyPolicyTests.swift` counts supplied lookups for Muse eval, Private mode and private apps |
| Eval credential restriction | `CloudUse.allowsCredential` and the one lookup closure stored by `CloudAccess.granted` | `CloudCredentialPredicateTests.swift` covers every selected speech model against every speech credential, Cleanup and Jev |
| Case-insensitive private apps | `Preferences.cloudDenied` lowercases the supplied bundle ID and list entries for comparison only | `AppPrivacyPolicyTests.swift` covers casing, exact non-case differences, whitespace, empty/nonempty lists and unknown apps |
| Secret revokes before lookup | `CloudAccess.key(_:sending:)` delegates credential access to `key(_:)` after the Secret guard | `SecretGuardAccessTests.swift` checks no credential lookup, permanent revocation and allowed ordinary prose |
| Existing credential and revoke behavior | Both public `CloudAccess.key` methods consume the same stored lookup | `CloudCredentialPolicyTests.swift` covers app/model-install credentials and revocation before/during lookup; existing `CloudAccessTests.swift` stays in the full check |

The lowercase heuristic requires the existing minimum token length and at least twelve distinct lowercase letters. A known provider prefix uses the existing sixteen-character suffix minimum. Without a prefix, the twenty-four-character minimum and six consecutive consonants (treating y as a vowel) also apply. It supplements the existing mixed-letter/digit rule without a dictionary or classifier. It is a shape heuristic, not a guarantee of detecting every secret.

`lowercaseHuggingFaceKeyRevokesJevAccessBeforeLookup` checks the supported-prefix case through the public text-key path: the access revokes before any supplied lookup, and subsequent key access stays denied.

## Retention limit

Muse remains retention-unconfirmed. Its public eval grant is denied before any supplied lookup. No allowed-eval override, new CloudUse case or retention override was added.

The narrow internal predicate test does not claim an allowed eval grant was exercised. The source mapping closes that evidence gap: `granted` first checks privacy/retention, then stores only a closure that checks `allowsCredential` before calling the supplied lookup. The raw lookup has no second stored path. Both existing public key methods share that closure, including their existing revoke checks.

Defaults and persistence are unchanged. The domain tests use synthetic strings and lookups only. No provider call or live-app check is required. Parent integration acceptance remains on #335 and #336.
