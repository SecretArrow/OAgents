// OAgents compat — OpenAI-compatible adapter in front of the embedded
// opencode v2 server.
//
// The app UI speaks a small OpenAI-style contract (GET /health, GET /models,
// POST /chat/completions SSE with an optional `Authorization: Bearer` — see
// lib/services/opencode_client.dart). opencode v2's own server speaks its
// /api/* protocol with HTTP Basic auth (`opencode:<password>`). This adapter
// bridges the two with zero dependencies:
//
//   GET  /health             -> 200 {"ok":true,"upstream":bool} — always
//                               200 once the ADAPTER is up; `upstream`
//                               reports the opencode server separately so
//                               boot-window polls never see a 503 (v1.0.8)
//   GET  /models             -> opencode GET /api/model, mapped to OpenAI list
//   POST /chat/completions   -> opencode /api/session[/prompt] + /api/event
//                               SSE -> OpenAI chunk stream.
//                               v1.0.8: body.sessionID reuses (and returns)
//                               one persistent opencode session per app chat
//                               — matching the CLI, where sessions survive
//                               across prompts. body.model switches that
//                               session's model first (the CLI's /model
//                               command) and modelID echoes back in chunks.
//                               No sessionID = legacy one-shot session,
//                               deleted after the turn (old behavior).
//   POST /v1/chat/completions (same handler)
//   ANY  /api/*               -> proxied VERBATIM to the upstream opencode
//                               server (the Dart setup UI talks opencode's
//                               own protocol — /api/credential, /api/model,
//                               /api/session, /api/provider — directly
//                               through this port)
//   GET  /openapi.json        -> same passthrough (diagnostics only)
//
// Env:
//   PORT       listening port for the app (default 4096 — bridge/UI expect it)
//   OCODE_UP   upstream opencode server base URL (default http://127.0.0.1:4097)
//   OCODE_PASS opencode server password (Basic auth user "opencode")
//
// The Dart client's Bearer token is accepted and ignored: the adapter talks
// to a loopback-only server spawned by the app itself.
import http from "node:http"
import { randomUUID } from "node:crypto"

const PORT = Number(process.env.PORT || 4096)
const UP = (process.env.OCODE_UP || "http://127.0.0.1:4097").replace(/\/+$/, "")
const PASS = process.env.OCODE_PASS || ""
const UP_AUTH = "Basic " + Buffer.from("opencode:" + PASS).toString("base64")
// Without a configured provider the agent retries forever (session.retry.
// scheduled, never idle) — the watchdog ends the SSE stream with a clear
// error instead of hanging the chat UI. Configurable for CI smokes.
const IDLE_TIMEOUT = Number(process.env.OCODE_IDLE_TIMEOUT || 90_000)
// Cached upstream liveness for /health: refreshed at most every 2s so a
// health poll storm (bridge + Dart + setup screen) cannot serialize the
// event loop behind back-to-back upstream fetches (v1.0.8).
const UP_PROBE_INTERVAL = 2_000
let upCache = { ok: false, at: 0 }
let upProbeInflight = null

function log(...a) {
  console.log(new Date().toISOString().slice(11, 19), "[compat]", ...a)
}

/** Upstream fetch with Basic auth; returns the raw Response. */
function up(path, init = {}) {
  const headers = { authorization: UP_AUTH, ...(init.headers || {}) }
  if (init.body && !headers["content-type"]) headers["content-type"] = "application/json"
  return fetch(UP + path, { ...init, headers })
}

async function readJson(res) {
  const text = await res.text()
  try { return JSON.parse(text) } catch { return { raw: text } }
}

function sseWrite(res, obj) {
  res.write(`data: ${JSON.stringify(obj)}\n\n`)
}

function chunk(id, delta, finish = null, model = null) {
  return {
    id,
    object: "chat.completion.chunk",
    created: Math.floor(Date.now() / 1000),
    model: model || "opencode",
    choices: [{ index: 0, delta, finish_reason: finish }],
  }
}

function sseError(res, id, message) {
  sseWrite(res, chunk(id, { role: "assistant" }))
  sseWrite(res, chunk(id, { content: message }))
  sseWrite(res, chunk(id, {}, "stop"))
  res.write("data: [DONE]\n\n")
  res.end()
}

// ---------------------------------------------------------------------------
// GET /models
// ---------------------------------------------------------------------------
async function listModels(res) {
  try {
    const r = await up("/api/model")
    const body = await readJson(r)
    const rows = Array.isArray(body?.data) ? body.data : []
    const data = rows.map((m) => ({
      id: `${m.providerID ?? m.provider_id ?? "opencode"}/${m.id ?? m.modelID ?? m.model_id ?? "model"}`,
      object: "model",
      owned_by: m.providerID ?? m.provider_id ?? "opencode",
    }))
    res.writeHead(200, { "content-type": "application/json" })
    res.end(JSON.stringify({ object: "list", data }))
  } catch (e) {
    res.writeHead(502, { "content-type": "application/json" })
    res.end(JSON.stringify({ error: { message: `upstream /api/model failed: ${e?.message ?? e}` } }))
  }
}

// ---------------------------------------------------------------------------
// POST /chat/completions — session -> prompt -> /api/event SSE -> chunks
// ---------------------------------------------------------------------------
async function chat(req, res, body) {
  const id = "chatcmpl-" + randomUUID().slice(0, 8)
  const stream = body?.stream !== false
  const text = typeof body?.messages?.at?.(-1)?.content === "string"
    ? body.messages.at(-1).content
    : (body?.messages || []).map((m) => (typeof m.content === "string" ? m.content : "")).join("\n")
  if (!text.trim()) {
    return sseError(res, id, "empty prompt — messages[].content required")
  }
  // v1.0.8 session pinning: body.sessionID = the app chat's opencode
  // session (stable across turns, like the CLI); body.model = "provider/id"
  // switches that session's model first (the CLI's /model command).
  const sessionID = typeof body?.sessionID === "string" && body.sessionID.trim() ? body.sessionID.trim() : null
  const model = typeof body?.model === "string" && body.model.trim() ? body.model.trim() : null
  if (!stream) {
    // Non-stream path: same pipeline, buffer until done, then reply once.
    const parts = []
    let err = null
    try {
      for await (const piece of runPrompt(text, { sessionID, model })) {
        if (piece.error) err = piece.error
        else if (piece.text) parts.push(piece.text)
      }
    } catch (e) {
      err = e?.message ?? String(e)
    }
    res.writeHead(200, { "content-type": "application/json" })
    if (err && parts.length === 0) {
      res.end(JSON.stringify({ error: { message: err } }))
      return
    }
    res.end(JSON.stringify({
      id,
      object: "chat.completion",
      created: Math.floor(Date.now() / 1000),
      model: model || "opencode",
      choices: [{ index: 0, message: { role: "assistant", content: parts.join("") }, finish_reason: "stop" }],
    }))
    return
  }

  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
    connection: "keep-alive",
  })
  sseWrite(res, chunk(id, { role: "assistant" }, null, model))
  let done = false
  const finish = () => {
    if (done) return
    done = true
    sseWrite(res, chunk(id, {}, "stop", model))
    res.write("data: [DONE]\n\n")
    res.end()
  }
  req.on("close", () => { done = true })
  try {
    for await (const piece of runPrompt(text, { sessionID, model })) {
      if (done) break
      if (piece.error) {
        sseWrite(res, chunk(id, { content: `\n\n[error] ${piece.error}` }, null, model))
      } else if (piece.text) {
        sseWrite(res, chunk(id, { content: piece.text }, null, model))
      } else if (piece.sessionID) {
        // First emission of a pinned run: tells the app which opencode
        // session backs this chat (a newly created one when the app had
        // none yet). Delivered as a chunk with model info so the standard
        // OpenAI parser can carry it; the app reads `sessionID` off the
        // delta object.
        sseWrite(res, chunk(id, { role: "assistant", sessionID: piece.sessionID, model: model || "" }, null, model))
      }
    }
  } catch (e) {
    if (!done) sseWrite(res, chunk(id, { content: `\n\n[error] ${e?.message ?? e}` }, null, model))
  }
  finish()
}

// ---------------------------------------------------------------------------
// Generic /api/* passthrough — the Dart setup UI speaks opencode's own
// protocol (credentials, models, providers) directly against this port, so
// the adapter forwards those requests VERBATIM instead of re-modeling them
// (a hand-rolled mapping would drift from the /api/* schema the upstream
// bundle actually serves). /openapi.json rides along for diagnostics.
// ---------------------------------------------------------------------------
async function proxy(req, res, path, query) {
  // Collect the client's body first: fetch needs the full payload up front
  // (no streaming upload), and the body is required to size content-type.
  const chunks = []
  for await (const c of req) chunks.push(c)
  const body = Buffer.concat(chunks)
  const headers = {
    authorization: UP_AUTH, // upstream only accepts the Basic pair
    "content-type": req.headers["content-type"] || (body.length ? "application/json" : undefined),
    accept: req.headers.accept || "*/*",
  }
  try {
    const r = await fetch(UP + path + query, {
      method: req.method,
      headers,
      body: body.length ? body : undefined,
      redirect: "manual", // 3xx must reach the client as-is, not be followed
    })
    // Stream the upstream body through verbatim: status code and
    // content-type are preserved, everything else stays untouched.
    res.writeHead(r.status, { "content-type": r.headers.get("content-type") || "application/octet-stream" })
    if (r.body) for await (const c of r.body) res.write(c)
    res.end()
  } catch (e) {
    // ECONNREFUSED while the app is still booting the opencode server —
    // surface a clean 503 so the UI can retry instead of parsing a hang.
    log(`proxy ${req.method} ${path} upstream unreachable: ${e?.cause?.code ?? e?.message ?? e}`)
    res.writeHead(503, { "content-type": "application/json" })
    res.end(JSON.stringify({ error: { message: "opencode server not reachable" } }))
  }
}

/**
 * Drives one opencode round. v1.0.8 session semantics (mirrors the CLI):
 *
 *  - opts.sessionID set  -> REUSE that opencode session (created earlier by
 *    this chat). The session survives the turn — the app's chat list and
 *    the CLI's session list see the same history. The caller learns the
 *    id through the first {sessionID} yield when it did not have one yet.
 *  - opts.sessionID null -> legacy one-shot session, deleted afterwards
 *    (pre-v1.0.8 behavior).
 *  - opts.model set      -> `POST /api/session/{id}/model` BEFORE the
 *    prompt (the CLI's /model command); "provider/id" is split into
 *    {providerID, id}. Cleared per session, not global.
 *
 * Yields {sessionID} once, then {text} pieces and a final {error?}.
 */
async function* runPrompt(text, opts = {}) {
  let sessionID = opts.sessionID || null
  const model = opts.model || null
  const keep = !!sessionID

  if (!sessionID) {
    const sr = await up("/api/session", { method: "POST", body: JSON.stringify({}) })
    if (!sr.ok) {
      yield { error: `opencode session create failed (${sr.status}): ${(await sr.text()).slice(0, 300)}` }
      return
    }
    const sbody = await readJson(sr)
    sessionID = sbody?.data?.id
    if (!sessionID) {
      yield { error: `opencode session response missing id: ${JSON.stringify(sbody).slice(0, 200)}` }
      return
    }
  }
  // Tell the caller which session backs this chat (newly minted ids in
  // particular — the app persists it on the chat and reuses it next turn).
  if (keep || opts.sessionID == null) yield { sessionID }

  // Per-session model switch (CLI /model). "provider/id" → Model.Ref.
  if (model && model.includes("/")) {
    const sep = model.indexOf("/")
    const mr = await up(`/api/session/${sessionID}/model`, {
      method: "POST",
      body: JSON.stringify({ model: { providerID: model.slice(0, sep), id: model.slice(sep + 1) } }),
    })
    if (!mr.ok) {
      // A bad/unknown model id must not kill the turn — opencode keeps the
      // session's previous model. Surface the reason; the app shows it.
      yield { error: `model switch to ${model} failed (${mr.status}): ${(await mr.text()).slice(0, 200)}` }
    }
  }

  // Subscribe FIRST so no event is lost between prompt and listener.
  const ev = await up("/api/event", { headers: { accept: "text/event-stream" } })
  if (!ev.ok || !ev.body) {
    yield { error: `opencode event bus failed (${ev.status})` }
    return
  }

  const pr = await up(`/api/session/${sessionID}/prompt`, {
    method: "POST",
    body: JSON.stringify({ text, id: null }),
  })
  if (!pr.ok) {
    yield { error: `opencode prompt failed (${pr.status}): ${(await pr.text()).slice(0, 300)}` }
    if (!keep) {
      try { await up(`/api/session/${sessionID}`, { method: "DELETE" }) } catch {}
    }
    return
  }

  // Decode the SSE frames: {event, data:{type, properties...}}.
  // Watchdog semantics: with no provider configured the agent emits
  // retry/transport frames forever without ever producing TEXT, so the
  // deadline counts from the prompt until the FIRST text piece (and then
  // between text pieces at 10x, guarding against a silently dead stream).
  const parts = new Map() // partID -> accumulated text
  const reader = ev.body.getReader()
  const dec = new TextDecoder()
  let buf = ""
  let idle = false
  const firstTextDeadline = Date.now() + IDLE_TIMEOUT
  let softDeadline = 0
  let gotText = false
  try {
    while (!idle) {
      const now = Date.now()
      const deadline = gotText ? softDeadline : firstTextDeadline
      if (now >= deadline) {
        yield { error: gotText
          ? `opencode stream stalled for ${Math.round((IDLE_TIMEOUT * 10) / 1000)}s`
          : `opencode produced no output within ${Math.round(IDLE_TIMEOUT / 1000)}s — configure a provider (API key) in the app's opencode setup screen` }
        idle = true
        break
      }
      const tick = reader.read()
      const result = await Promise.race([
        tick,
        new Promise((r) => setTimeout(() => r({ timeout: true }), deadline - now)),
      ])
      if (result.timeout) continue
      const { value, done } = result
      if (done) break
      buf += dec.decode(value, { stream: true })
      let idx
      while ((idx = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, idx).trim()
        buf = buf.slice(idx + 1)
        if (!line.startsWith("data:")) continue
        let frame
        try { frame = JSON.parse(line.slice(5).trim()) } catch { continue }
        const type = frame?.data?.type ?? frame?.event
        const d = frame?.data ?? {}
        if (type === "message.part.updated") {
          const part = d.part ?? {}
          if (part.type === "text" && d.sessionID === sessionID) {
            const pid = part.id ?? `${d.messageID}-0`
            const full = part.text ?? ""
            const prev = parts.get(pid) ?? ""
            if (full.length > prev.length) {
              const piece = full.slice(prev.length)
              parts.set(pid, full)
              gotText = true
              softDeadline = Date.now() + IDLE_TIMEOUT * 10
              yield { text: piece }
            }
          }
        } else if (type === "session.error" && d.sessionID === sessionID) {
          const msg = d.error?.message ?? d.error?.name ?? "session error"
          yield { error: String(msg) }
          idle = true
        } else if ((type === "session.idle" || type === "session.execution.failed" || type === "session.execution.interrupted") && (d.sessionID === sessionID || d.id === sessionID)) {
          idle = true
        }
      }
    }
  } finally {
    try { await reader.cancel() } catch {}
    // One-shot (legacy) runs delete their session so no orphan history
    // piles up on the server; pinned runs keep theirs — that history IS
    // the app chat's opencode-side memory (the CLI sees it too).
    if (!keep) {
      try { await up(`/api/session/${sessionID}`, { method: "DELETE" }) } catch {}
    }
  }
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = (req.url || "/").split("?")[0]
  if (req.method === "GET" && (url === "/health" || url === "/")) {
    // v1.0.8: the adapter itself is up -> 200, with `upstream` reported
    // separately. The old handler returned 503 while opencode was still
    // booting, so every readiness poll during the boot window saw a
    // "failed" server; worse, its synchronous 1.5s upstream fetch ran on
    // the single event loop, serializing /models and /chat behind it.
    // `upstream` is cached for UP_PROBE_INTERVAL and shared across
    // concurrent health polls. Consumers that need "ready to chat" check
    // `upstream === true` (the Dart client reads the JSON body).
    const now = Date.now()
    if (now - upCache.at > UP_PROBE_INTERVAL) {
      if (!upProbeInflight) {
        upProbeInflight = (async () => {
          try {
            const r = await fetch(UP + "/api/info", {
              headers: { authorization: UP_AUTH },
              signal: AbortSignal.timeout(1500),
            })
            upCache = { ok: r.status < 500, at: Date.now() }
          } catch {
            upCache = { ok: false, at: Date.now() }
          } finally {
            upProbeInflight = null
          }
        })()
      }
      await upProbeInflight
    }
    res.writeHead(200, { "content-type": "application/json" })
    res.end(JSON.stringify({ ok: true, adapter: "oagents-compat", upstream: upCache.ok }))
    return
  }
  if (req.method === "GET" && (url === "/models" || url === "/v1/models")) {
    return listModels(res)
  }
  if (req.method === "POST" && (url === "/chat/completions" || url === "/v1/chat/completions")) {
    let body = ""
    for await (const c of req) body += c
    let parsed = {}
    try { parsed = JSON.parse(body) } catch {}
    return chat(req, res, parsed)
  }
  // Opencode-protocol passthrough. Exact-path routes above stay matched
  // FIRST (the OpenAI surface wins over the raw /api surface), then any
  // remaining /api/* route — and /openapi.json for diagnostics — is
  // forwarded verbatim. Anything else falls through to the 404 below.
  if (url.startsWith("/api/") || (req.method === "GET" && url === "/openapi.json")) {
    const raw = req.url || "/"
    const q = raw.includes("?") ? raw.slice(raw.indexOf("?")) : ""
    return proxy(req, res, url, q)
  }
  res.writeHead(404, { "content-type": "application/json" })
  res.end(JSON.stringify({ error: { message: `no route ${req.method} ${url}` } }))
})

server.listen(PORT, "127.0.0.1", () => {
  log(`listening on http://127.0.0.1:${PORT} -> ${UP}`)
})
