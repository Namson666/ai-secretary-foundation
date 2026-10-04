package com.namson.ai_secretary

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Bundle
import android.media.AudioManager
import android.media.AudioDeviceInfo
import io.flutter.plugin.common.MethodChannel

class VoiceCallForegroundService : Service() {
    companion object {
        const val ACTION_START = "com.namson.ai_secretary.START_CALL"
        const val ACTION_STOP = "com.namson.ai_secretary.STOP_CALL"
        private const val CHANNEL_ID = "ai_health_voice_call"
        private const val NOTIFICATION_ID = 301
        var events: MethodChannel? = null
        private var active = false

        fun preferSpeaker(context: android.content.Context) {
            if (!active) return
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
            val audio = context.getSystemService(AudioManager::class.java)
            val current = audio.communicationDevice
            if (current != null && current.type != AudioDeviceInfo.TYPE_BUILTIN_EARPIECE) return
            val speaker = audio.availableCommunicationDevices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            }
            if (speaker != null) audio.setCommunicationDevice(speaker)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            events?.invokeMethod("stopRequested", null)
            stopSelf()
            return START_NOT_STICKY
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "实时语音通话", NotificationManager.IMPORTANCE_LOW)
        )
        val openIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java)
                .putExtra("open_call", true)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this, 1, Intent(this, VoiceCallForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val promotion = Bundle()
        if (Build.VERSION.SDK_INT >= 36) {
            promotion.putBoolean("android.requestPromotedOngoing", true)
        }
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("${applicationInfo.loadLabel(packageManager)}通话中")
            .setContentText("麦克风正在使用；点此返回通话")
            .setContentIntent(openIntent)
            .addAction(Notification.Action.Builder(null, "结束通话", stopIntent).build())
            .setOngoing(true)
            .setShowWhen(false)
            .addExtras(promotion)
            .build()
        active = true
        preferSpeaker(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        active = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(AudioManager::class.java).clearCommunicationDevice()
        }
        super.onDestroy()
    }
}
