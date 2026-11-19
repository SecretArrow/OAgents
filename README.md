# OAgents

> Android AI agent app with opencode CLI embedded on-device.

[![CI](https://github.com/SecretArrow/OAgents/actions/workflows/ci.yml/badge.svg)](https://github.com/SecretArrow/OAgents/actions/workflows/ci.yml)
[![Release](https://github.com/SecretArrow/OAgents/actions/workflows/release.yml/badge.svg)](https://github.com/SecretArrow/OAgents/actions/workflows/release.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)

OAgents is a Flutter Android app that embeds a **complete Node.js toolbox
inside its own APK** — not just the [opencode](https://opencode.ai) CLI —
and drives opencode over a fixed loopback HTTP endpoint
(`http://127.0.0.1:4096`). There is no remote opencode server to point at,
no provider picker, no API-key drawer with ten entries, and no local
llama.cpp runtime to cross-compile. The toolbox tree (an esbuild-bundled
`opencode.bundle.js` + a curated `lib/node_modules` of crypto / developer /
browser packages + a CI-generated `modules.json` manifest + per-ABI Node.js
and agent-browser binaries + `version.txt`) ships inside the APK at
`assets/toolbox/toolbox.tar.gz`, is extracted to `filesDir/toolbox/` at
first launch by the native Kotlin bridge `OpencodeRuntimeBridge.kt`, and is
spawned under a per-ABI Node runtime — a real Termux-built `node`
executable (node 26, built against Android's Bionic libc + NDK r30, "for
Android 24"), exec'd directly from `filesDir/toolbox/bin/node-<abi>` with
`LD_LIBRARY_PATH=filesDir/toolbox/lib/<abi>` so Bionic's dynamic linker
resolves its companion `.so` libs ahead of the binary's baked RUNPATH. It
serves the app sandbox only — no other app and no network host can reach
it.

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
  **embedded on-device** via a bundled Node.js toolbox — an esbuild-bundled
  `opencode.bundle.js` running under a per-ABI Termux-built `node`
  executable (node 26, Bionic libc + NDK r30, "for Android 24"), exec'd
  from `filesDir/toolbox/bin/node-<abi>` with
  `LD_LIBRARY_PATH=filesDir/toolbox/lib/<abi>`, plus a curated
  `lib/node_modules` of crypto / developer / browser packages — extracted to
  `filesDir/toolbox/` by the Kotlin `OpencodeRuntimeBridge.kt` and served on
  a fixed loopback port. The toolbox is not just the opencode CLI; it is a
  full on-device Node environment the chat modules and agent tools can
  `require()` against with zero per-script install.

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
    TOOLBOX["Node toolbox<br/>filesDir/toolbox/<br/>(opencode.bundle.js + node_modules<br/>+ node/&lt;abi&gt; + agent-browser&lt;abi&gt;/-js)"]
    SVC["OAgentsForegroundService<br/>(keep-alive + wake lock)"]
    OPC["opencode runtime<br/>(auth, models, MCP, agent tools)<br/>node opencode.bundle.js serve --port 4096"]

    UI --> LOOP
    LOOP --> CFG --> CLIENT
    CLIENT -- "GET /health<br/>GET /models<br/>POST /chat/completions (SSE)" --> HTTP
    HTTP --> OPC
    UI -. "start / stop / status" .-> BRIDGE
    BRIDGE -- "extract toolbox.tar.gz<br/>select ABI<br/>chmod +x<br/>spawn + env" --> TOOLBOX
    BRIDGE -- "start / stop" --> SVC
    SVC -- "keep-alive" --> OPC
    BRIDGE -- "status events" .-> UI
    TOOLBOX -- "node opencode.bundle.js serve<br/>NODE_PATH=toolbox/lib/node_modules<br/>PATH=toolbox/bin:$PATH" --> OPC
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
   spawned by the Kotlin `OpencodeRuntimeBridge` as
   `node opencode.bundle.js serve --port 4096` inside the extracted
   `filesDir/toolbox/` tree, under a per-ABI Node runtime, kept alive by an
   Android foreground service. `NODE_PATH=toolbox/lib/node_modules` is set
   in the spawn env so every curated package (`ethers`, `web3`, `viem`,
   `playwright-core`, …) resolves without per-script install.

---

## Bundled Node toolbox

OAgents ships a **full Node.js toolbox** inside the APK, not just the
opencode CLI. The tree is extracted from `assets/toolbox/toolbox.tar.gz` to
`filesDir/toolbox/` on first launch by `OpencodeRuntimeBridge.kt`, and is
the on-device environment that both the opencode runtime and the chat
modules `require()` against.

```
toolbox/
  bin/
    node-<abi>            per-ABI Termux Node.js executable (node 26, Bionic
                          libc + NDK r30, "for Android 24"), selected at
                          runtime for the device ABI (arm64-v8a /
                          armeabi-v7a / x86_64) and exec'd with
                          LD_LIBRARY_PATH=toolbox/lib/<abi>.
    npm / npx             shell shims that exec the per-ABI node with
                          npm-cli.js / npx-cli.js (reading $OAGENTS_ABI to
                          pick the right node binary).
    agent-browser-<abi>   per-ABI Rust musl-static agent-browser CLI
                          (optional; JS shim fallback bin/agent-browser-js).
    agent-browser-js      Node shim that delegates to the agent-browser npm pkg.
  lib/
    <abi>/*.so*           per-ABI companion shared libs the Termux node
                          binary links against (libc++_shared.so,
                          libcares.so, libcrypto.so.3, libffi.so,
                          libicui18n.so.79, libicuuc.so.79, libsqlite3.so,
                          libssl.so.3, libz.so.1) staged for arm64-v8a /
                          armeabi-v7a / x86_64.
    node_modules/         pre-installed packages the embedded opencode runtime
                          AND chat modules can require() with no per-script
                          install. Curated set (see below).
    opencode.bundle.js    opencode CLI source bundled into one Node-runnable file.
    package.json          opencode's package.json (for the require graph).
  modules.json            CI-generated manifest of every bundled package +
                         version, categorized (crypto / dev / browser). Read
                         by lib/services/toolbox_manifest.dart and shown in
                         Settings → opencode "Embedded Node toolbox" card.
  version.txt            revision string: opencode-<sha>+toolbox-<sha>.
```

The curated `lib/node_modules` set, grouped by purpose:

| Category | Packages |
|---|---|
| **Crypto / web3** | `ethers@6`, `web3@4`, `viem`, `@solana/web3.js`, `@solana/spl-token`, `bitcoinjs-lib`, `@noble/secp256k1`, `@noble/ed25519`, `@noble/hashes`, `@noble/curves`, `bip39`, `bip32`, `hdkey`, `crypto-js`, `bs58`, `tweetnacl`. The native-addon `secp256k1` is overridden to the pure-JS `@noble/secp256k1` so the toolbox runs under any Android Node runtime without a toolchain. |
| **Developer** | `typescript`, `esbuild`, `tsx`, `prettier`, `vitest`, `zx`, `commander`, `chalk`, `dotenv`, `axios`, `lodash`, `zod`, `date-fns`, `p-map`, `p-queue`, `node-fetch`. |
| **Browser** | `agent-browser` (npm package + optional Rust binary), `playwright-core` (pure-JS API only — Chromium itself is NOT shipped, see [Honest limitations](#honest-limitations)). |

The exact package list and versions are pinned in the CI workflow's
curated `package.json` and reflected verbatim in `modules.json`. Settings →
opencode reads that manifest via `lib/services/toolbox_manifest.dart` and
shows it in the "Embedded Node toolbox" card **before** the runtime is
started — the manifest and `version.txt` are staged loose in
`assets/toolbox/` so Dart can read them through `rootBundle` without
launching opencode.

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
- **`bundle-opencode.yml`** — the **"Bundle opencode + Node toolbox"**
  workflow. Produces the `oagents-toolbox` workflow artifact containing:
  - `assets/toolbox/toolbox.tar.gz` — the full toolbox tree: `bin/{node-<abi>
    ×3, npm, npx, agent-browser-js, agent-browser-<abi>?}`,
    `lib/{<abi>/*.so ×3, node_modules/(curated + opencode bundle +
    package.json)}`, `modules.json`, `version.txt`. The esbuild
    `opencode.bundle.js`, the curated `lib/node_modules` of crypto / dev /
    browser deps via `npm install --omit=dev`, the CI-generated
    `modules.json`, the `agent-browser-js` shim, the per-ABI `node-<abi>`
    Termux executables + companion `.so` libs, and the `npm`/`npx` shims
    are all packed into this one tarball.
  - `assets/toolbox/version.txt` and `assets/toolbox/modules.json` — also
    staged **loose** alongside the tarball, so Dart can read them through
    `rootBundle` (via `lib/services/toolbox_manifest.dart`) and Settings →
    opencode can show the manifest + version **without launching opencode**.

  The "Fetch per-ABI Node.js + companion libs from Termux" step is a real,
  reproducible fetcher (not best-effort). For each Android ABI
  (arm64-v8a→aarch64, armeabi-v7a→arm, x86_64→x86_64) it downloads the
  Termux `Packages` index from
  `https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-<arch>/Packages`,
  looks up each dep (`nodejs npm libc++ openssl c-ares libicu libsqlite
  zlib libffi libandroid-spawn libuv libnghttp2 brotli`) by exact
  `Package: <name>` line match (not regex — needed because of `libc++`),
  downloads the `.deb`, and `dpkg-deb -x` extracts it. It stages
  `nodejs`'s `usr/bin/node` → `bin/node-<abi>`, collects every
  `usr/lib/*.so*` from all deps → `lib/<abi>/`, and stages `npm`'s
  `usr/lib/node_modules/npm` → shared `lib/node_modules/npm` plus
  `bin/npm` + `bin/npx` shell shims that exec the per-ABI node with
  `npm-cli.js` / `npx-cli.js` (reading `$OAGENTS_ABI` to pick the right
  node binary). A "Verify node ELF arch matches target ABI" step then
  `readelf -h`'s each `node-<abi>` and greps the `Machine:` line for the
  expected substring (`AArch64` / `ARM` / `X86-64`), failing the build if
  the arch is wrong. The per-ABI `agent-browser-<abi>` Rust musl-static
  binary is fetched separately from `vercel-labs/agent-browser`. The
  staged `assets/toolbox/` tree is gitignored and never committed.
- **`release.yml`** — on `v*` tags: downloads the `oagents-toolbox`
  artifact, stages only `assets/toolbox/{toolbox.tar.gz, version.txt,
  modules.json}` into `android/app/src/main/assets/toolbox/` (nothing is
  staged into `jniLibs/` — the node runtime lives inside the tarball),
  then builds split-per-ABI signed APKs (`arm64-v8a`, `armeabi-v7a`,
  `x86_64`) and uploads them to GitHub Releases.
- **`auto-fix.yml`** — on push to `main`: runs `dart fix --apply` +
  `dart format`, and auto-commits the result (`[skip ci]`) so lint drift
  never blocks a merge. Best-effort; unfixable lints do not fail the job.
- **`ci.yml`** / **`e2e.yml`** — on push/PR: `dart format --set-exit-if-changed`,
  `flutter analyze`, `flutter test` (unit + integration, both hermetic via
  the in-process mock opencode server).

To release: tag `v<version>` (e.g. `v1.0.0`) and push it — `release.yml`
downloads the `oagents-toolbox` artifact produced by `bundle-opencode.yml`,
stages only `assets/toolbox/{toolbox.tar.gz, version.txt, modules.json}`
under `android/app/src/main/assets/toolbox/` (no `jniLibs/` staging — the
per-ABI Termux `node` executables and companion libs ship inside the
tarball), builds the APK, and publishes the GitHub Release.

If you do want a local build (Flutter 3.47.x, Java 17):

```bash
flutter pub get
flutter build apk --split-per-abi   # optional; CI is the default path
```

Note that a local build without the CI-staged
`assets/toolbox/toolbox.tar.gz` (which carries the per-ABI Termux `node`
executables and companion `.so` libs) will report `state=failed` in
**Settings → opencode** with an actionable message naming the missing ABI
— see [Honest limitations](#honest-limitations).

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
- **CI-bundled artifacts are gitignored.** The whole toolbox tree under
  `android/app/src/main/assets/toolbox/` (the `toolbox.tar.gz` tarball,
  which carries the per-ABI Termux `node` executables, their companion
  `.so` libs, the `npm`/`npx` shims, and the `agent-browser-<abi>`
  binaries, plus the loose `version.txt` + `modules.json`) is produced by
  `bundle-opencode.yml` and never committed.

See [`SECURITY.md`](SECURITY.md) for reporting.

---

## Honest limitations

Be aware of these before building or shipping:

1. **Playwright Chromium is NOT shipped.** Playwright's bundled browsers
   are built for glibc desktop Linux and cannot run on Android's Bionic
   libc (and are ~150 MB+ each, which is unacceptable in an APK anyway).
   The toolbox ships `playwright-core` (the pure-JS API) so
   `require('playwright')` resolves and scripts using the API type-check,
   but actual browser automation on-device is driven by the app's
   **embedded WebView** (`flutter_inappwebview`, already a dependency)
   through the agent's `browser_navigate` / `browser_click` /
   `browser_type` / etc. tools — see `lib/services/browser_automation.dart`
   and `live_browser_controller.dart`. `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`
   is set in the spawn env so Playwright never tries to fetch Chromium at
   runtime.

2. **agent-browser** ships as a per-ABI Rust musl-static binary when one is
   available (musl-static binaries are self-contained, so they run on
   Android's Bionic libc without a glibc dependency); otherwise the Node JS
   fallback shim `bin/agent-browser-js` is used, which itself needs a
   browser backend → routed to the app's embedded WebView.

3. **The embedded Node toolbox artifacts are not in the repo.** The
   `assets/toolbox/toolbox.tar.gz` tarball (which carries the per-ABI
   Termux `node` executables, their companion `.so` libs, the `npm`/`npx`
   shims, and the `agent-browser-<abi>` binaries), the loose `version.txt`
   + `modules.json`, and the curated `lib/node_modules` are all produced
   by the `bundle-opencode.yml` CI workflow and staged into
   `android/app/src/main/assets/toolbox/` at build time. That path is
   gitignored. A build that has **not** run `bundle-opencode.yml` will open
   the app fine, but **Settings → opencode** will report `state=failed`
   with an actionable message naming the missing ABI (e.g. *"No Node
   runtime found for arm64-v8a. The CI bundle-opencode job must stage the
   Termux node binary at assets/toolbox/bin/node-arm64-v8a (inside
   toolbox.tar.gz). Rebuild the APK after bundling."*).

4. **APK size is meaningful (~150–250 MB).** The APK carries three
   per-ABI Termux `node` executables (~36–51 MB each), their companion
   `.so` libs (crypto / ICU / sqlite / …), and the curated
   `lib/node_modules`. This is the cost of a fully self-contained
   on-device Node + crypto + developer toolbox with zero runtime download;
   acceptable for a GitHub Release APK (no Play Store 200 MB single-APK
   limit applies), but expect a long initial install. The Termux fetch is
   reproducible (exact `Package:` line match against the Termux `Packages`
   index + `dpkg-deb -x` extraction) and an ELF arch check (`readelf -h`
   → `Machine:` line) fails the build if a `node-<abi>` does not match its
   target ABI, so a missing or wrong-arch runtime is caught at CI rather
   than at first launch.

5. **Native crypto addons replaced with pure-JS.** The native-addon
   `secp256k1` is overridden to `@noble/secp256k1` (pure JS) so the toolbox
   runs under any Android Node runtime without a native toolchain. Other
   native-addon packages, if any, get the same treatment or are omitted
   from the curated `lib/node_modules` set.

6. **Foreground service.** The opencode process is kept alive by an Android
   foreground service (`OAgentsForegroundService`) with a persistent
   notification and wake lock. If the user or the OS kills that service
   while the app is backgrounded, the runtime transitions to `stopped` and
   must be restarted from Settings → opencode.

7. **Loopback only.** `127.0.0.1:4096` is reachable only from inside the
   app sandbox. No other app and no network host can reach the embedded
   opencode toolbox. This is deliberate; do not try to expose it.

8. **The exact opencode source entry path** bundled by CI
   (`packages/opencode/src/index.ts` on the `dev` branch) is an assumption;
   if `sst/opencode` moves it, update that one line in `bundle-opencode.yml`.
   The CI workflow does not silently paper over a moved entry point — a
   failed esbuild bundle fails the `bundle-opencode.yml` job loudly.

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
│   │   ├── toolbox_manifest.dart      # loads modules.json + version.txt from assets
│   │   ├── llm_client.dart            # stream / cancel / retry policy
│   │   ├── agent_controller.dart      # agent loop, tool fan-out, todo plans
│   │   ├── browser_automation.dart    # headless WebView, multi-context
│   │   ├── live_browser_controller.dart  # WebView backend for agent browser tools
│   │   ├── cron_scheduler.dart        # scheduled jobs
│   │   ├── subagents.dart             # fan-of-subagents runner
│   │   ├── module_runtime.dart        # JS module sandbox
│   │   └── …                          # skills, fs, backup, app lock, ip guard, …
│   ├── tools/tool_defs.dart           # agent tool schema
│   ├── ui/screens/opencode_setup_screen.dart  # opencode state + model picker + toolbox card
│   └── l10n/                          # app_strings (en/id/es)
├── android/app/src/main/kotlin/com/secretarrow/oagents/
│   ├── OpencodeRuntimeBridge.kt       # platform channel + toolbox extract + Node spawn + foreground svc
│   └── OAgentsForegroundService.kt    # keep-alive for the embedded opencode
├── android/app/src/main/assets/toolbox/   # CI-staged, gitignored (toolbox.tar.gz + loose version.txt/modules.json)
├── android/app/src/main/jniLibs/          # empty (.gitkeep); no .so shipped — node runtime lives in toolbox.tar.gz
├── docs/
│   ├── architecture.md                # HTTP + platform channel + toolbox + state machine
│   └── modules/                       # module SDK reference (en + id)
├── integration_test/e2e_test.dart     # hermetic E2E with in-process doubles
├── test/                              # unit + widget tests, mock opencode server
├── .github/workflows/                 # ci, e2e, auto-fix, bundle-opencode (oagents-toolbox artifact), release
└── pubspec.yaml
```

---

## License

Apache-2.0. opencode itself is Apache-2.0; the bundled opencode source keeps
its license. The ZAgents-origin code carried into this fork keeps its
original license terms where they apply; everything else is Apache-2.0 as
stated here. See the `LICENSE` file if present in this repository.
