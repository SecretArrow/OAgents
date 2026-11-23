# Provider keys

How to add the API keys the embedded opencode runtime uses to reach its
model providers — in the app, no terminal involved.

Since v1.0.4 the embedded opencode boots on-device (serve mode plus an
OpenAI-compatible adapter on `http://127.0.0.1:4096`), and chat works once
a provider API key is added. Keys are managed from the opencode setup
screen: **Settings → opencode → Provider keys**.

## Which providers

| Provider | Where to get a key |
|---|---|
| OpenAI | the OpenAI console (openai.com) |
| Anthropic | the Anthropic console (anthropic.com) |
| Google | Google AI Studio |
| OpenRouter | the OpenRouter console (openrouter.ai) |
| Ollama | no key needed — a locally running Ollama |
| LM Studio | no key needed — a locally running LM Studio |

Ollama and LM Studio are local runtimes; when they run on the same device
(or reachably on the network for OpenRouter-style endpoints), no key is
needed for them at all.

## Where keys live

The app stores nothing. A key you add under **Provider keys** is handed to
the embedded opencode runtime and written to opencode's own local
database inside the app's private storage — the same place opencode keeps
its auth on any machine. OAgents' settings hold no keys, and the app never
sends them anywhere other than the provider's own API.

Uninstalling the app removes the private storage and the keys with it.

## Active-key semantics

Each provider has exactly one **active** key. Adding a key for a provider
that already has one replaces the active key for that provider; deleting a
key removes it, and the provider falls back to "no key" until a new one is
added. Adding keys for several providers is fine — they are independent,
one active key each.

## Troubleshooting

- **Chat shows an error** right after sending: the most common cause is a
  wrong or rejected key. Check the key in the provider's console (copy it
  fresh, mind trailing whitespace), then delete the key under Provider
  keys and re-add it.
- **The Model picker is empty**: no models are advertised until a working
  key is in place. Add a provider API key, then tap **Refresh models**.
- **Key works but nothing streams**: confirm the runtime is `running` on
  the setup screen (Start it if not) — chat is gated on that state.
- **Key was pasted into a chat by accident**: treat it as compromised and
  revoke it at the provider immediately (see
  [`../SECURITY.md`](../SECURITY.md)).
