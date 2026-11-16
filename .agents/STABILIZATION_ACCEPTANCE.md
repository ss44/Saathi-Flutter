# Chat stabilization acceptance

Umbrella: #59. Delivery is one integrated chat/optimization PR, not one PR per worker. Original tickets remain acceptance checklists; do not close incomplete native/device-dependent scopes.

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

Current v2026.47.4 remains beta. No new stable release or extra manual native build is authorized by this batch request.
