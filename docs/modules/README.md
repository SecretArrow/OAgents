# Module Documentation

Official documentation for **OAgents chat modules** (plugins) — JavaScript
packages that run natively inside a chat session, isolated per chat like a
browser private window.

| Document | Language | Contents |
|---|---|---|
| [`sdk-reference-en.md`](sdk-reference-en.md) | English | Package layout, manifest, installation, full `oagents` API reference, isolation model, examples |
| [`sdk-reference-id.md`](sdk-reference-id.md) | Bahasa Indonesia | Same reference in Indonesian |

Both references ship **inside the app** as well: *Settings → Modules →
SDK docs* (language follows the app language: en / id / es).

## What a module is

A module is a ZIP with a `module.json` manifest and a `main.js` entry
point. The user installs it from the Modules screen, then activates it in
a chat (via `/plugins`, a chip on the new-chat screen, or a slash
command the module declares). Each activation boots a fresh JS context
sandboxed to that chat: its own `state/` directory, its own key/value
store, its own permission consents. Different chats never share module
state.

## The `oagents` SDK surface

A module talks to the host through the global `oagents` object (also
available as `const oagents = require('oagents-sdk')`). The shim is
`sdk/oagents-sdk.js`, shipped as a Flutter asset and injected before the
module's entry point runs. The namespaces:

- `oagents.info` — metadata: `name`, `version`, `sessionId`, `userAgent`,
  `setup`, and `prompt` (when triggered by a staged module's first
  message).
- `oagents.log(...)` — always available; captured into the module message.
- `oagents.storage` — per-chat key/value store (permission `storage`).
- `oagents.fs` — sandboxed file I/O under the module's per-chat `state/`
  directory (permission `files`).
- `oagents.http` — HTTP through the app, host-restricted by
  `allowedHosts` (permission `network`).
- `oagents.chat` — progressive output into the conversation
  (permission `chat`).
- `oagents.device` — shell + airplane-mode probe/cycle for rooted phones
  (permission `device`).
- `oagents.agent` — `compose` and `polish`, the two text-generation
  entry points (permission `agent`).

## Reaching the LLM: `oagents.agent` → opencode

Since OAgents has exactly one AI backend, modules no longer pick a
provider. `oagents.agent.compose` and `oagents.agent.polish` route through
the **same opencode server** the chat itself uses, via the host's
`agent.compose` / `agent.polish` pipeline. The model is the one the user
picked in Settings → opencode for that chat; there is no `oagents.agent`
knob for choosing a different provider. Failures (opencode server
unreachable, repeated composer-contract violations) throw, so wrap the
call in try/catch and skip the text action when generation is not
possible.

See the full reference below for every field, cap, and example.

## Building a module from chat

Type **`/make_plugins <description>`** (aliases `/make_plugin`,
`/make_module`) in any running chat. The agent scaffolds the folder,
packs a valid zip and stages it behind a confirmation card — you decide
whether to install. Session data (uploads, files, earlier messages) is
baked into the module when your description asks for it.

## Quick manifest checklist

- [ ] `name` — lowercase `[a-z0-9._-]`, max 40 chars (also the install
      directory name)
- [ ] `entry` — JavaScript entry point present in the ZIP (default
      `main.js`)
- [ ] `permissions` — request the minimum set the module needs
- [ ] `allowedHosts` — declare when the module talks to the network
- [ ] `timeoutSeconds` — raise only when the workload needs it (max 120)
