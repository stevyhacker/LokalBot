package me.dotenv.lokalbot.companion.ui.common

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import me.dotenv.lokalbot.companion.data.CompanionRepository

/** A screen's state, loaded from the library and reloaded whenever the library changes. */
abstract class LibraryViewModel(protected val repository: CompanionRepository) : ViewModel() {

    @OptIn(ExperimentalCoroutinesApi::class)
    protected fun <T> library(initial: T, load: suspend () -> T): StateFlow<T> =
        repository.revision.mapLatest { load() }.stateIn(viewModelScope, SharingStarted.Eagerly, initial)
}
