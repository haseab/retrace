<!--
Canonical issue body template for AI-authored bug reports in Retrace.

Rules:
- Keep observed facts separate from inferred causes.
- Prefer exact versions, timestamps, file paths, and log excerpts.
- If something is not verified, write Unknown.
- Keep reproduction steps minimal and deterministic.
- Do not claim a fix or root cause unless it has been verified.
-->

## Summary

<1-3 sentences describing the bug and the current impact>

## User Impact

- Severity: <Crash / Data loss / Incorrect results / Performance / Minor / Unknown>
- Scope: <Who is affected>
- Frequency: <Always / Intermittent / Rare / Unknown>

## Observed Behavior

- <Observed fact 1>
- <Observed fact 2>

## Expected Behavior

- <What should happen instead>

## Reproduction

1. <Step 1>
2. <Step 2>
3. <Step 3>

## Evidence

- App version: <version or Unknown>
- Build/source: <Debug / Release / /Applications/Retrace.app / Unknown>
- macOS version: <version or Unknown>
- Hardware: <Apple Silicon model or Unknown>
- Logs / crash excerpts:

```text
<Exact excerpt or Unknown>
```

- Screenshots / attachments: <absolute paths, links, or None>
- Related files / code paths: <absolute paths or Unknown>

## Environment

- Date observed: <YYYY-MM-DD or Unknown>
- Branch / commit: <branch and commit SHA or Unknown>
- Permissions state: <Screen Recording / Accessibility / Unknown>
- Storage / database state: <relevant context or Unknown>

## Suspected Area (Inference)

- Confidence: <Low / Medium / High / Unknown>
- Area: <module, file, or Unknown>
- Why this is suspected: <reasoning or Unknown>

## Acceptance Criteria

- [ ] <Condition that confirms the bug is fixed>
- [ ] <Regression check or follow-up verification>

## Unknowns

- <Open question 1>
- <Open question 2>
