package com.namson.ai_secretary

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.namson.ai_secretary.duix.DuixViewFactory
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

class MainActivity : FlutterActivity() {
    private val CONFIG_CHANNEL = "com.namson.ai_secretary/config"
    private val DUIX_CHANNEL = "com.namson.ai_secretary/duix"
    private val CALL_CHANNEL = "com.namson.ai_secretary/call"
    private var callChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 注册 DUIX PlatformView
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.namson.ai_secretary/duix_view",
            DuixViewFactory(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        )

        // API Key MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONFIG_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getApiKey" -> {
                    val key = call.argument<String>("key")
                    val value = when (key) {
                        "minimax" -> BuildConfig.MINIMAX_KEY
                        "mimo" -> BuildConfig.MINIMAX_KEY
                        "deepseek" -> BuildConfig.DEEPSEEK_KEY
                        "tencent_secret_id" -> BuildConfig.TENCENT_SECRET_ID
                        "tencent_secret_key" -> BuildConfig.TENCENT_SECRET_KEY
                        "bailian_workspace_id" -> BuildConfig.BAILIAN_WORKSPACE_ID
                        "bailian_api_key" -> BuildConfig.BAILIAN_API_KEY
                        else -> ""
                    }
                    result.success(value)
                }
                else -> result.notImplemented()
            }
        }

        callChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL)
        VoiceCallForegroundService.events = callChannel
        callChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                        result.error("microphone_permission", "请先允许使用麦克风", null)
                    } else {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                            }
                            startForegroundService(
                                Intent(this, VoiceCallForegroundService::class.java)
                                    .setAction(VoiceCallForegroundService.ACTION_START)
                            )
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("foreground_service", error.message, null)
                        }
                    }
                }
                "stop" -> {
                    stopService(Intent(this, VoiceCallForegroundService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // DUIX MethodChannel（全局 DUIX 控制接口）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DUIX_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startRandomMotion" -> result.success(true)
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra("open_call", false)) {
            callChannel?.invokeMethod("openRequested", null)
        }
    }

    override fun onDestroy() {
        if (VoiceCallForegroundService.events === callChannel) {
            VoiceCallForegroundService.events = null
        }
        super.onDestroy()
    }
}
