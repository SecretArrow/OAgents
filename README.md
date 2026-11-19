# OAgents

> Android AI agent app with opencode CLI embedded on-device.

[![CI](https://github.com/SecretArrow/OAgents/actions/workflows/ci.yml/badge.svg)](https://github.com/SecretArrow/OAgents/actions/workflows/ci.yml)
[![Release](https://github.com/SecretArrow/OAgents/actions/workflows/release.yml/badge.svg)](https://github.com/SecretArrow/OAgents/actions/workflows/release.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)

OAgents is a Flutter Android app that bundles the [opencode](https://opencode.ai)
CLI **inside its own process** and talks to it over a fixed loopback HTTP
endpoint (`http://127.0.0.1:4096`). There is no remote opencode server to
point at, no provider picker, no API-key drawer with ten entries, and no
local llama.cpp runtime to cross-compile. The opencode binary — a
Node-runnable JS bundle launched by a bundled NodeJS Mobile runtime — lives
in the APK, starts on-device, and serves the app sandbox only.

Localization ships for **English, Bahasa Indonesia, and Español**; this
README is English for consistency, with section headings kept in English.

---

## The key difference

### OAgents vs the official opencode mobile app

The official opencode mobile app is a **remote controller**: it talks to an
opencode instance running somewhere else (a dev box, a server, a cloud
session) and drives it from the phone. The opencode binary is **not** in the
official app.

OAgents is the opposite. The opencode binary **runs inside OAgents' own
process**, on the device:

| | Official opencode mobile app | OAgents |
|---|---|---|
| Where opencode runs | On a remote host | In the app's own process, on-device |
| Transport | Remote (cloud/LAN opencode) | Local loopback `127.0.0.1:4096` |
| Auth on the app→opencode hop | Remote credentials | None — loopback only, sandboxed |
| Network reachability | Reachable from the network | Unreachable from any other app or the network |
| Lifecycle | Owned by the remote host | Owned by OAgents (foreground service) |

### OAgents vs ZAgents

OAgents is a fork of **ZAgents**, a Flutter AI agent chat app. The fork makes
one decisive architectural change:

- **Removed from ZAgents:** every built-in AI provider — OpenRouter, Z.AI,
  OpenAI, Anthropic, AgentRouter, InferHub, Groq, DeepSeek, Nvidia NIM — and
  the **entire local-AI / Ollama / llama.cpp surface**. The provider preset
  screens, the per-provider key vault, the model catalog fetcher that pulled
  model lists from each provider, the Ollama manage screen, the Node-based
  preset editor, and the per-ABI llama.cpp build pipeline are all gone.
- **Added in OAgents:** the opencode CLI as the **sole** AI backend,
  **embedded on-device** via a bundled NodeJS Mobile runtime + opencode JS
  bundle, served on a fixed loopback port.

Everything else from ZAgents — the chat UX, the agent loop, the browser, the
scheduler, the module/plugin system, the security model — is kept and now
fronts the embedded opencode instead of the removed provider stack.

---

## Architecture overview

```mermaid
flowchart TD
    UI["Flutter UI<br/>(chat, settings, opencode setup screen)"]
    LOOP["Agent loop<br/>(agent_controller.dart)"]
    CFG["resolveOpencodeLlmConfig<br/>serverUrl = http://127.0.0.1:4096<br/>authToken = '' (loopback)<br/>model = settings.opencodeModel"]
    CLIENT["OpencodeClient<br/>(HTTP + SSE)<br/>lib/services/opencode_client.dart"]
    HTTP["http://127.0.0.1:4096<br/>(app sandbox loopback)"]
    BRIDGE["OpencodeRuntimeBridge<br/>(Kotlin platform channel)<br/>android/.../OpencodeRuntimeBridge.kt"]
    NODE["NodeJS Mobile + opencode.bundle.js<br/>(foreground service)"]
    OPC["opencode runtime<br/>(auth, models, MCP, agent tools)"]

    UI --> LOOP
    LOOP --> CFG --> CLIENT
    CLIENT -- "GET /health<br/>GET /models<br/>POST /chat/completions (SSE)" --> HTTP
    HTTP --> NODE
    UI -. "start / stop / status" .-> BRIDGE
    BRIDGE -- "spawn + keep-alive" --> NODE
    BRIDGE -- "status events" .-> UI
    NODE -- "require('./opencode.bundle.js')" --> OPC
```

Data flow for a chat turn:

1. The Flutter UI sends a message; the agent loop builds the message list
   and tool schema.
2. `resolveOpencodeLlmConfig(settings)` produces an `LlmConfig` pinned to
   `embeddedOpencodeUrl` (`http://127.0.0.1:4096`), empty auth token
   (loopback needs none), and `model = settings.opencodeModel`.
3. `OpencodeClient` POSTs to `/chat/completions` and consumes the SSE
   stream — assistant text deltas, tool-call deltas, a final usage chunk,
   and `[DONE]`.
4. On the other side of the loopback socket sits the opencode process,
   spawned by the Kotlin `OpencodeRuntimeBridge` running a bundled
   `opencode.bundle.js` under a bundled NodeJS Mobile runtime, kept alive by
   an Android foreground service.

---

## Features (kept from ZAgents)

All of these now drive the single embedded opencode backend instead of the
removed provider stack:

- **Streaming chat** — SSE token streaming, multi-session, per-session
  sandbox, abort/resume, token-usage accounting.
- **Agent mode with todo plans** — the agent loop plans via tool calls,
  tracks a todo list, executes tools, and fans out to subagents.
- **Fan-of-subagents** — parallel subagent runs (`subagents.dart`) each
  resolved against the same embedded `LlmConfig`.
- **Embedded browser automation (multi-context)** — headless WebView with
  per-session cookie and storage partitions (`browser_automation.dart`,
  `browser_session_isolation.dart`).
- **Cron scheduler** — scheduled agent runs, Telegram messages, and local
  notifications (`cron_scheduler.dart`).
- **Chat modules + skills** — installable JavaScript packages
  (`module.json` + `main.js`) sandboxed per chat via a typed `oagents.*` SDK
  (`module_runtime.dart`), plus `SKILL.md` skill packs (`skill_registry.dart`).
- **Session sandboxing** — each chat owns a private writable scope; chat A's
  module/storage can never reach chat B's.
- **App lock** — biometric + PIN, encrypted backups, IP-switch guard.
- **Background runs** — a foreground service keeps the opencode process
  alive while the app is backgrounded.
- **IP guard** — blocks sensitive operations when the network changes.
- **Localization** — English, Bahasa Indonesia, Español; dark and light themes.

---

## What was removed

Gone from the ZAgents codebase, with no replacement:

- Every provider preset — OpenRouter, Z.AI, OpenAI, Anthropic, AgentRouter,
  InferHub, Groq, DeepSeek, Nvidia NIM.
- Model catalog fetching from providers (the multiplexer that pulled model
  lists from each provider's API).
- The entire local-AI surface — Ollama management and the llama.cpp /
  llama-server runtime (the per-ABI cross-compile pipeline that lived
  under `.github/actions/llama-runtime`, now deleted).
- The AgentRouter routing layer.
- The `providers/`, `ollama/`, `node/`, and `preset-editor` screens.

What replaces them is not a new provider: it is the embedded opencode CLI,
which manages its **own** provider auth (see [Setup](#setup)).

---

## Setup

OAgents itself stores **no API keys**. The app ↔ opencode hop is loopback
inside the app sandbox and needs no auth. Provider credentials (OpenAI /
Anthropic / … API keys) are opencode's own concern and live in opencode's
own auth file inside the app's private storage, managed by opencode's
standard auth flow — never inside OAgents' settings.

To configure provider auth:

1. Open OAgents → **Settings → opencode** (the opencode setup screen).
2. The setup screen surfaces opencode's auth flow. Run
   `opencode auth login` from the app's opencode terminal once, then refresh.
3. Pick which model opencode should route to from the **Model** picker
   (fed by `GET /models` on the loopback endpoint).

There is no server URL field and no token field in OAgents' settings —
opencode runs on the fixed `http://127.0.0.1:4096` and the loopback hop is
unauthenticated by design.

---

## Build

**No local build is needed.** The recommended path is CI:

```bash
git tag v1.0.0
git push origin v1.0.0
# → release.yml builds split-per-ABI signed APKs and uploads them to GitHub Releases
```

CI, under `.github/workflows/`:

- **`ci.yml`** — on every push to `main` and every PR: `flutter analyze`,
  format check, sharded unit tests with coverage, a debug APK build, the
  Android-emulator E2E run (`integration_test/e2e_test.dart`), and an
  **auto-fix** job that applies `dart fix --apply` + `dart format` and
  commits the cleaned tree back to `main` (only on push to `main`, never on
  PRs from forks).
- **`bundle-opencode.yml`** — produces the **embedded runtime artifact**:
  it bundles the opencode source into `opencode.bundle.js`, writes
  `version.txt`, and drops a per-ABI `libnode.so` (NodeJS Mobile) into
  `android/app/src/main/jniLibs/<abi>/`. These artifacts are staged into
  `android/app/src/main/assets/opencode/` and `android/app/src/main/jniLibs/`
  at build time — they are gitignored and never committed.
- **`release.yml`** — on `v*` tags: builds split-per-ABI signed APKs
  (`arm64-v8a`, `armeabi-v7a`, `x86_64`) and uploads them to GitHub Releases.
- **`auto-fix.yml`** — on push to `main`: runs `dart fix --apply` +
  `dart format`, and auto-commits the result (`[skip ci]`) so lint drift
  never blocks a merge. Best-effort; unfixable lints do not fail the job.
- **`ci.yml`** / **`e2e.yml`** — on push/PR: `dart format --set-exit-if-changed`,
  `flutter analyze`, `flutter test` (unit + integration, both hermetic via
  the in-process mock opencode server).

To release: tag `v<version>` (e.g. `v1.0.0`) and push it — `release.yml`
calls `bundle-opencode.yml` to stage the embedded runtime, builds the APK,
and publishes the GitHub Release.

If you do want a local build (Flutter 3.47.x, Java 17):

```bash
flutter pub get
flutter build apk --split-per-abi   # optional; CI is the default path
```

Note that a local build without the CI-staged `opencode.bundle.js` /
`libnode.so` artifacts will report `state=failed` in **Settings → opencode**
with an actionable message — see [Honest limitations](#honest-limitations).

---

## Development

```bash
flutter pub get
flutter analyze
flutter test
```

The opencode HTTP contract is documented in
[`lib/services/opencode_client.dart`](lib/services/opencode_client.dart) and
fully expanded in [`docs/architecture.md`](docs/architecture.md). In short,
three OpenAI-shaped endpoints on `http://127.0.0.1:4096`:

- `GET /health` → `204`, no body (connection probe).
- `GET /models` → `{"data":[{"id":String,"name":String}]}`.
- `POST /chat/completions` → `text/event-stream`; SSE deltas for assistant
  text, tool calls, a final usage chunk, then `data: [DONE]`.

The platform channel contract (method channel
`com.secretarrow.oagents/opencode`, event channel
`com.secretarrow.oagents/opencode/status`) and the runtime state machine are
documented in [`docs/architecture.md`](docs/architecture.md).

The E2E harness is
[`integration_test/e2e_test.dart`](integration_test/e2e_test.dart): a
pure-Dart integration suite that swaps the LLM and browser for deterministic
in-process test doubles, so it runs hermetically on the emulator with no
network and no real opencode runtime.

---

## Security

- **No credentials in this app.** OAgents stores no provider API keys. The
  app ↔ opencode hop is loopback (`127.0.0.1:4096`) inside the app sandbox
  and carries no auth token; opencode manages its own provider auth in its
  own private storage.
- **`OAGENTS_CI_TOKEN`.** The auto-fix job (in `ci.yml`) and the release
  job (in `release.yml`) use a `OAGENTS_CI_TOKEN` GitHub Secret to push
  fixes/tags back to the repo. It lives **only** in GitHub Secrets and is
  **never** committed to the repo. The `.gitignore` excludes every common
  secret shape (`.env`, `*.token`, `*.key`, `*.keystore`, `*.jks`,
  `keystore.properties`, `*-base64.txt`, `secrets/`, `.secrets/`).
- **Revoke any token leaked in chat.** If a token, key, or credential is
  ever pasted into a chat, an issue, or a commit, treat it as compromised:
  revoke it at the provider immediately. No amount of `git history rewriting`
  unsends a secret that has already been seen.
- **CI-bundled artifacts are gitignored.** `opencode.bundle.js`,
  `version.txt`, `android/app/src/main/assets/opencode/`, and
  `android/app/src/main/jniLibs/` (the `libnode.so` runtimes) are produced
  by `bundle-opencode.yml` and never committed.

See [`SECURITY.md`](SECURITY.md) for reporting.

---

## Honest limitations

Be aware of these before building or shipping:

1. **The embedded runtime artifacts are not in the repo.** The
   `opencode.bundle.js`, `version.txt`, and per-ABI `libnode.so` are
   produced by the `bundle-opencode.yml` CI workflow and staged into
   `android/app/src/main/assets/opencode/` and
   `android/app/src/main/jniLibs/` at build time. Both paths are gitignored.
   A build that has **not** run `bundle-opencode.yml` will open the app
   fine, but **Settings → opencode** will report `state=failed` with an
   actionable message (e.g. "No Node runtime found. The CI bundle-opencode
   job must drop libnode.so into android/app/src/main/jniLibs/<abi>/ or
   assets/opencode/node-<abi>. Rebuild the APK after bundling.").

2. **`bundle-opencode.yml` is a CI assumption.** The Kotlin bridge
   (`android/app/src/main/kotlin/com/secretarrow/oagents/OpencodeRuntimeBridge.kt`)
   documents the exact bundled-asset layout it expects, and the exact
   opencode entry path it spawns:
   `node --eval "process.env.PORT='4096'; require('./opencode.bundle.js')"`
   with env `PORT=4096` and `OPENCODE_SERVE=1`. The NodeJS Mobile runtime is
   resolved as `nativeLibraryDir/libnode.so` (preferred, dropped by CI into
   `jniLibs/<abi>/libnode.so`) or a fallback static `node-<abi>` binary
   extracted from `assets/opencode/node-<abi>`. If neither is present the
   bridge reports `state=failed` instead of crashing. How the CI fetches
   the opencode source and the NodeJS Mobile build is documented in the
   workflow; it is not vendored in this repo.

3. **First-launch extraction.** On first launch (or when the bundled
   revision in `version.txt` changes) the bridge extracts the bundle and
   Node libs from APK assets to the app's private data dir. This is a
   one-time cost per revision; subsequent launches skip it.

4. **Foreground service.** The opencode process is kept alive by an Android
   foreground service (`OAgentsForegroundService`) with a persistent
   notification and wake lock. If the user or the OS kills that service
   while the app is backgrounded, the runtime transitions to `stopped` and
   must be restarted from Settings → opencode.

5. **Loopback only.** `127.0.0.1:4096` is reachable only from inside the
   app sandbox. No other app and no network host can reach the embedded
   opencode. This is deliberate; do not try to expose it.

---

## Project structure

```
OAgents/
├── lib/
│   ├── main.dart                      # entry, theme, app lock gate, boot ensureReady()
│   ├── di.dart                        # Riverpod providers, resolveOpencodeLlmConfig
│   ├── models/                        # TokenUsage, ToolCallRequest, CronJob, AppSettings…
│   ├── services/
│   │   ├── opencode_client.dart       # the sole AI backend HTTP/SSE client
│   │   ├── opencode_runtime.dart      # embedded runtime bridge facade (Dart side)
│   │   ├── llm_client.dart            # stream / cancel / retry policy
│   │   ├── agent_controller.dart      # agent loop, tool fan-out, todo plans
│   │   ├── browser_automation.dart    # headless WebView, multi-context
│   │   ├── cron_scheduler.dart        # scheduled jobs
│   │   ├── subagents.dart             # fan-of-subagents runner
│   │   ├── module_runtime.dart        # JS module sandbox
│   │   └── …                          # skills, fs, backup, app lock, ip guard, …
│   ├── tools/tool_defs.dart           # agent tool schema
│   ├── ui/screens/opencode_setup_screen.dart  # opencode state + model picker
│   └── l10n/                          # app_strings (en/id/es)
├── android/app/src/main/kotlin/com/secretarrow/oagents/
│   ├── OpencodeRuntimeBridge.kt       # platform channel + Node spawn + foreground svc
│   └── OAgentsForegroundService.kt    # keep-alive for the embedded opencode
├── docs/
│   ├── architecture.md                # HTTP + platform channel + state machine
│   └── modules/                       # module SDK reference (en + id)
├── integration_test/e2e_test.dart     # hermetic E2E with in-process doubles
├── test/                              # unit + widget tests, mock opencode server
├── .github/workflows/                 # ci, e2e, auto-fix, bundle-opencode, release
└── pubspec.yaml
```

---

## License

Apache-2.0. opencode itself is Apache-2.0; the bundled opencode source keeps
its license. The ZAgents-origin code carried into this fork keeps its
original license terms where they apply; everything else is Apache-2.0 as
stated here. See the `LICENSE` file if present in this repository.
