package me.dotenv.lokalbot.companion.sync

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import me.dotenv.lokalbot.companion.MainActivity
import me.dotenv.lokalbot.companion.R
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.data.model.AskResult

/** A local notification when the Mac answers a question queued while it was away. */
class AnswerNotifier(private val context: Context) {

    fun announce(request: AskRequest, result: AskResult) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED &&
            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU
        ) return
        ensureChannel()
        val open = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setContentTitle(context.getString(R.string.notification_answer_title))
            .setContentText(request.question)
            .setStyle(NotificationCompat.BigTextStyle().bigText(request.question))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(result.requestId.hashCode(), notification) }
    }

    private fun ensureChannel() {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.notification_channel_answers), NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = context.getString(R.string.notification_channel_answers_description)
            },
        )
    }

    private companion object {
        const val CHANNEL = "answers"
    }
}
