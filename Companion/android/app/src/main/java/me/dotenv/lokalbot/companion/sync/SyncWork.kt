package me.dotenv.lokalbot.companion.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit
import me.dotenv.lokalbot.companion.CompanionApp

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
