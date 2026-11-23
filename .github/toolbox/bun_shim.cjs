"use strict";
// bun_shim.cjs — minimal Bun API surface on Node, for the esbuild-bundled
// opencode CLI (built for Bun at upstream; the node bundle still references
// Bun.* lazily and dies with a swallowed ReferenceError at serve boot).
// Loaded via NODE_OPTIONS="--require <path>" or by the toolbox launcher
// BEFORE importing opencode.bundle.mjs.
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");
const { Readable } = require("node:stream");
const cp = require("node:child_process");
const Module = require("node:module");
const { fileURLToPath } = require("node:url");
const crypto = require("node:crypto");

function globToRegExp(pattern) {
  let re = "";
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === "*") {
      if (pattern[i + 1] === "*") {
        let j = i;
        while (pattern[j] === "*") j++;
        if (pattern[j] === "/") {
          re += "(?:[^/]*/)*";
          i = j;
        } else {
          re += ".*";
          i = j - 1;
        }
      } else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else if (c === "[") {
      let j = i + 1;
      const neg = pattern[j] === "!" || pattern[j] === "^";
      if (neg) j++;
      while (j < pattern.length && pattern[j] !== "]") j++;
      re += "[" + (neg ? "^" : "") + pattern.slice(i + 1 + (neg ? 1 : 0), j) + "]";
      i = j;
    } else if (c === "{") {
      let j = i + 1, depth = 1, seg = "";
      while (j < pattern.length && depth > 0) {
        if (pattern[j] === "{") depth++;
        if (pattern[j] === "}") { depth--; if (depth === 0) break; }
        seg += pattern[j]; j++;
      }
      const alts = seg.split(",").map((a) =>
        a.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]"));
      re += "(?:" + alts.join("|") + ")";
      i = j;
    } else if ("\\^$.|+()[]{}".includes(c)) re += "\\" + c;
    else re += c;
  }
  return new RegExp("^" + re + "$");
}

function walk(dir, dot, cb, base = "") {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    if (!dot && e.name.startsWith(".")) continue;
    const rel = base ? base + "/" + e.name : e.name;
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) { cb(rel, abs, true); walk(abs, dot, cb, rel); }
    else if (e.isFile() || e.isSymbolicLink()) cb(rel, abs, false);
  }
}

class BunGlob {
  constructor(pattern) {
    if (typeof pattern !== "string") throw new TypeError("Bun.Glob expects a pattern string.");
    this.pattern = pattern;
    this.re = globToRegExp(pattern);
  }
  match(p) { return this.re.test(String(p).replace(/\\/g, "/")); }
  scanSync(opts = {}) {
    const cwd = opts.cwd ? String(opts.cwd) : ".";
    const out = [];
    walk(cwd, opts.dot ?? false, (rel, abs, isDir) => {
      if (opts.onlyFiles && isDir) return;
      if (this.re.test(rel)) out.push(opts.absolute ? abs : rel);
    });
    return out[Symbol.iterator]();
  }
  async *scan(opts = {}) { yield* this.scanSync(opts); }
}

class BunFile {
  constructor(p) {
    this.path = typeof p === "string" ? p : fileURLToPath(p);
    this.name = path.basename(this.path);
  }
  get size() { try { return fs.statSync(this.path).size; } catch { return 0; } }
  get lastModified() { try { return fs.statSync(this.path).mtime; } catch { return new Date(0); } }
  get type() { return "application/octet-stream"; }
  async exists() { try { await fsp.access(this.path); return true; } catch { return false; } }
  async text() { return fs.readFileSync(this.path, "utf8"); }
  async json() { return JSON.parse(fs.readFileSync(this.path, "utf8")); }
  async arrayBuffer() { const b = fs.readFileSync(this.path); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength); }
  async bytes() { return new Uint8Array(fs.readFileSync(this.path)); }
  stream() { return Readable.toWeb(fs.createReadStream(this.path)); }
  async writer() { throw new Error("BunFile.writer() unsupported on the node shim"); }
}

const Bun = {
  version: "1.2.0-node-shim",
  env: process.env,
  cwd: () => process.cwd(),
  main: process.argv[1],
  argv: process.argv.slice(2),
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  file: (p) => new BunFile(p),
  async write(target, data) {
    let to;
    if (typeof target === "string") to = target;
    else if (target instanceof URL) to = fileURLToPath(target);
    else if (target && target.path) to = target.path;
    else throw new TypeError("Bun.write expects a path or a BunFile to write to.");
    let buf;
    if (typeof data === "string") buf = Buffer.from(data);
    else if (data instanceof Uint8Array) buf = Buffer.from(data);
    else if (data instanceof ArrayBuffer) buf = Buffer.from(new Uint8Array(data));
    else if (data instanceof BunFile) buf = fs.readFileSync(data.path);
    else if (data && typeof data.arrayBuffer === "function") buf = Buffer.from(new Uint8Array(await data.arrayBuffer()));
    else throw new TypeError("Bun.write shim: unsupported data type");
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.writeFileSync(to, buf);
    return buf.length;
  },
  stdin: {
    get stream() { return Readable.toWeb(process.stdin); },
  },
  which(cmd) {
    if (typeof cmd !== "string" || !cmd) return null;
    if (cmd.includes("/")) {
      try { fs.accessSync(cmd, fs.constants.X_OK); return path.resolve(cmd); } catch { return null; }
    }
    for (const d of (process.env.PATH || "").split(path.delimiter)) {
      if (!d) continue;
      const p = path.join(d, cmd);
      try {
        fs.accessSync(p, fs.constants.X_OK);
        if (fs.statSync(p).isFile()) return p;
      } catch {}
    }
    return null;
  },
  resolveSync(spec, from) {
    const base = path.join(String(from || process.cwd()), "index.js");
    try {
      return Module.createRequire(base).resolve(spec);
    } catch {
      // Bun.resolveSync throws when missing; the bundled plugin-runtime
      // discovery (effect/package.json etc.) runs at module scope against
      // the SOURCE tree layout. On the shipped payload those packages are
      // inlined in the bundle, so a missing file must resolve to a benign
      // virtual path instead of killing the import.
      return path.resolve(String(from || process.cwd()), String(spec));
    }
  },
  plugin(opts) { return opts; },
  Glob: BunGlob,
  hash(input, alg = "sha256") {
    const h = crypto.createHash(alg);
    h.update(typeof input === "string" ? Buffer.from(input) : Buffer.from(input));
    return h.digest("hex");
  },
  spawn(cmd, opts = {}) {
    return cp.spawn(String(cmd), [], opts);
  },
};

if (!("Bun" in globalThis)) {
  try {
    Object.defineProperty(globalThis, "Bun", {
      value: Bun, writable: true, configurable: true, enumerable: true,
    });
  } catch {
    globalThis.Bun = Bun;
  }
}
