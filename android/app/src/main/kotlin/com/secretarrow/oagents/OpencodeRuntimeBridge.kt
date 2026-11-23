/*
 * OpencodeRuntimeBridge.kt — Dart ⇄ Kotlin bridge for the EMBEDDED
 * Node toolbox that powers OAgents on-device.
 *
 * OAgents does NOT talk to a remote opencode server. The whole Node.js
 * toolbox is shipped INSIDE the APK and launched on-device by this bridge:
 *
 *   toolbox/
 *     bin/
 *       node-<abi>            per-ABI Node.js binary built for Android
 *                            (Termux — linked against Bionic libc), with
 *                            its companion .so libs under lib/. Exec'd
 *                            directly from filesDir (exec-able on every
 *                            Android version). NOT libnode.so — that is a
 *                            shared library and cannot be exec'd.
 *       agent-browser-<abi>  per-ABI Rust musl-static agent-browser CLI
 *                            (optional; JS fallback otherwise).
 *       npm, npx             CLI shims (ship with node under lib/node_modules/npm).
 *     lib/
 *       node_modules/        pre-installed packages the agent + chat
 *                            modules can `require()`:
 *                              opencode (bundle), agent-browser,
 *                              playwright-core (API only — browser work
 *                              goes through the app's embedded WebView,
 *                              not Playwright's Chromium, which is
 *                              glibc-only and not shipped),
 *                              crypto: ethers, web3, @solana/web3.js,
 *                                bitcoinjs-lib, @noble/secp256k1,
 *                                @noble/ed25519, @noble/hashes, bip39,
 *                                bip32, hdkey, crypto-js, bs58, viem,
 *                              dev: typescript, esbuild, tsx, prettier,
 *                                vitest, zx, commander, chalk, dotenv,
 *                                axios, lodash, zod, date-fns, p-map.
 *       opencode.bundle.js   opencode source bundled into one Node file.
 *       package.json         opencode's package.json (for the require graph).
 *     modules.json           manifest of bundled packages + versions
 *                            (read by lib/services/toolbox_manifest.dart).
 *     version.txt            toolbox revision (opencode-<sha>+toolbox-<sha>).
 *
 * The CI (.github/workflows/bundle-opencode.yml) produces `toolbox.tar.gz`
 * (the whole toolbox tree, ABI-independent) + per-ABI `node-<abi>` and
 * `agent-browser-<abi>` binaries, all staged under android/app/src/main/
 * assets/toolbox/ at release build time (gitignored, never committed).
 *
 * At start(), the bridge:
 *   1. extracts toolbox.tar.gz → filesDir/toolbox/ (idempotent on revision),
 *   2. selects the node binary for the device ABI (bin/node-<abi> — a real
 *      Termux-built executable; libnode.so is NOT used because it is a
 *      shared library and cannot be exec'd),
 *   3. selects agent-browser (bin/agent-browser-<abi> if present + executable,
 *      else the JS shim bin/agent-browser-js),
 *   4. chmods the picked binaries +x,
 *   5. spawns `node opencode.bundle.js serve --port 4096` with
 *      PATH=toolbox/bin:$PATH, LD_LIBRARY_PATH=toolbox/lib/<abi> (so the
 *      Termux node binary resolves its companion .so libs),
 *      NODE_PATH=toolbox/lib/node_modules, npm_config_prefix=toolbox,
 *      HOME=filesDir — so opencode can `require('ethers')`, shell out to
 *      `agent-browser`, run `npx`, etc.,
 *   6. polls http://127.0.0.1:4096/health until it answers.
 *
 * Every method is defensive: nothing throws across the channel. If the
 * toolbox is missing or the node binary for this ABI is absent, the bridge
 * reports state=failed with an actionable message — the app still opens
 * and Settings → opencode shows the failure.
 */
package com.secretarrow.oagents

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.GZIPInputStream
import kotlin.concurrent.thread

class OpencodeRuntimeBridge(private val context: Context) {

    companion object {
        private const val METHOD = "com.secretarrow.oagents/opencode"
        private const val EVENTS = "com.secretarrow.oagents/opencode/status"
        private const val ASSET_DIR = "toolbox"
        private const val VERSION_NAME = "version.txt"
        private const val MODULES_MANIFEST = "modules.json"
        private const val BUNDLE_NAME = "opencode.bundle.js"
        private const val COMPAT_NAME = "oagents-compat.mjs"
        // The opencode server binds the INTERNAL port; the OpenAI-compat
        // adapter (lib/oagents-compat.mjs) listens on PORT for the app —
        // /health, /models and /chat/completions are served by the adapter,
        // which proxies to the server with Basic auth (opencode:<password>).
        private const val PORT = 4096
        private const val INTERNAL_PORT = 4097
        private const val SERVER_PASSWORD = "oagents"
        private const val HEALTH_URL = "http://127.0.0.1:$PORT/health"
        // Revision file written into the extracted toolbox so we can skip
        // re-extraction when the bundled revision has not changed.
        private const val EXTRACTED_REV = ".extracted-revision"
    }

    private val status = AtomicReference<Map<String, Any>>(statusMap("unknown"))
    private var process: Process? = null
    private var adapterProcess: Process? = null
    private var sink: EventChannel.EventSink? = null
    private var extractedRevision: String? = null

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            thread(start = true) { start() }
                            result.success(statusMap("starting"))
                        }
                        "stop" -> {
                            stop()
                            result.success(statusMap("stopped"))
                        }
                        "status" -> result.success(status.get())
                        "version" -> result.success(readBundledVersion())
                        "manifest" -> result.success(readModulesManifest())
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    // Throwable, not Exception: a NoSuchMethodError-class bug
                    // on this background thread must reach the Dart UI as a
                    // failed status, never take the process down (that was
                    // the v1.0.1 startup crash).
                    result.success(statusMap("failed", message = e.message ?: "error"))
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    events?.success(status.get())
                }
                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })
    }

    private fun start() {
        try {
            emit(statusMap("extracting"))
            val workDir = File(context.filesDir, ASSET_DIR).apply { mkdirs() }
            val revision = readBundledVersion()

            // Idempotent extraction: only re-extract when the bundled
            // revision changes. The marker file lives inside the toolbox
            // dir and is wiped with it on a re-extract.
            val marker = File(workDir, EXTRACTED_REV)
            val needExtract = extractedRevision == null ||
                marker.readText().trim() != revision
            if (needExtract) {
                extractToolboxTar(workDir)
                marker.writeText(revision)
                extractedRevision = revision
            }

            val nodeBin = resolveNodeBinary(workDir)
            if (nodeBin == null) {
                emit(statusMap(
                    "failed",
                    message = "No Node runtime found for ABI ${deviceAbi()}. The CI " +
                        "bundle-opencode job (Termux fetch step) must produce a " +
                        "per-ABI node binary at assets/toolbox/bin/node-<abi> " +
                        "(arm64-v8a / armeabi-v7a / x86_64) + companion .so libs " +
                        "under lib/<abi>/. Re-run the workflow and rebuild the APK.",
                    revision = revision,
                ))
                return
            }
            val agentBrowserBin = resolveAgentBrowser(workDir)
            chmodExec(nodeBin)
            agentBrowserBin?.let { chmodExec(it) }

            emit(statusMap("starting", revision = revision))
            // Foreground service keeps the toolbox process alive when the
            // app is backgrounded (wake lock + persistent notification).
            val svc = Intent(context, OAgentsForegroundService::class.java).apply {
                action = OAgentsForegroundService.ACTION_START
                putExtra(OAgentsForegroundService.EXTRA_TITLE, "OAgents · opencode")
                putExtra(OAgentsForegroundService.EXTRA_TEXT, "Embedded opencode running")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(svc)
            } else {
                context.startService(svc)
            }

            val binDir = File(workDir, "bin")
            val libDir = File(workDir, "lib")
            val abi = deviceAbi()
            // Launch the launcher as a SCRIPT FILE (node <file>), NOT via
            // --eval: when node runs an ESM module reached from an --eval
            // context, the CJS global `__filename` leaks into the module
            // scope with the value "[eval]" (as a plain script it is
            // undefined). @effect/platform-node guards its createRequire
            // with `typeof __filename === "string"` and would then pass
            // "[eval]" to createRequire — ERR_INVALID_ARG_VALUE at boot.
            // The launcher cjs file (lib/opencode.bundle.js) injects the
            // serve argv under OPENCODE_SERVE=1 and dynamic-imports the
            // real ESM bundle (lib/opencode.bundle.mjs).
            val bundleLauncher = File(libDir, BUNDLE_NAME)
            val pb = ProcessBuilder(
                listOf(
                    nodeBin.absolutePath,
                    bundleLauncher.absolutePath,
                ),
            ).directory(workDir).redirectErrorStream(true)
            val env = pb.environment()
            env["PORT"] = INTERNAL_PORT.toString()
            env["OPENCODE_SERVE"] = "1"
            // The server requires HTTP Basic auth (user "opencode"); the
            // compat adapter forwards requests with this password. Loopback
            // only, app-private — a fixed local secret is fine.
            env["OPENCODE_PASSWORD"] = SERVER_PASSWORD
            // Tell the npm/npx shell shims which per-ABI node binary to exec.
            env["OAGENTS_ABI"] = abi
            // Make the toolbox's bin/ (node, npm, npx, agent-browser) the
            // FIRST thing on PATH so opencode's child processes resolve
            // them ahead of any system binary. lib/node_modules/.bin comes
            // next: the extracted symlinks (tsc, zx, esbuild, tsx, vite,
            // vitest, prettier …) become plain shell commands for the
            // agent — and npx/npm-exec PATH lookups find them too.
            env["PATH"] = binDir.absolutePath + ":" +
                File(libDir, "node_modules/.bin").absolutePath + ":" +
                (System.getenv("PATH") ?: "/system/bin:/system/xbin")
            // LD_LIBRARY_PATH → per-ABI lib dir, so the Termux-built node-<abi>
            // binary resolves its companion shared libs (libcrypto.so.3,
            // libssl.so.3, libcares, libffi, libicui18n.so.79, libicuuc.so.79,
            // libsqlite3.so, libz.so.1, libc++_shared.so) shipped under
            // toolbox/lib/<abi>/. Bionic's dynamic linker honors
            // LD_LIBRARY_PATH ahead of the binary's baked RUNPATH (which
            // points at Termux's prefix and is wrong outside Termux), so the
            // node binary runs standalone on a vanilla Android system.
            env["LD_LIBRARY_PATH"] = File(libDir, abi).absolutePath
            // NODE_PATH lets `require('ethers')` etc. resolve against the
            // pre-installed node_modules without a per-script install.
            env["NODE_PATH"] = File(libDir, "node_modules").absolutePath
            env["NODE_MODULES_CACHE"] = File(libDir, "node_modules").absolutePath
            // npm/npx global prefix + HOME so `npx <pkg>` and ~/.config work.
            env["npm_config_prefix"] = workDir.absolutePath
            env["HOME"] = context.filesDir.absolutePath
            env["NPM_CONFIG_HOME"] = context.filesDir.absolutePath
            // Dynamic module install support — npm needs a writable tmp dir
            // for staging downloads and a writable cache for the registry
            // metadata + tarballs. Android has no /tmp, so point both at the
            // app's cache dir (writable, not backed up, cleared on uninstall).
            // With these + the prefix above, `npm install -g <pkg>` writes to
            // $prefix/lib/node_modules/<pkg> (= NODE_PATH), and the toolbox's
            // install-module.mjs helper exposes that to the opencode agent as
            // a clean "add a module on demand" entry point.
            val cacheRoot = context.cacheDir.absolutePath
            File(cacheRoot, "npm-tmp").mkdirs()
            File(cacheRoot, "npm-cache").mkdirs()
            env["TMPDIR"] = File(cacheRoot, "npm-tmp").absolutePath
            env["npm_config_tmp"] = File(cacheRoot, "npm-tmp").absolutePath
            env["npm_config_cache"] = File(cacheRoot, "npm-cache").absolutePath
            // Playwright must NOT download Chromium on first use (it would
            // fetch a glibc binary that cannot run on Android). The app's
            // embedded WebView is the browser backend instead.
            env["PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"] = "1"
            env["PLAYWRIGHT_SKIP_BROWSER_GC"] = "1"

            val p = pb.start()
            process = p
            // Drain stdout so the child never blocks on a full pipe buffer.
            thread(start = true, isDaemon = true) {
                try {
                    p.inputStream.bufferedReader().use { r ->
                        r.forEachLine { /* swallow; a future revision can tail it */ }
                    }
                } catch (_: Throwable) {
                }
            }

            // The OpenAI-compat adapter on the APP-facing port (4096): the
            // Dart client (opencode_client.dart) and this bridge's readiness
            // poll both talk to it — /health, /models, /chat/completions —
            // and it proxies to the opencode server with Basic auth. Its
            // /health only answers 200 once the upstream server is reachable.
            val compat = File(libDir, COMPAT_NAME)
            if (compat.exists()) {
                val ca = ProcessBuilder(
                    listOf(
                        nodeBin.absolutePath,
                        compat.absolutePath,
                    ),
                ).directory(workDir).redirectErrorStream(true)
                val cenv = ca.environment()
                cenv["PORT"] = PORT.toString()
                cenv["OCODE_UP"] = "http://127.0.0.1:$INTERNAL_PORT"
                cenv["OCODE_PASS"] = SERVER_PASSWORD
                cenv["NODE_PATH"] = File(libDir, "node_modules").absolutePath
                cenv["TMPDIR"] = File(context.cacheDir, "npm-tmp").absolutePath.also {
                    File(it).mkdirs()
                }
                val ap = ca.start()
                adapterProcess = ap
                thread(start = true, isDaemon = true) {
                    try {
                        ap.inputStream.bufferedReader().use { r ->
                            r.forEachLine { /* drain */ }
                        }
                    } catch (_: Throwable) {
                    }
                }
            }

            val ready = waitForHealth(timeoutMs = 25_000)
            if (ready) {
                emit(statusMap("running", revision = revision, version = revision))
            } else {
                emit(statusMap(
                    "failed",
                    message = "opencode did not answer /health within 25s. " +
                        "Check that opencode.bundle.js is a valid Node bundle and " +
                        "that the node-<abi> binary matches this device.",
                    revision = revision,
                ))
            }
        } catch (e: Throwable) {
            // Throwable: an Error (OOM, NoSuchMethodError, …) here must show
            // up as a failed runtime status in the UI, not kill the process.
            emit(statusMap("failed", message = e.message ?: "start failed"))
        }
    }

    private fun stop() {
        try {
            adapterProcess?.let { it.destroyForcibly() }
            adapterProcess = null
            process?.let { it.destroyForcibly() }
            process = null
            context.stopService(Intent(context, OAgentsForegroundService::class.java))
        } catch (_: Exception) {
        }
        emit(statusMap("stopped"))
    }

    private fun deviceAbi(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP)
            Build.SUPPORTED_ABIS.firstOrNull() ?: "unknown"
        else @Suppress("DEPRECATION") Build.CPU_ABI

    private fun resolveNodeBinary(workDir: File): File? {
        // The Node runtime is a REAL executable shipped per-ABI in the
        // toolbox (Termux-built node, linked against Android's Bionic libc
        // + its companion .so libs under toolbox/lib). It is exec'd
        // directly from filesDir — which is on the app's private data
        // partition and therefore exec-able on every Android version
        // (Termux itself relies on exactly this property).
        //
        // NOTE: nodejs-mobile's libnode.so is a shared LIBRARY, not a PIE
        // executable, so it CANNOT be exec'd via ProcessBuilder. If you
        // later want the in-process libnode.so path, wire nodejs-mobile-
        // android's JNI helper (System.loadLibrary("node") + node::Start)
        // instead — do NOT try to exec libnode.so.
        val abis = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP)
            Build.SUPPORTED_ABIS.toList() else listOf(@Suppress("DEPRECATION") Build.CPU_ABI)
        val binDir = File(workDir, "bin")
        for (abi in abis) {
            val candidate = File(binDir, "node-$abi")
            if (candidate.exists()) return candidate
        }
        return null
    }

    private fun resolveAgentBrowser(workDir: File): File? {
        val abis = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP)
            Build.SUPPORTED_ABIS.toList() else listOf(@Suppress("DEPRECATION") Build.CPU_ABI)
        val binDir = File(workDir, "bin")
        for (abi in abis) {
            val candidate = File(binDir, "agent-browser-$abi")
            if (candidate.exists()) return candidate
        }
        // JS fallback shim (delegates to the agent-browser npm package).
        val jsShim = File(binDir, "agent-browser-js")
        return if (jsShim.exists()) jsShim else null
    }

    private fun chmodExec(file: File) {
        try {
            // setExecutable(true, true) → rwx--x--x; enough for the app's
            // own process to exec the binary without world-read leaks.
            file.setExecutable(true, true)
        } catch (_: Exception) {
            // Best-effort; ProcessBuilder will surface a clear error if the
            // binary still is not executable.
        }
    }

    private fun extractToolboxTar(destDir: File) {
        // The bundle workflow ships toolbox.tar.gz, but AGP's asset pipeline
        // STRIPS the .gz extension and stores the decompressed stream as
        // toolbox.tar inside the APK (default behavior for .gz assets). Try
        // the plain-tar name first (what's actually in the packaged APK),
        // then fall back to the gzipped name + GZIPInputStream (covers a
        // future aaptOptions { noCompress 'gz' } that keeps the .gz name).
        val plain = "$ASSET_DIR/toolbox.tar"
        val gzipped = "$ASSET_DIR/toolbox.tar.gz"
        val assets = context.assets
        val (open, isGz) = try {
            assets.open(plain).use { it.skip(1) }
            plain to false
        } catch (_: IOException) {
            try {
                assets.open(gzipped).use { it.skip(1) }
                gzipped to true
            } catch (e: IOException) {
                throw IOException(
                    "Missing or corrupt bundled toolbox tar ($plain / $gzipped): " +
                        "run the CI bundle-opencode job to produce the Node toolbox.",
                    e,
                )
            }
        }
        try {
            assets.open(open).use { input ->
                val stream = if (isGz) GZIPInputStream(input) else input
                stream.use { TarExtractor(it).extractTo(destDir) }
            }
        } catch (e: IOException) {
            throw IOException(
                "Corrupt bundled toolbox tar ($open): " +
                    "run the CI bundle-opencode job to produce the Node toolbox.",
                e,
            )
        }
    }

    private fun waitForHealth(timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                val url = java.net.URL(HEALTH_URL)
                val conn = url.openConnection() as java.net.HttpURLConnection
                conn.connectTimeout = 1000
                conn.readTimeout = 1000
                conn.requestMethod = "GET"
                conn.inputStream.use { it.read() }
                val code = conn.responseCode
                conn.disconnect()
                if (code in 200..299) return true
            } catch (_: Exception) {
                // Not up yet — keep polling.
            }
            try {
                Thread.sleep(500)
            } catch (_: InterruptedException) {
                return false
            }
        }
        return false
    }

    private fun readBundledVersion(): String = try {
        context.assets.open("$ASSET_DIR/$VERSION_NAME").bufferedReader().use {
            it.readText().trim()
        }
    } catch (_: Exception) { "" }

    private fun readModulesManifest(): String = try {
        context.assets.open("$ASSET_DIR/$MODULES_MANIFEST").bufferedReader().use {
            it.readText()
        }
    } catch (_: Exception) { "" }

    private fun statusMap(
        state: String,
        version: String = "",
        message: String = "",
        revision: String = "",
    ): Map<String, Any> = mapOf(
        "state" to state,
        "version" to version,
        "message" to message,
        "bundledRevision" to revision,
    )

    private fun emit(s: Map<String, Any>) {
        status.set(s)
        sink?.success(s)
    }
}

/**
 * Minimal POSIX tar reader (USTAR-compatible enough for CI-produced
 * tarballs). Streaming, no external deps. Files only — symlinks/dirs are
 * materialized as empty files / created on demand. 512-byte header blocks,
 * name + size + typeflag parsed; long names (>100 chars, common in
 * node_modules) are supported via the GNU `././@LongLink` extension.
 */
internal class TarExtractor(private val input: InputStream) {
    private val header = ByteArray(512)

    /**
     * API-24-safe readFully. InputStream.readNBytes(byte[], int, int) only
     * exists on Android 13 (API 33)+ and this build has NO core-library
     * desugaring — on an Android 7-12 device the first call threw
     * NoSuchMethodError (an Error, not an Exception), which escaped start()'s
     * catch, killed the background thread via the default uncaught handler
     * and took the whole process down: the exact "app crashes right after
     * opening" reported on v1.0.1. This manual loop is the fix.
     */
    private fun readFully(b: ByteArray, off: Int, len: Int): Int {
        var total = 0
        while (total < len) {
            val n = input.read(b, off + total, len - total)
            if (n <= 0) break
            total += n
        }
        return total
    }

    fun extractTo(destDir: File) {
        var longName: String? = null
        while (true) {
            val read = readFully(header, 0, 512)
            if (read < 512 || isZeroBlock(header)) break
            var name = longName
            longName = null
            if (name == null) {
                name = String(header, 0, 100).trimEnd(0.toChar(), ' ', '\u0000')
            }
            if (name.isEmpty()) continue
            val sizeOctal = String(header, 124, 12).trimEnd(0.toChar(), ' ', '\u0000')
            val size = sizeOctal.toLongOrNull(8) ?: 0L
            val typeFlag = header[156].toInt().toChar()
            // Consume the body (size bytes, padded up to 512).
            val padded = ((size + 511) / 512) * 512

            when (name) {
                "././@LongLink", "././@PaxHeader" -> {
                    // Next entry's real name is in this body.
                    val buf = ByteArray(size.toInt())
                    readFully(buf, 0, size.toInt())
                    // skip padding
                    val pad = (padded - size).toInt()
                    if (pad > 0) skipFully(pad)
                    longName = String(buf).trimEnd(0.toChar(), '\u0000')
                    continue
                }
            }

            if (typeFlag == '5' || name.endsWith("/")) {
                // Directory entry — ensure it exists, then move on.
                File(destDir, name).mkdirs()
                if (padded > 0) skipFully(padded.toInt())
                continue
            }
            if (typeFlag == '2') {
                // Symlink — materialize it. npm ships node_modules/.bin as
                // symlinks (tsc, zx, esbuild, tsx, vite, vitest, prettier,
                // agent-browser …); skipping them made every dev CLI
                // invisible on-device (npx/npm-exec and the agent shell
                // could not run any of them — found by the sandbox tar
                // test against the real 905MB toolbox). App-private
                // storage supports symlinks on every Android version;
                // NIO Files.createSymbolicLink exists since API 26, older
                // devices fall back to /system/bin/ln. Any failure degrades
                // to the old skip — the require() path never needs .bin.
                val linkTarget = parseTarString(header, 157, 100)
                if (linkTarget.isNotEmpty()) {
                    createSymlink(File(destDir, name), linkTarget)
                }
                if (padded > 0) skipFully(padded.toInt())
                continue
            }
            // Regular file ('0' or '\u0000').
            val outFile = File(destDir, name)
            outFile.parentFile?.mkdirs()
            outFile.outputStream().use { out ->
                copy(input, out, size)
            }
            // Restore the POSIX mode bits from the tar header. Without this
            // every file landed 0644: bin/npm + bin/npx were NOT executable
            // (install-module.mjs died on-device with "npm install exited
            // -1", empty log) and the .bin symlink TARGETS (typescript/bin/
            // tsc …) were not exec-able. CI never caught it because GNU tar
            // restores modes when it stages/extracts the toolbox.
            val mode = parseTarOctal(header, 100, 8)
            applyPosixMode(outFile, mode)
            // Skip any remaining padding within the last 512 block.
            val pad = (padded - size).toInt()
            if (pad > 0) skipFully(pad)
        }
    }

    /** Trimmed NUL/space string field (tar name, linkname). */
    private fun parseTarString(header: ByteArray, off: Int, len: Int): String {
        var end = off + len
        while (end > off && (header[end - 1] == 0.toByte() || header[end - 1] == ' '.code.toByte())) end--
        return String(header, off, end - off)
    }

    private fun parseTarOctal(header: ByteArray, off: Int, len: Int): Int =
        parseTarString(header, off, len).toLongOrNull(8)?.toInt() ?: 0

    /**
     * Restores the tar header's POSIX mode bits exactly. API 26+ maps every
     * rwx bit 1:1 via java.nio.file.Files.setPosixFilePermissions (checked
     * byte-for-byte against GNU tar on the real 905MB toolbox in the
     * sandbox test); API 24-25 falls back to java.io.File approximations —
     * only the exec bits matter functionally there, and app-private
     * storage relaxations are harmless (single-app sandbox).
     */
    private fun applyPosixMode(file: File, mode: Int) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val perms = java.util.EnumSet.noneOf(
                    java.nio.file.attribute.PosixFilePermission::class.java,
                )
                // Tar mode octal: rwxrwxrwx = 0o111_111_111 (owner, group,
                // other). Kotlin has no octal literals — binary form.
                if (mode and 0b100_000_000 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.OWNER_READ)
                if (mode and 0b010_000_000 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.OWNER_WRITE)
                if (mode and 0b001_000_000 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.OWNER_EXECUTE)
                if (mode and 0b000_100_000 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.GROUP_READ)
                if (mode and 0b000_010_000 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.GROUP_WRITE)
                if (mode and 0b000_001_000 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.GROUP_EXECUTE)
                if (mode and 0b000_000_100 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.OTHERS_READ)
                if (mode and 0b000_000_010 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.OTHERS_WRITE)
                if (mode and 0b000_000_001 != 0) perms.add(java.nio.file.attribute.PosixFilePermission.OTHERS_EXECUTE)
                java.nio.file.Files.setPosixFilePermissions(file.toPath(), perms)
                return
            }
        } catch (_: Exception) {
            // Fall through to the API-24-safe approximation.
        }
        try {
            file.setReadable(mode and 0b100_000_000 != 0, true)
            file.setWritable(mode and 0b010_000_000 != 0, true)
            file.setExecutable(mode and 0b001_000_000 != 0, true)
            if (mode and 0b000_100_100 != 0) file.setReadable(true, false)
            if (mode and 0b000_010_010 != 0) file.setWritable(true, false)
            if (mode and 0b000_001_001 != 0) file.setExecutable(true, false)
        } catch (_: Exception) {
        }
    }

    private fun createSymlink(link: File, target: String) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                java.nio.file.Files.createSymbolicLink(
                    link.toPath(),
                    java.nio.file.Paths.get(target),
                )
                return
            }
        } catch (_: Exception) {
            // Target exists from a previous partial extract, FS refuses
            // symlinks, … — fall through to the ln fallback.
        }
        try {
            // Plain waitFor(): the timed-overload waitFor(long, TimeUnit)
            // only exists since API 26 and this fallback runs exactly on
            // API 24-25. ln is instant — blocking is fine here.
            ProcessBuilder("ln", "-sfn", target, link.absolutePath)
                .redirectErrorStream(true)
                .start()
                .waitFor()
        } catch (_: Exception) {
            // Old behavior: no symlink — the require() path still works.
        }
    }

    /**
     * Reads and discards exactly n bytes (tar padding), buffer-sized, so a
     * corrupt stream cannot make us allocate a huge array up front.
     */
    private fun skipFully(n: Int) {
        var remaining = n
        val buf = ByteArray(64 * 1024)
        while (remaining > 0) {
            val toRead = minOf(remaining, buf.size)
            val got = input.read(buf, 0, toRead)
            if (got <= 0) break
            remaining -= got
        }
    }

    private fun copy(input: InputStream, out: java.io.OutputStream, size: Long) {
        val buf = ByteArray(64 * 1024)
        var remaining = size
        while (remaining > 0) {
            val toRead = minOf(remaining, buf.size.toLong()).toInt()
            val n = input.read(buf, 0, toRead)
            if (n <= 0) break
            out.write(buf, 0, n)
            remaining -= n
        }
    }

    private fun isZeroBlock(b: ByteArray): Boolean {
        for (i in 0 until 512) if (b[i].toInt() != 0) return false
        return true
    }
}
