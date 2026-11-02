package me.dotenv.lokalbot.companion.sync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ext.SdkExtensions
import androidx.annotation.RequiresApi
import androidx.annotation.RequiresExtension
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.Executors
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/** A Mac advertising `_lokalbot._tcp` on the current network. */
data class DiscoveredMac(val serviceName: String, val host: String, val port: Int, val fingerprint: String?) {
    val address: String get() = if (':' in host) "[$host]:$port" else "$host:$port"
}

/**
 * Finds paired Macs on the local network with NSD (Bonjour). The Rust core
 * takes the resolved "host:port" strings; the Mac's key, not its address,
 * proves it is the right Mac.
 */
class MacDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()
    private val legacyResolve = Mutex()

    /** Browses for [timeout] and returns the addresses to try, best first. */
    suspend fun addresses(fingerprint: String?, timeout: Duration = 2500.milliseconds): List<String> {
        val found = mutableListOf<DiscoveredMac>()
        withTimeoutOrNull(timeout) { services().collect { found += it } }
        return orderedAddresses(found, fingerprint)
    }

    fun services(): Flow<DiscoveredMac> = callbackFlow {
        val lock = wifi?.createMulticastLock("lokalbot-discovery")?.apply {
            setReferenceCounted(false)
            runCatching { acquire() }
        }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                this@callbackFlow.launch(Dispatchers.IO) {
                    withTimeoutOrNull(2000.milliseconds) { resolve(serviceInfo) }?.let { trySend(it) }
                }
            }
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                close()
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        awaitClose {
            runCatching { nsd.stopServiceDiscovery(listener) }
            runCatching { lock?.release() }
        }
    }

    private suspend fun resolve(info: NsdServiceInfo): DiscoveredMac? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
            SdkExtensions.getExtensionVersion(Build.VERSION_CODES.TIRAMISU) >= 7
        ) resolveWithCallback(info) else resolveLegacy(info)

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    @RequiresExtension(extension = Build.VERSION_CODES.TIRAMISU, version = 7)
    private suspend fun resolveWithCallback(info: NsdServiceInfo): DiscoveredMac? = suspendCancellableCoroutine { continuation ->
        val callback = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                if (continuation.isActive) continuation.resume(null)
            }
            override fun onServiceUpdated(serviceInfo: NsdServiceInfo) {
                runCatching { nsd.unregisterServiceInfoCallback(this) }
                if (continuation.isActive) continuation.resume(toMac(serviceInfo, serviceInfo.hostAddresses))
            }
            override fun onServiceLost() = Unit
            override fun onServiceInfoCallbackUnregistered() = Unit
        }
        nsd.registerServiceInfoCallback(info, executor, callback)
        continuation.invokeOnCancellation { runCatching { nsd.unregisterServiceInfoCallback(callback) } }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolveLegacy(info: NsdServiceInfo): DiscoveredMac? = legacyResolve.withLock {
        suspendCancellableCoroutine { continuation ->
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    if (continuation.isActive) continuation.resume(null)
                }
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    if (continuation.isActive) continuation.resume(toMac(serviceInfo, listOfNotNull(serviceInfo.host)))
                }
            })
        }
    }

    private fun toMac(info: NsdServiceInfo, hosts: List<InetAddress>): DiscoveredMac? {
        // Prefer IPv4; link-local IPv6 needs a scope the Rust core can't use.
        val host = hosts.sortedBy { if (it is Inet6Address) 1 else 0 }
            .firstOrNull { !(it is Inet6Address && it.isLinkLocalAddress) }
            ?.hostAddress ?: return null
        val fingerprint = info.attributes["k"]?.toString(Charsets.UTF_8)
        return DiscoveredMac(info.serviceName, host, info.port, fingerprint)
    }

    companion object {
        const val SERVICE_TYPE = "_lokalbot._tcp"

        /** The paired Mac first; Macs advertising a different key are left out. */
        fun orderedAddresses(found: List<DiscoveredMac>, fingerprint: String?): List<String> {
            val usable = found.filter { fingerprint == null || it.fingerprint == null || it.fingerprint.equals(fingerprint, ignoreCase = true) }
            return usable.sortedBy { if (fingerprint != null && it.fingerprint.equals(fingerprint, ignoreCase = true)) 0 else 1 }
                .map { it.address }
                .distinct()
        }

    }
}
