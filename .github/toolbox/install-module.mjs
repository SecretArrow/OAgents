#!/usr/bin/env node
// OAgents toolbox — dynamic module installer.
//
// Lets the opencode agent add a Node module on demand at runtime, without
// rebuilding the toolbox. Runs inside the opencode process: the Kotlin
// bridge already sets PATH (toolbox/bin first), NODE_PATH
// (toolbox/lib/node_modules), npm_config_prefix (toolbox root),
// npm_config_cache + npm_config_tmp (writable cache dir), and TMPDIR.
//
// Usage:
//   node lib/install-module.mjs <pkg-spec> [--no-verify]
//
//   <pkg-spec>   anything npm accepts: "is-odd", "is-odd@3.0.1",
//                "@scope/pkg", a tarball URL, or a github:user/repo spec.
//   --no-verify  skip the post-install require() probe (use this for
//                packages that have no main entry or are CLI-only).
//
// Output: a single JSON line on stdout:
//   {"ok":true,"spec":"is-odd","name":"is-odd","version":"3.0.1",
//    "path":".../node_modules/is-odd","main":"./index.js"}
//   {"ok":false,"spec":"...","error":"...","npmLog":"..."}
//
// The install target is the toolbox's global prefix (npm_config_prefix),
// so the new package lands in lib/node_modules — exactly where NODE_PATH
// points — and a subsequent `require('<name>')` from any opencode tool
// resolves it. Pure-JS packages work on every ABI; native-addon packages
// are rejected up front with a clear message (no toolchain on-device).

import { spawn } from "node:child_process"
import { createRequire } from "node:module"
import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
// toolbox layout: bin/npm is a sibling of lib/ (this file lives in lib/).
const npmBin = join(here, "..", "bin", "npm")
const nodeModulesDir = join(here, "node_modules")

function parseArgs(argv) {
  const rest = []
  let verify = true
  for (const a of argv) {
    if (a === "--no-verify") verify = false
    else if (a === "--verify") verify = true
    else if (!a.startsWith("--")) rest.push(a)
  }
  return { spec: rest[0], verify }
}

function pkgNameFromSpec(spec) {
  // Scoped: @scope/name[@version]   -> @scope/name
  // Plain : name[@version]          -> name
  // Tarball/github:spec/url         -> null (can't infer)
  if (!spec) return null
  if (spec.startsWith("http") || spec.startsWith("file:") || spec.includes(":")) return null
  if (spec.startsWith("@")) {
    const m = spec.match(/^(@[^/]+\/[^@/]+)(?:@.*)?$/)
    return m ? m[1] : null
  }
  const m = spec.match(/^([^@/]+)(?:@.*)?$/)
  return m ? m[1] : null
}

function hasNativeAddon(pkgDir) {
  const pkgJson = join(pkgDir, "package.json")
  if (!existsSync(pkgJson)) return false
  let pkg
  try {
    pkg = JSON.parse(readFileSyncSafe(pkgJson))
  } catch {
    return false
  }
  // .node binaries or gypfile => needs a toolchain we don't have on-device.
  if (pkg.gypfile === true || pkg.binary?.napi_versions === undefined && pkg.binary) return true
  const hasBinding = existsSync(join(pkgDir, "binding.gyp")) ||
    existsSync(join(pkgDir, "build"))
  const depsNative = Object.keys(pkg.dependencies || {}).some((d) =>
    /(node-gyp|nan|@mapbox\/node-pre-gyp|prebuild)/.test(d),
  )
  return hasBinding || depsNative
}

import { readFileSync } from "node:fs"
function readFileSyncSafe(p) {
  return readFileSync(p, "utf8")
}

function runNpm(args) {
  return new Promise((resolve) => {
    const child = spawn(npmBin, args, {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (d) => (stdout += d.toString()))
    child.stderr.on("data", (d) => (stderr += d.toString()))
    child.on("error", (e) => resolve({ code: -1, stdout, stderr, err: e.message }))
    child.on("close", (code) => resolve({ code, stdout, stderr }))
  })
}

async function main() {
  const { spec, verify } = parseArgs(process.argv.slice(2))
  if (!spec) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        error: "missing package spec — usage: node lib/install-module.mjs <pkg-spec>",
      }) + "\n",
    )
    process.exit(2)
  }
  if (!existsSync(npmBin)) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        spec,
        error: `npm shim not found at ${npmBin} — the toolbox layout is wrong`,
      }) + "\n",
    )
    process.exit(1)
  }

  const res = await runNpm(["install", "--global", "--no-fund", "--no-audit", spec])
  if (res.code !== 0) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        spec,
        // Include the spawn error message (res.err) — a bare "exited -1"
        // with an empty log made a spawn failure (missing/non-executable
        // shim, ENOEXEC) undiagnosable. Found by the sandbox tar test.
        error: `npm install exited ${res.code}${res.err ? `: ${res.err}` : ""}`,
        npmLog: res.stderr.slice(-4000),
      }) + "\n",
    )
    process.exit(1)
  }

  const name = pkgNameFromSpec(spec)
  if (!name) {
    process.stdout.write(
      JSON.stringify({
        ok: true,
        spec,
        name: null,
        note: "installed; name inference unsupported for this spec — set --no-verify off only if you know the import name",
        npmStdout: res.stdout.slice(-1000),
      }) + "\n",
    )
    return
  }

  const pkgDir = join(nodeModulesDir, name)
  if (!existsSync(pkgDir)) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        spec,
        name,
        error: `npm reported success but ${pkgDir} does not exist`,
        npmLog: res.stdout.slice(-2000),
      }) + "\n",
    )
    process.exit(1)
  }

  if (hasNativeAddon(pkgDir)) {
    process.stdout.write(
      JSON.stringify({
        ok: false,
        spec,
        name,
        error:
          "package ships a native addon (.node / node-gyp) — the on-device Node has no compiler and the registry's prebuilt binaries are glibc, so it cannot load. Use the pure-JS variant (e.g. @noble/* instead of secp256k1).",
      }) + "\n",
    )
    // Uninstall the broken package so a retry with the right variant is clean.
    await runNpm(["uninstall", "--global", name])
    process.exit(1)
  }

  let version = null
  let main = null
  try {
    const pkg = JSON.parse(readFileSyncSafe(join(pkgDir, "package.json")))
    version = pkg.version ?? null
    main = pkg.main ?? pkg.module ?? null
  } catch {}

  if (verify) {
    try {
      const req = createRequire(import.meta.url)
      // Resolve (not execute) — some packages have side effects.
      const resolved = req.resolve(name)
      process.stdout.write(
        JSON.stringify({
          ok: true,
          spec,
          name,
          version,
          path: pkgDir,
          main,
          resolved,
        }) + "\n",
      )
      return
    } catch (e) {
      process.stdout.write(
        JSON.stringify({
          ok: false,
          spec,
          name,
          version,
          error: `installed but require('${name}') failed: ${e.message}`,
        }) + "\n",
      )
      process.exit(1)
    }
  }

  process.stdout.write(
    JSON.stringify({ ok: true, spec, name, version, path: pkgDir, main }) + "\n",
  )
}

main().catch((e) => {
  process.stdout.write(JSON.stringify({ ok: false, error: e?.message ?? String(e) }) + "\n")
  process.exit(1)
})
