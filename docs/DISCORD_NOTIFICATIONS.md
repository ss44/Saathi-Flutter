# Discord merged-PR notifications

`.github/workflows/discord-pr-merged.yml` posts **Job done!**, the merged PR's
GitHub link, and a randomly selected celebration GIF to the configured channel.
It chooses from three fixed GIF URLs; no GIF-service API key is required.

## Trigger and scope

The workflow observes pushes to `main` and checks GitHub's associated-PR metadata.
It notifies only closed, actually merged PRs whose merge commit is that push and
whose base is this repository's `main`. Closing without merging, direct pushes
without a matching merge, branch pushes and test/build completion do not post.

This avoids privileged `pull_request_target` execution and handles merged fork
PRs without exposing a secret to fork workflows. It performs no checkout and
never executes a PR's code, title, body or shell expressions. Permissions are
read-only. Native release scheduling and builds are unchanged.

## Secret

Configure repository Actions secret `DISCORD_PR_WEBHOOK_URL` with the complete
Discord webhook URL. Never commit the URL, place it in repository variables,
print it in logs or attach it to a PR. GitHub's token is sent only to GitHub;
the Discord credential is used only on the validated Discord webhook route.

## Delivery and verification

Mentions are disabled. The POST requests Discord's message acknowledgement,
then reads that exact message back to verify its PR link and GIF. Redirects are
not followed, response sizes and request timeouts are bounded, and failure logs
suppress sensitive URLs/response bodies.

An uncertain POST is not automatically retried. A failed workflow therefore may
need inspection before retrying; manually rerunning a successful notifier can
post another message. Concurrency prevents overlapping runs for the same commit,
not durable deduplication of deliberate reruns. This is a notification, not proof
that the merged change is released or installed.

## Local tests

```sh
python3 -m unittest discover -s tool -p 'test_discord_notification.py' -v
```

These tests execute the exact inline workflow script with controlled responses,
not production credentials. Actual GitHub-to-Discord delivery is separate evidence.
