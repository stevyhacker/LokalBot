package me.dotenv.lokalbot.companion

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

enum class LibraryMode { None, Sample, Paired }

private val Context.settings by preferencesDataStore(name = "settings")

class AppPreferences(private val context: Context) {

    val mode: Flow<LibraryMode> = context.settings.data.map { prefs ->
        prefs[MODE]?.let { stored -> LibraryMode.entries.firstOrNull { it.name == stored } } ?: LibraryMode.None
    }

    val appLockEnabled: Flow<Boolean> = context.settings.data.map { it[APP_LOCK] ?: false }

    suspend fun setMode(mode: LibraryMode) {
        context.settings.edit { it[MODE] = mode.name }
    }

    suspend fun setAppLockEnabled(enabled: Boolean) {
        context.settings.edit { it[APP_LOCK] = enabled }
    }

    suspend fun deviceId(): String {
        context.settings.data.first()[DEVICE_ID]?.let { return it }
        val id = UUID.randomUUID().toString()
        context.settings.edit { it[DEVICE_ID] = id }
        return id
    }

    suspend fun deviceName(): String? = context.settings.data.first()[DEVICE_NAME]

    suspend fun setDeviceName(name: String) {
        context.settings.edit { it[DEVICE_NAME] = name }
    }

    private companion object {
        val MODE = stringPreferencesKey("libraryMode")
        val APP_LOCK = booleanPreferencesKey("appLock")
        val DEVICE_ID = stringPreferencesKey("deviceId")
        val DEVICE_NAME = stringPreferencesKey("deviceName")
    }
}
