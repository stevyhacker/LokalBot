package me.dotenv.lokalbot.companion

import android.app.Application
import android.os.Build
import android.provider.Settings
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.DeviceRecording
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.RecordingState
import me.dotenv.lokalbot.companion.data.RustRepository
import me.dotenv.lokalbot.companion.data.UnpairedRecordingsStore
import me.dotenv.lokalbot.companion.data.UploadOutcome
import me.dotenv.lokalbot.companion.pairing.PairingPayload
import me.dotenv.lokalbot.companion.recording.MediaRecorderCapture
import me.dotenv.lokalbot.companion.recording.MeetingRecorder
import me.dotenv.lokalbot.companion.security.DeviceKeyVault
import me.dotenv.lokalbot.companion.sync.AnswerNotifier
import me.dotenv.lokalbot.companion.sync.MacDiscovery
import me.dotenv.lokalbot.companion.sync.SyncWorker
import me.dotenv.lokalbot.companion.sync.UploadWorker
import me.dotenv.lokalbot.sync.ClientConfig
import me.dotenv.lokalbot.sync.RecordingInfo
import me.dotenv.lokalbot.sync.SyncClient
import me.dotenv.lokalbot.sync.SyncException
import me.dotenv.lokalbot.sync.generateStaticKey

sealed interface PairOutcome {
    data class Paired(val macName: String) : PairOutcome
    data class Failed(val message: String) : PairOutcome
}

class AppContainer(private val app: Application) {
    val preferences = AppPreferences(app)
    val discovery by lazy { MacDiscovery(app) }
    val keyVault = DeviceKeyVault(File(app.noBackupFilesDir, "device-key.bin"))
    val databaseFile = File(app.noBackupFilesDir, "companion.sqlite")

    private val recordingsDir = File(app.noBackupFilesDir, "recordings")
    val unpairedRecordings = UnpairedRecordingsStore(File(app.noBackupFilesDir, "unpaired-recordings"))
    private val notifier by lazy { AnswerNotifier(app) }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val _repository = MutableStateFlow<CompanionRepository?>(null)
    val repository: StateFlow<CompanionRepository?> = _repository.asStateFlow()

    val recorder = MeetingRecorder(
        scope,
        library = { _repository.value ?: unpairedRecordings },
        newCapture = { MediaRecorderCapture(app) },
    )

    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready.asStateFlow()

    private val _removedByMac = MutableStateFlow(false)
    val removedByMac: StateFlow<Boolean> = _removedByMac.asStateFlow()

    fun dismissRemovedNotice() {
        _removedByMac.value = false
    }

    private val _revokedRecordings = MutableStateFlow<List<DeviceRecording>>(emptyList())
    val heldRecordings: StateFlow<List<DeviceRecording>> = combine(
        unpairedRecordings.recordings,
        _revokedRecordings,
    ) { local, revoked ->
        (local + revoked).sortedByDescending { it.startedAt }
    }.stateIn(scope, SharingStarted.Eagerly, emptyList())

    suspend fun discardHeldRecording(id: String) {
        if (unpairedRecordings.contains(id)) {
            withContext(Dispatchers.IO) { unpairedRecordings.discardRecording(id) }
            return
        }
        withContext(Dispatchers.IO) {
            runCatching { openClient(deviceName()) }.getOrNull()?.let { client ->
                runCatching { client.discardRecording(id) }
                val remaining = unsentRecordings(client)
                client.close()
                if (remaining == null) {
                    _revokedRecordings.value = _revokedRecordings.value.filterNot { it.id == id }
                } else {
                    _revokedRecordings.value = remaining
                    if (remaining.isEmpty()) eraseFiles()
                }
            }
        }
    }

    suspend fun discardHeldRecordings() {
        withContext(Dispatchers.IO) {
            unpairedRecordings.clearAll()
            eraseFiles()
        }
        _revokedRecordings.value = emptyList()
    }

    init {
        scope.launch {
            withContext(Dispatchers.IO) { unpairedRecordings.recoverRecordings() }
            val mode = preferences.mode.first()
            _repository.value = when (mode) {
                LibraryMode.Sample -> loadSample()
                LibraryMode.Paired -> openPaired()
                LibraryMode.None -> null
            }
            if (mode != LibraryMode.Paired && databaseFile.exists()) {
                _revokedRecordings.value = withContext(Dispatchers.IO) {
                    runCatching { openClient(deviceName()) }.getOrNull()?.let { client ->
                        unsentRecordings(client).also { client.close() }
                    }.orEmpty()
                }
            }
            _ready.value = true
        }
    }

    fun storageBytes(): Long =
        listOf("", "-wal", "-shm").sumOf { File(databaseFile.path + it).length() } +
            (recordingsDir.listFiles()?.sumOf { it.length() } ?: 0) +
            unpairedRecordings.storageBytes()

    suspend fun openSample() {
        _removedByMac.value = false
        close(_repository.value)
        _repository.value = loadSample()
        preferences.setMode(LibraryMode.Sample)
    }

    suspend fun deviceName(): String = preferences.deviceName() ?: defaultDeviceName()

    suspend fun pair(link: String, payload: PairingPayload, deviceName: String): PairOutcome = withContext(Dispatchers.IO) {
        _removedByMac.value = false
        if (recorder.isActive) return@withContext PairOutcome.Failed(app.getString(R.string.pair_failed_recording))
        val name = deviceName.trim().ifEmpty { defaultDeviceName() }
        preferences.setDeviceName(name)
        val client = try {
            openClient(name)
        } catch (e: Throwable) {
            return@withContext PairOutcome.Failed(app.getString(R.string.pair_failed_core, e.message.orEmpty()))
        }
        try {
            val mac = client.pair(link)
            withContext(NonCancellable) {
                val cutShort = recorder.isActive
                if (cutShort) recorder.abort()
                close(_repository.value)
                val library = paired(client)
                library.migrateLocalRecordings()
                _repository.value = library
                _revokedRecordings.value = emptyList()
                preferences.setMode(LibraryMode.Paired)
                SyncWorker.schedule(app)
                if (cutShort) recorder.recoverIfIdle(library)
                scope.launch {
                    library.sync()
                    UploadWorker.enqueue(app)
                }
            }
            PairOutcome.Paired(mac.macName)
        } catch (e: SyncException) {
            client.close()
            PairOutcome.Failed(pairingMessage(e, payload.macName))
        }
    }

    suspend fun removeLibrary() {
        val current = _repository.value
        val wasPaired = current is RustRepository
        if (wasPaired) recorder.abort()
        _repository.value = null
        withContext(Dispatchers.IO) {
            if (current is RustRepository) {
                runCatching { current.unpairAndClose() }
                unpairedRecordings.clearAll()
            }
            if (wasPaired || _revokedRecordings.value.isEmpty()) eraseFiles()
        }
        if (wasPaired) _revokedRecordings.value = emptyList()
        SyncWorker.cancel(app)
        UploadWorker.cancel(app)
        preferences.setMode(LibraryMode.None)
    }

    fun syncInForeground() {
        val repository = _repository.value?.takeUnless { it.isSample } ?: return
        scope.launch { repository.sync() }
    }

    suspend fun syncInBackground() {
        val repository = library()?.takeUnless { it.isSample } ?: return
        repository.sync()
        repository.uploadRecordings()
    }

    suspend fun uploadInBackground(): UploadOutcome =
        library()?.uploadRecordings() ?: UploadOutcome.Finished(uploaded = 0, waiting = 0, failed = 0)

    private suspend fun library(): CompanionRepository? {
        ready.first { it }
        return _repository.value
    }

    private suspend fun loadSample(): CompanionRepository = withContext(Dispatchers.IO) {
        FixtureRepository.fromJson(
            app.assets.open(SAMPLE_ASSET).bufferedReader().use { it.readText() },
            localRecordings = unpairedRecordings,
        )
    }

    private suspend fun openPaired(): CompanionRepository? = withContext(Dispatchers.IO) {
        val client = runCatching { openClient(deviceName()) }.getOrNull() ?: return@withContext null
        if (client.pairedMac() == null) {
            _revokedRecordings.value = unsentRecordings(client).orEmpty()
            client.close()
            preferences.setMode(LibraryMode.None)
            return@withContext null
        }
        val library = paired(client)
        val migrated = library.migrateLocalRecordings()
        SyncWorker.schedule(app)
        if (migrated > 0 || unpairedRecordings.waitingForMigration().isNotEmpty()) UploadWorker.enqueue(app)
        library.also { recorder.recoverIfIdle(it) }
    }

    private fun paired(client: SyncClient): RustRepository {
        lateinit var library: RustRepository
        library = RustRepository(
            client = client,
            discover = { fingerprint -> discovery.addresses(fingerprint) },
            onQueuedAnswer = notifier::announce,
            onRevoked = { scope.launch { forget(library) } },
            onRecordingsWaiting = { UploadWorker.enqueue(app) },
            unpairedStore = unpairedRecordings,
        )
        return library
    }

    private suspend fun forget(library: RustRepository) {
        if (_repository.value !== library) return
        recorder.abort()
        _repository.value = null
        withContext(Dispatchers.IO) {
            library.heldAfterRevocation()
            library.close()
            val held = runCatching { openClient(deviceName()) }.getOrNull()?.let { client ->
                unsentRecordings(client).also { client.close() }
            }
            _revokedRecordings.value = held.orEmpty()
            if (held != null && held.isEmpty()) eraseFiles()
        }
        SyncWorker.cancel(app)
        UploadWorker.cancel(app)
        preferences.setMode(LibraryMode.None)
        _removedByMac.value = true
    }

    private fun unsentRecordings(client: SyncClient): List<DeviceRecording>? {
        runCatching { client.recoverRecordings() }
        return runCatching {
            client.recordings()
                .filter { it.state != "uploaded" }
                .map(::toDeviceRecording)
        }.getOrNull()
    }

    private fun toDeviceRecording(info: RecordingInfo) = DeviceRecording(
        id = info.id,
        title = info.title,
        state = RecordingState.entries.firstOrNull { it.name.equals(info.state, ignoreCase = true) } ?: RecordingState.Waiting,
        startedAt = info.startedAt,
        durationSeconds = info.durationSeconds,
        byteCount = info.byteCount.toLong(),
        sentBytes = info.sentBytes.toLong(),
        message = info.message,
        filePath = info.filePath,
    )

    private fun eraseFiles() {
        listOf("", "-wal", "-shm").forEach { File(databaseFile.path + it).delete() }
        recordingsDir.deleteRecursively()
        keyVault.erase()
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
