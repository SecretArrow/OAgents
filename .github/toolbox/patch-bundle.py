#!/usr/bin/env python3
"""Patch the esbuild node bundle of opencode for on-device Node runtime.

Upstream opencode targets Bun. The bundle we ship runs on the toolbox's
Node (Termux bionic build), where several Bun-isms break boot:

1. `import.meta.dir` / `import.meta.dirname` — Bun-only; undefined on Node.
   Replaced with a banner var derived from import.meta.url (same value).
2. `Bun.*` calls (sleep/file/stdin/write/Glob/which/resolveSync/plugin) —
   ReferenceError on Node, swallowed by Effect -> silent serve hang. Handled
   by bun_shim.cjs loaded BEFORE the bundle (staged as lib/bun_shim.cjs and
   required by the launcher).
3. Self-awaits — `await init_X()` inside init_X's own __esm body deadlock
   under the async memoization on Node (51 sites). Removed: they are no-ops
   semantically (the init is already running).
4. `import("virtual:opencode-app-assets")` — a build-time virtual module
   that does not exist in the payload; without OPENCODE_LOCAL + app/dist the
   web-ui load FAILS the whole serve boot. The Android app ships its own UI,
   so load4 returns empty files (API-only server; web UI 404s).
5. Plugin runtime discovery (effect / @opencode/plugin) resolves packages
   that only exist in the source tree; two stub modules are staged so the
   discovery finds benign empty modules instead of crashing the import.

Run AFTER esbuild, BEFORE tar:  python3 patch-bundle.py <bundle.mjs> <libdir>
Prints PATCH OK <counts> and exits non-zero on any unexpected state.
"""
import re
import sys
from pathlib import Path


def main() -> int:
    bundle = Path(sys.argv[1])
    libdir = Path(sys.argv[2])
    s = bundle.read_text(encoding="utf-8", errors="replace")

    # 1. import.meta.dir / .dirname -> banner var (same value as Bun's)
    n_dir = s.count("import.meta.dir")
    banner = 'const __oc_dir = new URL(".", import.meta.url).pathname;\n'
    s = s.replace("import.meta.dir", "__oc_dir")
    lines = s.split("\n")
    if lines[0].startswith("#!"):
        lines.insert(1, banner.strip())
        s = "\n".join(lines)
    else:
        s = banner + s

    # 3. self-awaits inside their own __esm body
    out, pos, removed = [], 0, 0
    for m in re.finditer(r'await (init_[A-Za-z0-9_]+)\(\);', s):
        name = m.group(1)
        window = s[max(0, m.start() - 30000):m.start()]
        defs = re.findall(r'init_[A-Za-z0-9_]+ = __esm', window)
        if defs and defs[-1] == f"{name} = __esm":
            out.append(s[pos:m.start()])
            out.append(";")
            pos = m.end()
            removed += 1
    out.append(s[pos:])
    s = "".join(out)

    # 4. web-ui assets: the app brings its own UI; never fail serve boot
    n_assets = s.count('return { files: yield* sourceAssets(), brotli: void 0 };')
    s = s.replace('return { files: yield* sourceAssets(), brotli: void 0 };',
                  'return { files: {}, brotli: void 0 };')

    bundle.write_text(s, encoding="utf-8")

    # 5. stub modules for plugin-runtime discovery
    stubs = 0
    for name in ("effect", "@opencode/plugin"):
        pdir = libdir / "node_modules" / name
        pdir.mkdir(parents=True, exist_ok=True)
        (pdir / "package.json").write_text(
            f'{{"name":"{name}","version":"0.0.0-stub","main":"index.js","type":"commonjs"}}\n',
            encoding="utf-8")
        (pdir / "index.js").write_text("module.exports = {};\n", encoding="utf-8")
        stubs += 1

    if n_dir < 2 or removed < 10 or n_assets != 1:
        print(f"PATCH UNEXPECTED: dir={n_dir} selfawait={removed} assets={n_assets}")
        return 1
    print(f"PATCH OK dir={n_dir} selfawait={removed} assets={n_assets} stubs={stubs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
