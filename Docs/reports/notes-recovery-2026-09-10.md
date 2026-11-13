# Resumable notes recovery and partial results

A live GLM run extracted both transcript parts, then spent its entire 640-token repair allowance on reasoning. The second part remained incomplete, even though 24 notes and five actions were already saved. A second meeting returned `has_more=true`; its first part was never continued. The detail view loaded only completed artifacts and skipped bullet-form recaps, making saved work look empty.

## Changes

- Known OpenRouter GLM-5.3 engines reserve at least 2,048 output tokens for structured requests. A truncated repair can retry once with a larger allowance, up to the existing 4,096-token request ceiling. The larger requirement survives a restart. Local engines keep their existing small repair allowances.
- Each part checkpoints its accepted-record ledger, scan completion, pending repairs and next page. Up to three extraction pages and two repair calls can run per part in one attempt. Continuation requests ask only for additional records, retain the original evidence, allow distinct facts from the same source, and stop when the model repeats a page without progress. A completed scan with an unfinished repair resumes just the repair.
- Every request, including continuation, repair and transport recovery, stays inside the existing 600-second, 12-request and token limits. Added continuation text is checked against the context limit before sending. Invalid or missing citations and unsupported user ownership remain rejected.
- A single atomic partial snapshot keeps the displayed recap and actions together. The meeting detail view also reads revision-matched progress from the previous app version. It reloads after failure, labels partial work, and preserves evidence navigation. Partial actions are read-only until publication; prior user corrections remain visible. Completed outcome indexes and existing final artifacts retain their normal publication rules.
- The Overview now accepts the generated bullet-form TL;DR and ignores empty `None` placeholders. A current partial snapshot replaces the misleading speaker-change notice; actual stale artifacts continue to require refresh.

## Validation

- Focused native regressions: **93 passed, zero failed**.
- Complete native suite: **2,041 passed, zero failed, seven skipped**. Skips are the existing opt-in/environment-dependent tests.
- Strict SwiftLint and `git diff --check` pass. The Xcode project was regenerated from `project.yml`.
- Regression coverage includes output exhaustion, bounded paging, repeated-page detection, continuation after a request limit, persisted repair recovery, shared budget enforcement, same-source distinct facts, legacy partial visibility, stale revision rejection, completed artifact precedence, manual edits and bullet recaps.
- A hosted UI regression opens a synthetic partial meeting and checks the visible recap/actions, incomplete label, read-only actions and Full Summary tab. UI tests run on hosted macOS runners only.

These checks exercise deterministic failures and publication behavior. A model can still return unsupported or incomplete output; those cases must remain visibly partial rather than silently claiming completion. Live follow-through and hosted UI results are recorded in the pull request.
