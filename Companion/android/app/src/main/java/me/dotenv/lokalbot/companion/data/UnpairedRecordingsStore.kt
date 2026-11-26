package me.dotenv.lokalbot.companion.data

import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import me.dotenv.lokalbot.companion.data.model.RecordJson

class UnpairedRecordingsStore(
    private val directory: File,
    private val now: () -> Instant = Instant::now,
) : RecordingSink {

    @Serializable
    private data class StoredEntry(
        val id: String,
        val title: String = "",
        val state: String,
        val startedAt: String,
        val durationSeconds: Double? = null,
        val byteCount: Long = 0,
    )

    private val lock = Any()
    private val indexFile = File(directory, "index.json")
    private val entries = mutableListOf<StoredEntry>()
    private val _recordings = MutableStateFlow<List<DeviceRecording>>(emptyList())
    val recordings: StateFlow<List<DeviceRecording>> = _recordings.asStateFlow()

    init {
        synchronized(lock) {
            entries.addAll(loadFromDisk())
            publishLocked()
        }
    }

    override suspend fun beginRecording(title: String?): DeviceRecording = synchronized(lock) {
        directory.mkdirs()
        val id = UUID.randomUUID().toString().lowercase()
        val entry = StoredEntry(
            id = id,
            title = title?.trim().orEmpty(),
            state = STATE_RECORDING,
            startedAt = now().toString(),
        )
        entries.add(0, entry)
        saveLocked()
        publishLocked()
        toRecording(entry)
    }

    override suspend fun finishRecording(id: String, durationSeconds: Double): Boolean = synchronized(lock) {
        val index = entries.indexOfFirst { it.id == id }
        if (index < 0) return false
        val file = audioFile(id)
        val size = if (file.isFile) file.length() else 0L
        if (size <= 0L) {
            entries.removeAt(index)
            file.delete()
            saveLocked()
            publishLocked()
            return false
        }
        val current = entries[index]
        if (current.state == STATE_RECORDING) {
            val validDuration = durationSeconds.takeIf { it.isFinite() && it > 0.0 }
            entries[index] = current.copy(
                state = STATE_WAITING,
                durationSeconds = validDuration,
                byteCount = size,
            )
            saveLocked()
            publishLocked()
        }
        true
    }

    override suspend fun recoverRecordings(): Int = synchronized(lock) {
        var kept = 0
        var changed = false
        val remaining = mutableListOf<StoredEntry>()
        for (entry in entries) {
            if (entry.state != STATE_RECORDING) {
                remaining += entry
                continue
            }
            changed = true
            val file = audioFile(entry.id)
            val size = if (file.isFile) file.length() else 0L
            if (size > 0L) {
                remaining += entry.copy(state = STATE_WAITING, byteCount = size)
                kept += 1
            } else {
                file.delete()
            }
        }
        if (changed) {
            entries.clear()
            entries.addAll(remaining)
            saveLocked()
            publishLocked()
        }
        kept
    }

    override suspend fun discardRecording(id: String) = synchronized(lock) {
        entries.removeAll { it.id == id }
        audioFile(id).delete()
        if (indexFile.exists() || entries.isNotEmpty()) saveLocked()
        publishLocked()
    }

    override suspend fun setRecordingTitle(id: String, title: String) = synchronized(lock) {
        val index = entries.indexOfFirst { it.id == id }
        if (index < 0) return
        entries[index] = entries[index].copy(title = title.trim())
        saveLocked()
        publishLocked()
    }

    fun contains(id: String): Boolean = synchronized(lock) { entries.any { it.id == id } }

    fun waitingForMigration(): List<DeviceRecording> = synchronized(lock) {
        entries
            .filter { it.state == STATE_WAITING }
            .sortedBy { it.startedAt }
            .map(::toRecording)
    }

    fun clearAll() = synchronized(lock) {
        if (entries.none { it.state == STATE_RECORDING }) {
            entries.clear()
            directory.deleteRecursively()
        } else {
            entries.filter { it.state != STATE_RECORDING }.forEach { audioFile(it.id).delete() }
            entries.retainAll { it.state == STATE_RECORDING }
            saveLocked()
        }
        publishLocked()
    }

    fun storageBytes(): Long = directory.listFiles()?.sumOf { if (it.isFile) it.length() else 0L } ?: 0L

    private fun audioFile(id: String): File = File(directory, "$id.aac")

    private fun toRecording(entry: StoredEntry): DeviceRecording = DeviceRecording(
        id = entry.id,
        title = entry.title,
        state = if (entry.state == STATE_RECORDING) RecordingState.Recording else RecordingState.Waiting,
        startedAt = entry.startedAt,
        durationSeconds = entry.durationSeconds,
        byteCount = entry.byteCount,
        sentBytes = 0L,
        message = null,
        filePath = audioFile(entry.id).absolutePath,
    )

    private fun publishLocked() {
        _recordings.value = entries.sortedByDescending { it.startedAt }.map(::toRecording)
    }

    private fun saveLocked() {
        directory.mkdirs()
        val temp = File(directory, "index.json.tmp")
        temp.writeText(RecordJson.encodeToString(ListSerializer(StoredEntry.serializer()), entries))
        if (!temp.renameTo(indexFile)) {
            indexFile.writeText(temp.readText())
            temp.delete()
        }
    }

    private fun loadFromDisk(): List<StoredEntry> {
        if (!indexFile.isFile) return emptyList()
        return runCatching {
            RecordJson.decodeFromString(ListSerializer(StoredEntry.serializer()), indexFile.readText())
        }.getOrDefault(emptyList())
    }

    private companion object {
        const val STATE_RECORDING = "recording"
        const val STATE_WAITING = "waiting"
    }
}
