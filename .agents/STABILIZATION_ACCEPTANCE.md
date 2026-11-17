# Chat stabilization acceptance

Umbrella: #59. Delivery is one integrated chat/optimization PR, not one PR per worker. Original tickets remain acceptance checklists; do not close incomplete native/device-dependent scopes.

## Current user-selected delivery scope

Hermes first. [The current acceptance table](../docs/HERMES_DELIVERY_ACCEPTANCE.md)
supersedes the all-provider/media delivery order below, while preserving these
original checklists as provenance. Issue #16 / new OpenClaw is deferred until
Hermes is accepted; isolated work is preserved and not integrated. New #7/#9
media/vision/SAF app wiring and feature-only tests are isolated in the complete
pre-scope WIP snapshot, not reachable in this delivery. Existing shared chat,
personas, organization, unread, usage, journal and queue correctness remain gates.
The worker cannot merge or dispatch a build; exact-diff independent review and
parent-owned CI/merge/beta gates still apply.

## Priority order

1. #37/#38: stuck thinking, delivered replies, streaming, busy input and genuine continuation of existing server conversations.
2. #29/#34: hidden optimizer entry, preview/apply/undo, separate global/per-chat destination selection and privacy.
3. #28/#14: conversation organization, shared personas, actual read visibility and reported usage.
4. #7/#9: deliberate image generation and attachment/share-to-draft, without unsolicited uploads or image fetching.
5. #16: controlled native OpenClaw pairing and interactive go/no-go evidence.

## Cross-feature checks

- [ ] Reproduce thinking/completion failures through controlled real transport before the fix; record the exact failing and passing commands.
- [ ] Long native work accepts supported new guidance or clearly labelled next-turn input without duplicate runs, silently merged messages or falsely delivered receipts.
- [ ] Open an externally created authorized conversation, send into that same session and reconcile the authoritative reply; no transcript cloning.
- [ ] Lost replies, ambiguous acknowledgements and restart recover original operations without automatic resend.
- [ ] Approvals, child activity and queued drafts coexist above the bottom-pinned composer at 360/390px, 2x text and with the keyboard open.
- [ ] Preserve current draft, focus and reader scroll position; reveal new-message feedback rather than forcing a scrolled-up reader to the bottom.
- [ ] Long-press Send opens actions, release/dismiss never sends, ordinary tap still sends once; accessibility and keyboard alternatives work.
- [ ] Optimizer destination selection never mutates the response model, falls back silently or executes an agent/tool request as a text rewrite.
- [ ] Shared persona edits preserve captured context for accepted work and disclose changes to affected future chats.
- [ ] Unread clears only when a completed reply is actually visible in the foreground; replay and restart do not create duplicates.
- [ ] Archive/rename preserve source identities, history and running work, including after failed persistence.
- [ ] Token/context displays use reported data and clearly identify unavailable values; no speculative prices or exact percentages.
- [ ] Image selection/share only creates a reviewable source-bound draft; generation/upload requires explicit consent and preserves uncertain paid outcomes without automatic retry.
- [ ] Existing unsolicited Markdown image blocking, secure credentials, update validation and permanent signing identity remain intact.
- [ ] Full integrated normal suite, >=85% app line coverage, fatal analyzer, formatting, tooling, branding and workflow checks pass.
- [ ] Independent security/logic and user-flow reviews cover the exact complete integrated diff and original ticket criteria.

## Evidence must be labelled

Controlled fixtures, a listening official backend, a native build, a phone and the user's deployed server prove different things. Record each separately. No production credentials or paid calls are used by automated work. Backend bootstrap/pairing/device blockers remain explicit rather than being hidden behind unsupported controls.

Current v2026.47.4 remains beta. The user's later authorization permits one manual run of the existing signed weekly beta workflow (`.github/workflows/release-desktop.yml`) only after the final combined PR60 scope is ready, exact-complete-diff independent review and applicable CI pass, and its squash merge is verified by remote readback. The parent integration owner alone may dispatch from the verified final merge SHA on `main`, record the run ID, and confirm an actual native build job has started; queued/preparing/verification states are not yet building. Do not dispatch from a partial/draft head, repeat an uncertain dispatch, alter the permanent signing identity, or label this release stable. This supersedes the earlier no-extra-manual-build restriction, not the remaining integration and review gates.
