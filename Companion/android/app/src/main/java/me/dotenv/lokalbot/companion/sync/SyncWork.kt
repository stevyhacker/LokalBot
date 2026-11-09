package me.dotenv.lokalbot.companion.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit
import me.dotenv.lokalbot.companion.CompanionApp
import me.dotenv.lokalbot.companion.data.SyncFailure
import me.dotenv.lokalbot.companion.data.UploadOutcome

/**
 * Background catch-up with the Mac. WorkManager can't require "unmetered or
 * VPN" directly, so the worker waits for any network and skips metered
 * connections that aren't Tailscale (a VPN on Android).
 */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        if (!isUnmeteredOrVpn(applicationContext)) return Result.success()
        val container = (applicationContext as CompanionApp).container
        container.syncInBackground()
        return Result.success()
    }

    companion object {
        private const val WORK_NAME = "lokalbot-sync"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<SyncWorker>(30, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }

        fun isUnmeteredOrVpn(context: Context): Boolean {
            val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return false
            val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork) ?: return false
            return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ||
                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }
}

/**
 * Sends waiting recordings, and keeps trying until none are left, so one
 * stopped out of range goes when the computer is back, even if this process
 * died in between. A recording the computer deferred waits the same way; one it
 * refused waits for the person.
 */
class UploadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as CompanionApp).container
        return if (shouldRetry(container.uploadInBackground())) Result.retry() else Result.success()
    }

    companion object {
        private const val WORK_NAME = "lokalbot-upload"

        /** Starts the tries over, so a new recording doesn't wait out an old backoff. */
        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<UploadWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.REPLACE, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }

        fun shouldRetry(outcome: UploadOutcome): Boolean = when (outcome) {
            is UploadOutcome.Finished -> outcome.waiting > 0
            is UploadOutcome.Failed -> outcome.reason != SyncFailure.Revoked && outcome.reason != SyncFailure.NotPaired
        }
    }
}
