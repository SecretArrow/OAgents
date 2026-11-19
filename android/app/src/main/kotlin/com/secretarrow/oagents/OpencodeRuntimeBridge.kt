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
        private const val TOOLBOX_TAR = "toolbox.tar.gz"
        private const val VERSION_NAME = "version.txt"
        private const val MODULES_MANIFEST = "modules.json"
        private const val BUNDLE_NAME = "opencode.bundle.js"
        private const val PORT = 4096
        private const val HEALTH_URL = "http://127.0.0.1:$PORT/health"
        // Revision file written into the extracted toolbox so we can skip
        // re-extraction when the bundled revision has not changed.
        private const val EXTRACTED_REV = ".extracted-revision"
    }

    private val status = AtomicReference<Map<String, Any>>(statusMap("unknown"))
    private var process: Process? = null
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
                } catch (e: Exception) {
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
            val pb = ProcessBuilder(
                listOf(
                    nodeBin.absolutePath,
                    "--eval",
                    "process.env.PORT='$PORT'; require('./$BUNDLE_NAME')",
                ),
            ).directory(workDir).redirectErrorStream(true)
            val env = pb.environment()
            env["PORT"] = PORT.toString()
            env["OPENCODE_SERVE"] = "1"
            // Tell the npm/npx shell shims which per-ABI node binary to exec.
            env["OAGENTS_ABI"] = abi
            // Make the toolbox's bin/ (node, npm, npx, agent-browser) the
            // FIRST thing on PATH so opencode's child processes resolve
            // them ahead of any system binary.
            env["PATH"] = binDir.absolutePath + ":" +
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
                } catch (_: Exception) {
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
        } catch (e: Exception) {
            emit(statusMap("failed", message = e.message ?: "start failed"))
        }
    }

    private fun stop() {
        try {
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
        try {
            context.assets.open("$ASSET_DIR/$TOOLBOX_TAR").use { input ->
                GZIPInputStream(input).use { gz ->
                    TarExtractor(gz).extractTo(destDir)
                }
            }
        } catch (e: IOException) {
            throw IOException(
                "Missing or corrupt bundled asset $ASSET_DIR/$TOOLBOX_TAR: " +
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

    fun extractTo(destDir: File) {
        var longName: String? = null
        while (true) {
            val read = input.readNBytes(header, 0, 512)
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
                    input.readNBytes(buf, 0, size.toInt())
                    // skip padding
                    val pad = (padded - size).toInt()
                    if (pad > 0) input.readNBytes(ByteArray(pad), 0, pad)
                    longName = String(buf).trimEnd(0.toChar(), '\u0000')
                    continue
                }
            }

            if (typeFlag == '5' || name.endsWith("/")) {
                // Directory entry — ensure it exists, then move on.
                File(destDir, name).mkdirs()
                if (padded > 0) input.readNBytes(ByteArray(padded.toInt()), 0, padded.toInt())
                continue
            }
            if (typeFlag == '2') {
                // Symlink — skip the body (we cannot materialize symlinks
                // reliably across Android storage); node_modules symlinks
                // are rare and the npm install in CI dedupes them.
                if (padded > 0) input.readNBytes(ByteArray(padded.toInt()), 0, padded.toInt())
                continue
            }
            // Regular file ('0' or '\u0000').
            val outFile = File(destDir, name)
            outFile.parentFile?.mkdirs()
            outFile.outputStream().use { out ->
                copy(input, out, size)
            }
            // Skip any remaining padding within the last 512 block.
            val pad = (padded - size).toInt()
            if (pad > 0) input.readNBytes(ByteArray(pad), 0, pad)
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
