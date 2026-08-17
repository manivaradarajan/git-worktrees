# Model Routing: DeepSeek V4 Pro vs V4 Flash

Working agreement for when this session should run on **DeepSeek V4 Flash**
(routine, fast, cheap) versus **DeepSeek V4 Pro** (hard reasoning, quality
critical). This file is loaded globally via `opencode.json` →
`instructions`. It is the **judgment** half of the routing system; the
**mechanical** half lives in the companion plugin
`model-routing-alarm.js` (failing test runs, same-file loops, green-phase
downgrades), which fires macOS notifications + session banners on its own.

## Default posture

Start on **Flash**. Escalate to **Pro** only when a task is genuinely hard or
quality-critical. Rule of thumb: Flash for ~95% of routine work; Pro when the
failure is *silent, subtle, or you've lost the thread*.

"Hard" is less about language than about three signals:

1. **Non-obvious failure modes** — a wrong answer that is silent and hard to
   catch (Unicode/NFC-NFD edge cases, combining marks, script shaping,
   Bazel dependency/toolchain resolution).
2. **No working hypothesis** — you've been staring at a failure for 20+
   minutes with no idea where it comes from.
3. **Cross-language boundaries** — Python ↔ TypeScript ↔ Next.js API contract
   mismatches, where type drift across the seam is exactly where a fast model
   hallucinates consistency.

## Pro / Flash working agreement

**Pro writes the spec and the golden tests. Flash implements to pass them.**

- Pro is better at exploration and getting it right first time: enumerating
  edge cases, deciding the canonical rule, capturing the user's domain
  knowledge as an executable contract.
- Flash is ideal at iterating against a deterministic green/red target.
- Golden tests must be **spec-preserving, not behavior-locking**: each test
  names the *why* it exists (e.g.
  `test_virama_between_samvriddhi_and_halanta_preserves_conjunct`), so
  re-goldening an arguably-wrong behavior becomes visibly wrong. Frequent
  re-goldening is the signal that Pro's spec was incomplete — take it back to
  Pro.
- The loop is *down* for volume, *up* only for divergence.

## Mechanical signals (handled by the plugin, no action needed here)

- 2 consecutive failing test runs (`pytest`, `bazel test`, `vitest`, `jest`,
  `npm test`, `go test`, `mix test`, `mvn test`) → **Pro**.
- 4 consecutive edits/writes to the same file → **Pro** (stuck loop).
- 5 consecutive green test passes while on Pro → **Flash** (mechanical phase).

## Judgment signals — emit a loud marker

When one of these fires, the agent must emit a loud, single-line marker so the
user notices:

```
⚠️ SWITCH-TO-PRO: <reason, one line>
```

or, to downgrade a routine phase:

```
⚠️ SWITCH-TO-FLASH: <reason, one line>
```

Trigger SWITCH-TO-PRO for:

- **Silent normalization corruption**: text that looks correct but subtly
  violates the normalization contract (Indic: NFC/NFD equivalence, virama /
  halanta, anusvara/visarga, nukta, ZWNJ/ZWJ, Vedic svara marks). This is the
  classic "wrong-but-passing" — a test passes because both sides are wrong the
  same way.
- **Cross-language contract drift**: Python ↔ TypeScript ↔ Next.js type/schema
  drift across the seam that you cannot reconcile from the local context.
- **Bazel build-graph weirdness**: dependency/toolchain errors whose cascade
  you cannot explain.
- **20+ minutes without a hypothesis** for a bug.

Trigger SWITCH-TO-FLASH when:

- The remaining work is mechanical (boilerplate, single-module refactors,
  wiring, applying a pattern that already exists in the repo) and you're on
  Pro.
- Everything is verifiable in minutes by a test or the build cache, so a wrong
  answer is cheap to catch.

When you emit a marker, also state in the same message whether you recommend
the switch immediately or after the current step completes.
