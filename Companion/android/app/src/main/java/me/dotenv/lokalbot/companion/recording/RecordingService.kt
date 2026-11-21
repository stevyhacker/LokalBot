package me.dotenv.lokalbot.companion.recording

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.CompanionApp
import me.dotenv.lokalbot.companion.MainActivity
import me.dotenv.lokalbot.companion.R

class RecordingService : Service() {
    private val recorder get() = (application as CompanionApp).container.recorder
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var following: Job? = null
    private var finishing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> start()
            ACTION_STOP -> {
                recorder.stop()
                if (following == null) stopSelf()
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun start() {
        val allowed = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        val foreground = allowed && runCatching {
            val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(), type)
        }.isSuccess
        if (foreground) recorder.begin() else recorder.failToStart()
        if (following == null) {
            following = scope.launch {
                val ended = recorder.state.first { it is RecorderState.Idle || it is RecorderState.Failed }
                if (ended is RecorderState.Failed && ended.problem == RecorderProblem.Interrupted) notifyInterrupted()
                finishing = true
                ServiceCompat.stopForeground(this@RecordingService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    override fun onDestroy() {
        if (!finishing) recorder.stop()
        scope.cancel()
        super.onDestroy()
    }

    private fun notifyInterrupted() {
        val open = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stopped = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(getString(R.string.notification_recording_stopped_title))
            .setContentText(getString(R.string.notification_recording_stopped_text))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { getSystemService(NotificationManager::class.java)?.notify(STOPPED_NOTIFICATION_ID, stopped) }
    }

    private fun notification(): Notification {
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(
            NotificationChannel(CHANNEL, getString(R.string.notification_channel_recording), NotificationManager.IMPORTANCE_LOW).apply {
                description = getString(R.string.notification_channel_recording_description)
                setShowBadge(false)
            },
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .putExtra(EXTRA_SHOW_RECORDER, true)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this,
            0,
            Intent(this, RecordingService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(getString(R.string.notification_recording_title))
            .setContentText(getString(R.string.notification_recording_text))
            .setContentIntent(open)
            .setOngoing(true)
            .setUsesChronometer(true)
            .setWhen(System.currentTimeMillis())
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, getString(R.string.recording_stop), stop)
            .build()
    }

    companion object {
        const val EXTRA_SHOW_RECORDER = "showRecorder"

        private const val ACTION_START = "me.dotenv.lokalbot.companion.recording.START"
        private const val ACTION_STOP = "me.dotenv.lokalbot.companion.recording.STOP"
        private const val CHANNEL = "recording"
        private const val NOTIFICATION_ID = 42
        private const val STOPPED_NOTIFICATION_ID = 43

        fun start(context: Context, recorder: MeetingRecorder) {
            if (!recorder.requestStart()) return
            try {
                ContextCompat.startForegroundService(context, Intent(context, RecordingService::class.java).setAction(ACTION_START))
            } catch (_: IllegalStateException) {
                recorder.failToStart()
            }
        }
    }
}
