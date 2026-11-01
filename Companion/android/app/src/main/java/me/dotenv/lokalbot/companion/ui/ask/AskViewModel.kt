package me.dotenv.lokalbot.companion.ui.ask

import androidx.lifecycle.viewModelScope
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import me.dotenv.lokalbot.companion.data.AskEvent
import me.dotenv.lokalbot.companion.data.CompanionRepository
import me.dotenv.lokalbot.companion.data.SearchHit
import me.dotenv.lokalbot.companion.data.SyncState
import me.dotenv.lokalbot.companion.data.model.AskExchange
import me.dotenv.lokalbot.companion.data.model.AskRequest
import me.dotenv.lokalbot.companion.data.model.AskResult
import me.dotenv.lokalbot.companion.data.model.AskTurn
import me.dotenv.lokalbot.companion.ui.common.LibraryViewModel

enum class TurnPhase { Streaming, Done, Failed, MacUnreachable, Queued }

data class AskTurnState(
    val request: AskRequest,
    val askedAt: Instant,
    val answer: String = "",
    val result: AskResult? = null,
    val phase: TurnPhase = TurnPhase.Streaming,
    val error: String? = null,
    val localHits: List<SearchHit>? = null,
)

data class Conversation(val id: String, val title: String, val lastAt: String?, val exchanges: List<AskExchange>)

data class AskState(
    val conversationId: String,
    val turns: List<AskTurnState> = emptyList(),
    val conversations: List<Conversation> = emptyList(),
) {
    val busy: Boolean get() = turns.lastOrNull()?.phase == TurnPhase.Streaming
}

/**
 * Questions go to the Mac, which streams the answer back with citations.
 * When the Mac can't be reached the phone offers its own search and a queue.
 */
class AskViewModel(repository: CompanionRepository) : LibraryViewModel(repository) {
    private val _state = MutableStateFlow(AskState(conversationId = newId()))
    val state: StateFlow<AskState> = _state.asStateFlow()
    val syncState: StateFlow<SyncState> = repository.syncState
    val isSample: Boolean get() = repository.isSample
    private var job: Job? = null

    init {
        refreshHistory()
    }

    fun ask(question: String) {
        val text = question.trim()
        if (text.isEmpty() || _state.value.busy) return
        val previous = _state.value.turns.filter { it.phase == TurnPhase.Done }
        val request = AskRequest(
            requestId = newId(),
            conversationId = _state.value.conversationId,
            question = text,
            history = previous.flatMap { listOf(AskTurn("user", it.request.question), AskTurn("assistant", it.answer)) },
        )
        _state.update { it.copy(turns = it.turns + AskTurnState(request, repository.now())) }
        job = viewModelScope.launch {
            repository.ask(request).collect { event ->
                updateTurn(request.requestId) { turn ->
                    when (event) {
                        is AskEvent.Delta -> turn.copy(answer = turn.answer + event.text)
                        is AskEvent.Done -> turn.copy(answer = event.result.answer, result = event.result, phase = TurnPhase.Done)
                        is AskEvent.Failed -> turn.copy(
                            phase = if (event.macUnreachable) TurnPhase.MacUnreachable else TurnPhase.Failed,
                            error = event.message,
                        )
                    }
                }
            }
            refreshHistory()
        }
    }

    fun stop() {
        job?.cancel()
        _state.update { state -> state.copy(turns = state.turns.map { if (it.phase == TurnPhase.Streaming) it.copy(phase = TurnPhase.Failed) else it }) }
    }

    fun searchThisDevice(requestId: String) {
        val turn = _state.value.turns.firstOrNull { it.request.requestId == requestId } ?: return
        viewModelScope.launch {
            val hits = repository.search(turn.request.question, limit = 12)
            updateTurn(requestId) { it.copy(localHits = hits) }
        }
    }

    fun askWhenMacIsBack(requestId: String) {
        val turn = _state.value.turns.firstOrNull { it.request.requestId == requestId } ?: return
        viewModelScope.launch {
            repository.queueQuestion(turn.request)
            updateTurn(requestId) { it.copy(phase = TurnPhase.Queued) }
        }
    }

    fun newConversation() {
        job?.cancel()
        _state.update { it.copy(conversationId = newId(), turns = emptyList()) }
    }

    fun openConversation(id: String) {
        val conversation = _state.value.conversations.firstOrNull { it.id == id } ?: return
        job?.cancel()
        _state.update {
            it.copy(
                conversationId = id,
                turns = conversation.exchanges.map { exchange ->
                    AskTurnState(
                        request = exchange.request,
                        askedAt = exchange.result.answeredAt?.let { at -> runCatching { Instant.parse(at) }.getOrNull() } ?: repository.now(),
                        answer = exchange.result.answer,
                        result = exchange.result,
                        phase = TurnPhase.Done,
                    )
                },
            )
        }
    }

    private fun refreshHistory() {
        viewModelScope.launch {
            val conversations = repository.askHistory(200)
                .groupBy { it.request.conversationId }
                .map { (id, exchanges) ->
                    val ordered = exchanges.reversed()
                    Conversation(id, ordered.first().request.question, exchanges.first().result.answeredAt, ordered)
                }
            _state.update { it.copy(conversations = conversations) }
        }
    }

    private fun updateTurn(requestId: String, change: (AskTurnState) -> AskTurnState) {
        _state.update { state -> state.copy(turns = state.turns.map { if (it.request.requestId == requestId) change(it) else it }) }
    }

    private companion object {
        fun newId() = UUID.randomUUID().toString()
    }
}
