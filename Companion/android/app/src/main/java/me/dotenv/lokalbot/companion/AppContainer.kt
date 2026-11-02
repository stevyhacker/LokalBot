package me.dotenv.lokalbot.companion

import android.app.Application
import android.os.Build
import android.provider.Settings
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.RustRepository
import me.dotenv.lokalbot.companion.pairing.PairingPayload
import me.dotenv.lokalbot.companion.security.DeviceKeyVault
import me.dotenv.lokalbot.companion.sync.AnswerNotifier
import me.dotenv.lokalbot.companion.sync.MacDiscovery
import me.dotenv.lokalbot.companion.sync.SyncWorker
import me.dotenv.lokalbot.sync.ClientConfig
import me.dotenv.lokalbot.sync.SyncClient
import me.dotenv.lokalbot.sync.SyncException
import me.dotenv.lokalbot.sync.generateStaticKey

/** Outcome of pairing with a Mac. */
sealed interface PairOutcome {
    data class Paired(val macName: String) : PairOutcome
    data class Failed(val message: String) : PairOutcome
}

/** Builds the app's long-lived objects and switches between libraries. */
class AppContainer(private val app: Application) {
    val preferences = AppPreferences(app)
    val discovery by lazy { MacDiscovery(app) }
    val keyVault = DeviceKeyVault(File(app.noBackupFilesDir, "device-key.bin"))
    val databaseFile = File(app.noBackupFilesDir, "companion.sqlite")
    private val notifier by lazy { AnswerNotifier(app) }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _repository = MutableStateFlow<CompanionRepository?>(null)
    val repository: StateFlow<CompanionRepository?> = _repository.asStateFlow()

    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready.asStateFlow()

    /** True after the Mac removed this device, until the person moves on. */
    private val _removedByMac = MutableStateFlow(false)
    val removedByMac: StateFlow<Boolean> = _removedByMac.asStateFlow()

    fun dismissRemovedNotice() {
        _removedByMac.value = false
    }

    init {
        scope.launch {
            _repository.value = when (preferences.mode.first()) {
                LibraryMode.Sample -> loadSample()
                LibraryMode.Paired -> openPaired()
                LibraryMode.None -> null
            }
            _ready.value = true
        }
    }

    /** Bytes the synced library takes on this device. */
    fun storageBytes(): Long = listOf("", "-wal", "-shm").sumOf { File(databaseFile.path + it).length() }

    suspend fun openSample() {
        _removedByMac.value = false
        close(_repository.value)
        _repository.value = loadSample()
        preferences.setMode(LibraryMode.Sample)
    }

    /** The name the Mac shows in its approval prompt: the one set before, else the system's. */
    suspend fun deviceName(): String = preferences.deviceName() ?: defaultDeviceName()

    /** Pairs with the Mac in [link] as [deviceName]; blocks until the person answers on the Mac. */
    suspend fun pair(link: String, payload: PairingPayload, deviceName: String): PairOutcome = withContext(Dispatchers.IO) {
        _removedByMac.value = false
        val name = deviceName.trim().ifEmpty { defaultDeviceName() }
        preferences.setDeviceName(name)
        val client = try {
            openClient(name)
        } catch (e: Throwable) {
            return@withContext PairOutcome.Failed(app.getString(R.string.pair_failed_core, e.message.orEmpty()))
        }
        try {
            val mac = client.pair(link)
            close(_repository.value)
            val library = paired(client)
            _repository.value = library
            preferences.setMode(LibraryMode.Paired)
            SyncWorker.schedule(app)
            scope.launch { library.sync() }
            PairOutcome.Paired(mac.macName)
        } catch (e: SyncException) {
            client.close()
            PairOutcome.Failed(pairingMessage(e, payload.macName))
        }
    }

    /** Leaves the sample library, or erases the synced copy and forgets the Mac. */
    suspend fun removeLibrary() {
        val current = _repository.value
        _repository.value = null
        withContext(Dispatchers.IO) {
            if (current is RustRepository) runCatching { current.unpairAndClose() }
            listOf("", "-wal", "-shm").forEach { File(databaseFile.path + it).delete() }
            keyVault.erase()
        }
        SyncWorker.cancel(app)
        preferences.setMode(LibraryMode.None)
    }

    fun syncInForeground() {
        val repository = _repository.value?.takeUnless { it.isSample } ?: return
        scope.launch { repository.sync() }
    }

    suspend fun syncInBackground() {
        _repository.value?.takeUnless { it.isSample }?.sync()
    }

    private suspend fun loadSample(): CompanionRepository = withContext(Dispatchers.IO) {
        FixtureRepository.fromJson(app.assets.open(SAMPLE_ASSET).bufferedReader().use { it.readText() })
    }

    /** The library paired earlier, or null when the store no longer holds a pairing. */
    private suspend fun openPaired(): CompanionRepository? = withContext(Dispatchers.IO) {
        val client = runCatching { openClient(deviceName()) }.getOrNull() ?: return@withContext null
        if (client.pairedMac() == null) {
            client.close()
            preferences.setMode(LibraryMode.None)
            return@withContext null
        }
        SyncWorker.schedule(app)
        paired(client)
    }

    private fun paired(client: SyncClient): RustRepository {
        lateinit var library: RustRepository
        library = RustRepository(
            client = client,
            discover = { fingerprint -> discovery.addresses(fingerprint) },
            onQueuedAnswer = notifier::announce,
            onRevoked = { scope.launch { forget(library) } },
        )
        return library
    }

    /** The Mac removed this device and the core erased its copy: back to the welcome screen. */
    private suspend fun forget(library: RustRepository) {
        if (_repository.value !== library) return
        _repository.value = null
        withContext(Dispatchers.IO) {
            library.close()
            listOf("", "-wal", "-shm").forEach { File(databaseFile.path + it).delete() }
            keyVault.erase()
        }
        SyncWorker.cancel(app)
        preferences.setMode(LibraryMode.None)
        _removedByMac.value = true
    }

    private suspend fun openClient(deviceName: String): SyncClient = SyncClient(
        ClientConfig(
            dbPath = databaseFile.absolutePath,
            deviceId = preferences.deviceId(),
            deviceName = deviceName,
            platform = "android",
            staticPrivateKey = keyVault.loadOrCreate { generateStaticKey().privateKey },
        ),
    )

    /** The device name from system settings when readable, else manufacturer and model. */
    private fun defaultDeviceName(): String {
        Settings.Global.getString(app.contentResolver, Settings.Global.DEVICE_NAME)?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        val model = Build.MODEL.trim()
        if (model.startsWith(Build.MANUFACTURER, ignoreCase = true)) return model
        return "${Build.MANUFACTURER.replaceFirstChar { it.titlecase() }} $model".trim()
    }

    private fun pairingMessage(e: SyncException, macName: String): String = when (e) {
        is SyncException.PairingRejected -> app.getString(R.string.pair_failed_rejected, macName)
        is SyncException.PairingExpired -> app.getString(R.string.pair_problem_expired)
        is SyncException.Unreachable, is SyncException.Io -> app.getString(R.string.pair_failed_unreachable, macName)
        else -> app.getString(R.string.pair_failed_other, e.message.orEmpty())
    }

    private fun close(repository: CompanionRepository?) {
        (repository as? RustRepository)?.close()
    }

    companion object {
        const val SAMPLE_ASSET = "sample-library.json"
    }
}
