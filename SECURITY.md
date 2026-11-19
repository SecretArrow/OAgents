# Security policy

## Reporting a vulnerability

Report security issues privately to the maintainer (the repo owner on
GitHub, via the "Security" → "Report a vulnerability" tab when available,
or by opening a **private** security advisory). Do **not** open a public
issue for a security vulnerability. Include a description of the issue, the
steps to reproduce, and the affected version. You will get an acknowledgement
and a fix timeline.

## The app stores no credentials

OAgents stores **no API keys and no provider tokens**. The opencode CLI runs
embedded inside the app on a fixed loopback endpoint
(`http://127.0.0.1:4096`) that is reachable only from inside the app sandbox,
so the app → opencode hop needs no auth. Provider credentials (OpenAI,
Anthropic, … API keys) are opencode's own concern — they live in opencode's
own auth file inside the app's private storage and are managed by opencode's
standard `opencode auth login` flow, never inside OAgents' settings or
SharedPreferences.

## Revoke any token leaked in chat

If a token, API key, keystore, or any other credential is ever pasted into a
chat, an issue, a PR description, a commit message, or a file in this repo,
treat it as compromised immediately: revoke it at the provider before doing
anything else. No amount of git history rewriting or force-pushing unsends a
secret that has already been seen by a CI runner, a fork, or a mirror.
Rotate, then clean up.

## CI token

The auto-fix job (`ci.yml`) and the release job (`release.yml`) use a
`OAGENTS_CI_TOKEN` GitHub Secret to push fixes and tags back to the repo.
That token lives **only** in GitHub Secrets — it is never committed to the
repo, never printed in logs, and scoped to the least privilege the job
needs. The `.gitignore` excludes every common secret shape
(`.env`, `.env.*`, `*.token`, `*.key`, `*.keystore`, `*.jks`,
`keystore.properties`, `*-base64.txt`, `secrets/`, `.secrets/`) so an
accidental local secret file is not tracked. If you believe the CI token has
leaked, revoke it in the repo's Settings → Secrets and rotate it.
