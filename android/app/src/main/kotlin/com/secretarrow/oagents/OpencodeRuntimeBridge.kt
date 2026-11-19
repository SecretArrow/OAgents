/*
 * OpencodeRuntimeBridge.kt — Dart ⇄ Kotlin bridge for the EMBEDDED
 * opencode CLI runtime.
 *
 * OAgents does NOT talk to a remote opencode server. The opencode CLI
 * binary (bundled as a Node-runnable JS bundle) and a NodeJS Mobile /
 * static-Node runtime are shipped INSIDE the APK and launched on-device
 * by this bridge. The Dart side (lib/services/opencode_runtime.dart)
 * drives the lifecycle through the `com.secretarrow.oagents/opencode`
 * MethodChannel and observes transitions through the
 * `com.secretarrow.oagents/opencode/status` EventChannel.
 *
 * Bundled assets (produced by .github/workflows/bundle-opencode.yml):
 *   assets/opencode/opencode.bundle.js   — opencode source bundled into
 *                                          one Node-runnable file.
 *   assets/opencode/version.txt          — opencode version + revision.
 *   assets/opencode/package.json         — opencode's own package.json
 *                                          (for the require graph).
 * On first launch (or when the bundled revision changes) these are
 * extracted to filesDir/opencode/ and the Node runtime is spawned with
 * the bundle as its entrypoint: `node opencode.bundle.js serve --port
 * 4096`. The runtime binds to 127.0.0.1:4096 INSIDE the app sandbox —
 * no other app can reach it, so no auth is needed on this hop.
 *
 * Node runtime resolution (first match wins):
 *   1. nativeLibraryDir/libnode.so  — NodeJS Mobile shared lib (preferred;
 *      the CI drops a per-ABI libnode.so into android/app/src/main/jniLibs).
 *   2. filesDir/opencode/node       — a static Node binary extracted from
 *      assets/opencode/node-<abi> (Termux-style).
 * If neither is present the bridge reports state=failed with an
 * actionable message instead of crashing — the app still opens, the
 * Settings → opencode screen shows the failure, and the user can retry
 * after the CI has bundled the runtime.
 *
 * Every method is defensive: nothing throws across the channel.
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
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class OpencodeRuntimeBridge(private val context: Context) {

    companion object {
        private const val METHOD = "com.secretarrow.oagents/opencode"
        private const val EVENTS = "com.secretarrow.oagents/opencode/status"
        private const val ASSET_DIR = "opencode"
        private const val BUNDLE_NAME = "opencode.bundle.js"
        private const val VERSION_NAME = "version.txt"
        private const val PACKAGE_NAME = "package.json"
        private const val PORT = 4096
        private const val HEALTH_URL = "http://127.0.0.1:$PORT/health"
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
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    // Never throw across the channel.
                    result.success(statusMap("failed", message = e.message ?: "error"))
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler() {
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
            val needExtract = extractedRevision == null || extractedRevision != revision
            if (needExtract) {
                extractAsset("$ASSET_DIR/$BUNDLE_NAME", File(workDir, BUNDLE_NAME))
                extractAsset("$ASSET_DIR/$VERSION_NAME", File(workDir, VERSION_NAME))
                extractAssetOptional("$ASSET_DIR/$PACKAGE_NAME", File(workDir, PACKAGE_NAME))
                extractedRevision = revision
            }

            val nodeBin = resolveNodeBinary(workDir)
            if (nodeBin == null) {
                emit(statusMap(
                    "failed",
                    message = "No Node runtime found. The CI bundle-opencode job must " +
                        "drop libnode.so into android/app/src/main/jniLibs/<abi>/ or " +
                        "assets/opencode/node-<abi>. Rebuild the APK after bundling.",
                    revision = revision,
                ))
                return
            }

            emit(statusMap("starting", revision = revision))
            // Start the foreground service so a backgrounded app keeps the
            // opencode process alive (wake lock + persistent notification).
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

            val pb = ProcessBuilder(
                listOf(
                    nodeBin.absolutePath,
                    "--eval",
                    "process.env.PORT='$PORT'; require('./$BUNDLE_NAME')",
                ),
            ).directory(workDir).redirectErrorStream(true)
            pb.environment()["PORT"] = PORT.toString()
            pb.environment()["OPENCODE_SERVE"] = "1"
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

            // Poll /health until it answers (max ~20s).
            val ready = waitForHealth(timeoutMs = 20_000)
            if (ready) {
                emit(statusMap("running", revision = revision, version = revision))
            } else {
                emit(statusMap(
                    "failed",
                    message = "opencode did not answer /health within 20s. " +
                        "Check that opencode.bundle.js is a valid Node bundle.",
                    revision = revision,
                ))
            }
        } catch (e: Exception) {
            emit(statusMap("failed", message = e.message ?: "start failed"))
        }
    }

    private fun stop() {
        try {
            process?.let {
                it.destroyForcibly()
            }
            process = null
            val svc = Intent(context, OAgentsForegroundService::class.java)
            context.stopService(svc)
        } catch (_: Exception) {
        }
        emit(statusMap("stopped"))
    }

    private fun resolveNodeBinary(workDir: File): File? {
        // 1. NodeJS Mobile shared lib path (jniLibs/libnode.so is mapped into
        //    nativeLibraryDir at install time).
        val nativeDir = context.applicationInfo.nativeLibraryDir
        val soFile = File(nativeDir, "libnode.so")
        if (soFile.exists()) return soFile
        // 2. Static node binary extracted per-ABI.
        val abis = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) Build.SUPPORTED_ABIS else arrayOf(Build.CPU_ABI)
        for (abi in abis) {
            val extracted = File(workDir, "node-$abi")
            if (extracted.exists() && extracted.canExecute()) return extracted
        }
        return null
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

    private fun extractAsset(assetPath: String, dest: File) {
        try {
            context.assets.open(assetPath).use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
        } catch (e: IOException) {
            throw IOException("Missing bundled asset $assetPath: run the CI bundle-opencode job.", e)
        }
    }

    private fun extractAssetOptional(assetPath: String, dest: File) {
        try {
            context.assets.open(assetPath).use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
        } catch (_: IOException) {
            // Optional asset — its absence is fine.
        }
    }

    private fun readBundledVersion(): String {
        return try {
            context.assets.open("$ASSET_DIR/$VERSION_NAME").bufferedReader().use { it.readText().trim() }
        } catch (_: Exception) {
            ""
        }
    }

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
