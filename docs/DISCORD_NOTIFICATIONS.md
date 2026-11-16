# Discord merge and native-build notifications

`.github/workflows/discord-pr-merged.yml` shares one metadata-only notifier and
one verified delivery path for merged PRs and completed native build cycles.

## Trigger and scope

Pushes to `main` retain the original merged-only guard: the associated PR must
be closed, actually merged, and match that exact pushed merge SHA, base branch
and original repository. Direct pushes and closed-but-unmerged PRs do not post.
For each matching PR, a separate authoritative `GET /repos/{owner}/{repo}/pulls/{number}`
is revalidated before using its complete title and body. Ordinary text is inline
as data, not interpolated into shell code. A missing/empty body is labelled
**No description provided.** The PR link and random celebration GIF remain.

The only `workflow_run` subscription is `completed` for **Desktop and Android
binary releases**. It never starts a build, observes Verify Saathi, observes
itself, or generates an extra PR notification. The canonical repository is
`ss44/Saathi-Flutter`. The event's repository, head repository, run ID, attempt,
SHA, name, status and conclusion are checked against authoritative run metadata;
the workflow ID and path must match the existing `release-desktop.yml` workflow.
No checkout, artifacts or PR code are executed. Only read permissions are used;
`actions: read` is needed to inspect native run/job metadata.

Success reports the run link and the observed native-job outcome. Skipped native
jobs are explicitly not evidence of a new build/release; unchanged source is one
possible reason, not an invented cause. Even successful native jobs do not alone
claim publication. Failure, `timed_out` and `cancelled` remain distinct outcomes.
Failures include actual job names/conclusions and failed step names/conclusions,
with canonical job-log links, not raw logs or inferred root causes. Missing
details are labelled honestly. Jobs are fetched for the exact run attempt with
pagination (100/page, at most ten pages), checked against `total_count`, and
incomplete/changed/oversized inventories fail closed rather than post a partial
report. A separate three-URL failure GIF pool is used for unsuccessful cycles.
All three failure URLs returned HTTP 200 and actual `GIF89a` bytes in public GET
verification; live availability remains an external dependency.

## Complete text and delivery limits

Discord content is limited to 2,000 characters. The notifier conservatively counts
UTF-16 units, including astral Unicode. Reports over that limit use one complete
UTF-8 Markdown attachment containing the full report, full PR title/body where
applicable, and links. The message explicitly says the complete report is attached;
no title, description or failure list is silently truncated. The attachment
filename is generated from validated numeric IDs, never untrusted metadata.
A conservative local 8 MiB attachment cap fails before POST if exceeded. JSON
responses are capped at 1 MiB; HTTP requests have 20-second timeouts. These are
safety bounds, not a claim of unlimited Discord storage or API pagination.

The upload uses multipart `payload_json` and `files[0]`, with explicit attachment
metadata. Mentions are disabled for both paths. `wait=true` acknowledges the POST;
then the exact returned message ID is fetched and content/GIF are checked. If
attached, the filename and size must match, and a public GET of the validated
Discord CDN attachment must return byte-for-byte identical complete UTF-8 data.
No bearer token or webhook credentials are forwarded to that CDN GET. Unexpected
attachments and untrusted attachment URLs are rejected.

## Secret and recovery

Use the existing repository Actions secret `DISCORD_PR_WEBHOOK_URL`. Never commit,
print or put its value in repository variables. GitHub's token is sent only to
fixed GitHub API URLs; Discord credentials stay on the validated original webhook
route. Redirects are rejected for all requests. Network errors suppress URLs and
response bodies that could contain secrets. No uncertain POST is automatically
retried. Inspect delivery before deliberate reruns: they may duplicate messages.
Concurrency avoids overlapping notifications for the same commit/run attempt;
it is not durable deduplication.

## Verification

```sh
python3 -m unittest discover -s tool -p 'test_discord_notification.py' -v
python3 -m unittest discover -s tool -p 'test_*.py' -v
actionlint .github/workflows/discord-pr-merged.yml
```

Tests execute the exact inline script with controlled responses and synthetic
credentials: inline/empty/long/Unicode/hostile PR data, merge/base/SHA guards,
native success/skips/failure/timeouts/cancellation, identity rejection, pagination,
full-report attachments, upload bounds, transport/credential routing, readback
corruption, no redirects, no raw logs and no uncertain POST retries.

Real Discord delivery is separate acceptance. After review, CI and merge, the
integration owner must send three clearly labelled synthetic tests (PR, successful
build, failed build), read each back, and state these are tests rather than real
merges/build outcomes. Do not dispatch native builds or fake a real failure.

Primary contracts consulted:
- Discord Execute/Get Webhook Message: https://discord.com/developers/docs/resources/webhook
- Discord uploading files: https://discord.com/developers/docs/reference#uploading-files
- Official Discord API source: https://github.com/discord/discord-api-docs/tree/main/developers
- GitHub workflow_run: https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run
- GitHub exact-attempt jobs/pagination and Actions read permission: https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run-attempt
- GitHub authoritative PR: https://docs.github.com/en/rest/pulls/pulls#get-a-pull-request
