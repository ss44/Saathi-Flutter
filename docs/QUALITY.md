# Quality checks

Run from the repository root with the pinned CI Flutter SDK and Python 3.13.
Both verification jobs use an immutable `actions/setup-python` pin and install
`tool/requirements-test.txt` before branding tests. Pillow is required by their
real image assertions; do not rely on runner-global packages. Locally, use a venv
rather than modifying the system Python (including externally managed installs):

```sh
python3.13 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r tool/requirements-test.txt
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --fatal-infos --fatal-warnings
flutter test --coverage --timeout 60s
python3 tool/check_coverage.py coverage/lcov.info --minimum 85
python3 -m unittest discover -s tool -p 'test_*.py' -v
python3 -m unittest discover -s test/branding -v
PR_TITLE='CI: Add quality checks' python3 tool/check_pr_title.py
# If installed:
actionlint
```

Resolve dependencies before formatting: package language versions affect Dart
formatting. Normal verification and the release verification job run the same
coverage, analysis, formatting, tooling and branding checks. Release triggers
remain weekly Monday 09:00 UTC and manual only; PR-title edits do not build
native binaries or publish releases.

## Coverage is a floor, not proof of safety

The gate is **at least 85% app Dart line coverage**, not branch coverage, averaged
file percentages, or test count. Run the full normal Flutter suite with coverage;
do not replace it with a selected subset or `--no-test-assets`. The previously
measured main baseline was 2692/2884 executable lines (about 93.34%), not 85%.
The denominator can change with SDK instrumentation and source changes; measure
it again rather than treating that historical result as a guarantee. At this
guardrail change, the full 214-test suite measured 2694/2885 lines (about 93.38%),
including the newly exercised conditional installer stub.

`tool/check_coverage.py` counts distinct resolved `lib/**/*.dart` file/line pairs.
Repeated DA records merge hits (any positive hit covers a line) without inflating
the denominator. SDK and dependency files outside the app are not counted. It
prints exact integer totals and a decimal percentage, and compares the unrounded
ratio against the threshold. It rejects missing, empty, oversized, incomplete or
malformed reports, inconsistent optional line summaries, and unexpected app
files absent from SF records. Reports are limited to 32 MiB; threshold syntax is
0–100 with at most six fractional decimal digits (no exponent syntax).

Missing files are **not assigned invented executable-line counts**. The only
currently accepted zero-executable source syntax is comments/whitespace plus
simple `library` and `export` directives, verified from the actual file contents
and listed in the output. No filename allowlist or generated-file exclusion is
used. Other declaration-only syntax fails closed until deliberately supported
with tests. In particular, the conditional unsupported-platform installer is
handwritten executable logic: its real rejection behavior is tested directly,
not excluded. Never add ignore directives, file filters, fake hits or reduced
suite selection merely to improve the percentage.

Critical negative-path tests still matter above 85%: credential privacy,
connection-bound dispatch, uncertain sends, storage failures, lifecycle changes,
untrusted update metadata and downloads, explicit installer consent, and
unsupported platform behavior. Aggregate coverage cannot prove these contracts,
native builds, device installation, signing, or live backend compatibility.

## Small safety lint set

Keep `flutter_lints` and additionally enable `unawaited_futures`,
`cancel_subscriptions`, `close_sinks`, `always_declare_return_types`, and
`use_rethrow_when_possible`. Infos and warnings are fatal in CI. Resolve findings
locally; do not silence them wholesale. No strict-dynamic migration or universal
public API documentation lint is imposed.

## PR titles and review

Use `<DOMAIN>: <summary>`, for example `CORE: Reject stale dispatch grants` or
`CI: Gate app line coverage`. Domain is uppercase ASCII letters/digits starting
with a letter. Summary must be nonempty, single-line and trimmed; titles are
limited to 256 characters, with no control characters. The read-only
`pull_request` title workflow handles opened, edited, reopened and synchronize
events; it passes the title through an environment variable, never shell source.

Review for SOLID responsibilities, clear concise names, and public documentation
where a contract, ownership boundary or non-obvious behavior needs explanation.
Prefer narrowly scoped changes and meaningful failure-path tests over percentage
chasing. Review is still required before committing these guardrails; this file
does not claim repository branch protection has been configured.
