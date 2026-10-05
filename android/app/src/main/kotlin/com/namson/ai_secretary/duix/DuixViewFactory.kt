package com.namson.ai_secretary.duix

import android.content.Context
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import ai.guiji.duix.sdk.client.DUIX
import ai.guiji.duix.sdk.client.render.DUIXRenderer
import ai.guiji.duix.sdk.client.render.DUIXTextureView
import java.util.concurrent.Executors

class DuixViewFactory(
    private val messenger: BinaryMessenger,
    private val appContext: Context
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        Log.d(TAG, "Creating DuixView id=$viewId args=$args")
        return DuixPlatformView(appContext, viewId, args, messenger)
    }

    companion object {
        private const val TAG = "DuixViewFactory"
    }
}

class DuixPlatformView(
    private val context: Context,
    private val viewId: Int,
    args: Any?,
    messenger: BinaryMessenger
) : PlatformView {

    private val container: FrameLayout
    private val duixView: DuixTextureView
    private val modelPath: String
    private var duix: DUIX? = null
    private var methodChannel: MethodChannel
    private var audioResult: MethodChannel.Result? = null
    private var audioStarted = false

    init {
        modelPath = (args as? Map<*, *>)?.get("modelPath") as? String ?: ""
        Log.d(TAG, "DuixPlatformView init modelPath=$modelPath")

        methodChannel = MethodChannel(messenger, "com.namson.ai_secretary/duix_view_$viewId")

        duixView = DuixTextureView(context, modelPath) { duixInstance ->
            duix = duixInstance
            Log.d(TAG, "DUIX initialized successfully")
            // Notify Flutter side
            try {
                methodChannel.invokeMethod("onDuixInitialized", true)
            } catch (e: Throwable) {
                Log.e(TAG, "Failed to notify Flutter of DUIX init", e)
            }
        }
        duixView.onAudioEvent = { event ->
            when (event) {
                "play.start" -> audioStarted = true
                "play.end" -> if (audioStarted) {
                    audioStarted = false
                    audioResult?.success(true)
                    audioResult = null
                }
                "play.error" -> {
                    audioStarted = false
                    audioResult?.error("audio_error", "Digital avatar playback failed", null)
                    audioResult = null
                }
            }
        }
        duixView.onInitError = {
            methodChannel.invokeMethod("onDuixError", "数字人初始化失败，仍可使用文字和语音")
        }
        container = FrameLayout(context).apply {
            addView(duixView, FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            ))
        }

        setupMethodChannel()
    }

    private fun setupMethodChannel() {
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "playPcm" -> {
                    val bytes = call.argument<ByteArray>("pcm")
                    val active = duix
                    if (active?.isReady != true) {
                        result.error("not_ready", "Digital avatar is not ready", null)
                    } else if (bytes == null || bytes.isEmpty() || bytes.size % 2 != 0) {
                        result.error("invalid_pcm", "Expected 16kHz mono 16-bit PCM", null)
                    } else if (audioResult != null) {
                        result.error("audio_busy", "Stop previous playback first", null)
                    } else {
                        audioStarted = false
                        audioResult = result
                        try {
                            com.namson.ai_secretary.VoiceCallForegroundService.preferSpeaker(context)
                            active.startPush()
                            for (offset in bytes.indices step 32000) {
                                active.pushPcm(bytes.copyOfRange(offset, minOf(offset + 32000, bytes.size)))
                            }
                            active.stopPush()
                        } catch (e: Throwable) {
                            audioResult = null
                            result.error("audio_error", "Digital avatar playback failed", null)
                        }
                    }
                }
                "stopAudio" -> {
                    try { duix?.stopAudio() } catch (_: Throwable) {}
                    audioStarted = false
                    audioResult?.success(false)
                    audioResult = null
                    result.success(null)
                }
                "setEmotion" -> {
                    val emotion = call.argument<String>("emotion")
                    Log.d(TAG, "setEmotion $emotion")
                    val motionName = emotionToMotion(emotion)
                    if (motionName != null) {
                        Log.d(TAG, "setEmotion triggering motion: $motionName")
                        try { duix?.startMotion(motionName, true) }
                        catch (e: Throwable) { Log.e(TAG, "startMotion failed", e) }
                    }
                    result.success(true)
                }
                "bodyAction" -> {
                    val action = call.argument<String>("action")
                    Log.d(TAG, "bodyAction $action")
                    if (action != null) {
                        try { duix?.startMotion(action, true) }
                        catch (e: Throwable) { Log.e(TAG, "startMotion failed", e) }
                    }
                    result.success(true)
                }
                "setSpeaking" -> {
                    val speaking = call.argument<Boolean>("speaking") ?: false
                    Log.d(TAG, "setSpeaking $speaking")
                    result.success(true)
                }
                "startSpeaking" -> {
                    Log.d(TAG, "startSpeaking")
                    result.success(true)
                }
                "stopSpeaking" -> {
                    Log.d(TAG, "stopSpeaking")
                    result.success(true)
                }
                "startPush" -> {
                    try { duix?.startPush(); result.success(true) }
                    catch (e: Throwable) { result.error("err", e.message, null) }
                }
                "stopPush" -> {
                    try { duix?.stopPush(); result.success(true) }
                    catch (e: Throwable) { result.error("err", e.message, null) }
                }
                "pushPcm" -> {
                    try {
                        val bytes = call.argument<ByteArray>("pcm")
                        if (bytes != null) duix?.pushPcm(bytes)
                        result.success(true)
                    }
                    catch (e: Throwable) { result.error("err", e.message, null) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun emotionToMotion(emotion: String?): String? {
        return when (emotion) {
            "happy" -> "smile"
            "excited" -> "smile"
            "sad" -> "frown"
            "worried" -> "frown"
            "surprised" -> "raiseEyebrow"
            "gentle" -> "smile"
            "neutral" -> "idle"
            else -> null
        }
    }

    override fun getView(): View = container

    override fun dispose() {
        Log.d(TAG, "dispose DuixPlatformView")
        duixView.onAudioEvent = null
        duixView.onInitError = null
        audioResult?.success(false)
        audioResult = null
        try { duix?.release() } catch (e: Throwable) { Log.e(TAG, "release failed", e) }
        methodChannel.setMethodCallHandler(null)
    }

    companion object {
        private const val TAG = "DuixPlatformView"
    }
}

class DuixTextureView(
    context: Context,
    private val modelPath: String,
    private val onInitialized: (DUIX?) -> Unit
) : DUIXTextureView(context) {
    var onAudioEvent: ((String) -> Unit)? = null
    var onInitError: (() -> Unit)? = null

    private var pendingSurface: SurfaceTexture? = null
    private var pendingWidth = 0
    private var pendingHeight = 0
    private var initialized = false
    private var initInProgress = false
    private var disposed = false
    private var duix: DUIX? = null
    private var renderer: DUIXRenderer? = null
    private var retryCount = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        setEGLContextClientVersion(2)
        setEGLConfigChooser(8, 8, 8, 8, 16, 0)
        isOpaque = false
    }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
        Log.d(TAG, "onSurfaceTextureAvailable w=$width h=$height")
        disposed = false
        pendingSurface = surface
        pendingWidth = width
        pendingHeight = height
        mainHandler.post {
            Log.d(TAG, "onSurfaceTextureAvailable deferred init")
            maybeInit()
        }
    }

    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
        if (initialized) {
            super.onSurfaceTextureSizeChanged(surface, width, height)
        }
    }

    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        Log.d(TAG, "onSurfaceTextureDestroyed")
        mainHandler.removeCallbacksAndMessages(null)
        if (initialized) {
            try {
                super.onSurfaceTextureDestroyed(surface)
            } catch (e: Throwable) { Log.e(TAG, "surfaceDestroyed error", e) }
            try { duix?.release() } catch (e: Throwable) { Log.e(TAG, "release failed", e) }
        }
        initialized = false
        initInProgress = false
        duix = null
        pendingSurface = null
        return true
    }

    override fun onAttachedToWindow() {
        Log.d(TAG, "onAttachedToWindow")
        disposed = false
        super.onAttachedToWindow()
    }

    override fun onDetachedFromWindow() {
        Log.d(TAG, "onDetachedFromWindow")
        disposed = true
        mainHandler.removeCallbacksAndMessages(null)
        if (initialized) {
            try { duix?.release() } catch (e: Throwable) { Log.e(TAG, "release failed", e) }
        }
        initialized = false
        initInProgress = false
        duix = null
        super.onDetachedFromWindow()
    }

    private fun maybeInit() {
        if (disposed) return
        if (initialized) return
        if (initInProgress) return
        val surface = pendingSurface
        if (surface == null) {
            Log.w(TAG, "maybeInit: no pending surface, retrying")
            mainHandler.postDelayed({
                if (!disposed) maybeInit()
            }, 50)
            return
        }

        initInProgress = true
        val attempt = retryCount + 1
        Log.d(TAG, "maybeInit: preparing resources in background (attempt $attempt)")

        resourceExecutor.execute {
            try {
                ResourcePreparer.prepareIfNeeded(context.applicationContext)
                mainHandler.post {
                    if (disposed || initialized) {
                        initInProgress = false
                        return@post
                    }
                    if (pendingSurface !== surface) {
                        initInProgress = false
                        maybeInit()
                        return@post
                    }
                    initializeDuix(surface)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "DUIX resource preparation failed", e)
                mainHandler.post {
                    initInProgress = false
                    retryInit()
                }
            }
        }
    }

    private fun initializeDuix(surface: SurfaceTexture) {
        if (disposed || initialized) {
            initInProgress = false
            return
        }

        val resolvedName = modelPath
            .removePrefix("local://bundled/")
            .removePrefix("local://")
            .ifEmpty { "小秘" }
        Log.d(TAG, "maybeInit: resolved modelName=$resolvedName")

        try {
            val activeRenderer = renderer ?: DUIXRenderer(context, this).also {
                // Match the viewport without letterboxing; preserve aspect ratio.
                it.setScaleType(0)
                // This calibration belongs only to the shipped XiaoMi 540x960 model.
                it.setRepairBundledCeiling(resolvedName == "小秘")
                setRenderer(it)
                renderMode = RENDERMODE_WHEN_DIRTY
                super.onSurfaceTextureAvailable(surface, pendingWidth, pendingHeight)
                onResume()
                renderer = it
            }

            duix = DUIX(context, resolvedName, activeRenderer) { event, msg, info ->
                Log.i(TAG, "DUIX callback event=$event msg=$msg")
                mainHandler.post {
                    if (event == "play.start" || event == "play.end" || event == "play.error") {
                        onAudioEvent?.invoke(event)
                    }
                    when (event) {
                        "init.ready" -> {
                            initInProgress = false
                            Log.d(TAG, "DUIX is ready, notifying Flutter")
                            if (!initialized) {
                                initialized = true
                                onInitialized(duix)
                            }
                        }
                        "init.error" -> {
                            initInProgress = false
                            Log.e(TAG, "DUIX init error: $msg")
                            if (shouldRetryInit(msg)) {
                                retryInit()
                            } else {
                                Log.e(TAG, "DUIX init error is not retryable; keeping fallback avatar")
                                onInitError?.invoke()
                            }
                        }
                    }
                }
            }
            duix?.init()
            if (duix?.isReady == true) {
                duix?.startRandomMotion(true)
            }
        } catch (e: Throwable) {
            Log.e(TAG, "DUIX init failed with exception", e)
            initInProgress = false
            duix = null
            retryInit()
        }
        // Do NOT call onInitialized here — wait for "init.ready" callback
    }

    private fun shouldRetryInit(message: String?): Boolean {
        if (message == null) return true
        return !message.contains("Model configuration read exception") &&
            !message.contains("does not exist")
    }

    private fun retryInit() {
        if (disposed) return
        if (initialized) return
        retryCount++
        if (retryCount < 10) {
            val delay = (retryCount * 1000).coerceAtMost(5000)
            Log.d(TAG, "Retrying DUIX init in ${delay}ms (attempt $retryCount/10)...")
            mainHandler.postDelayed({
                if (!disposed && !initialized) {
                    try { duix?.release() } catch (_: Throwable) {}
                    duix = null
                    initInProgress = false
                    maybeInit()
                }
            }, delay.toLong())
        } else {
            Log.e(TAG, "DUIX init failed after 10 retries")
            onInitError?.invoke()
        }
    }

    companion object {
        private const val TAG = "DuixTextureView"
        private val resourceExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "duix-resource-prep").apply { isDaemon = true }
        }
    }
}
