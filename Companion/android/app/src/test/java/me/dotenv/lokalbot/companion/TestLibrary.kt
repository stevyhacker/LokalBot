package me.dotenv.lokalbot.companion

import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import kotlinx.serialization.builtins.ListSerializer
import me.dotenv.lokalbot.companion.data.FixtureRepository
import me.dotenv.lokalbot.companion.data.model.Manifest
import me.dotenv.lokalbot.companion.data.model.Meeting
import me.dotenv.lokalbot.companion.data.model.RecordEnvelope
import me.dotenv.lokalbot.companion.data.model.RecordJson
import me.dotenv.lokalbot.companion.data.model.RecordKind

/**
 * Companion/protocol/fixtures/sample-library.json, pinned to the moment the
 * Mac generated it. Dates come from the fixture so tests follow it when it
 * moves.
 */
object TestLibrary {
    val json: String by lazy {
        val path = System.getProperty("lokalbot.sampleLibrary") ?: "../../protocol/fixtures/sample-library.json"
        File(path).readText()
    }

    private val envelopes: List<RecordEnvelope> by lazy {
        RecordJson.decodeFromString(ListSerializer(RecordEnvelope.serializer()), json)
    }

    private val meetings: List<Meeting> by lazy {
        envelopes.filter { it.kind == RecordKind.MEETING }.map { RecordJson.decodeFromJsonElement(Meeting.serializer(), it.body) }
    }

    /** The manifest's `generatedAt`: "now" for the sample library. */
    val now: Instant by lazy {
        val manifest = envelopes.single { it.kind == RecordKind.MANIFEST }
        Instant.parse(RecordJson.decodeFromJsonElement(Manifest.serializer(), manifest.body).generatedAt!!)
    }

    /** The Mac's offset, from the newest meeting. */
    val zone: ZoneOffset by lazy { ZoneOffset.ofTotalSeconds(meetings.maxBy { it.startedAt }.timeZoneOffsetMinutes * 60) }

    val today: LocalDate by lazy { now.atZone(zone).toLocalDate() }
    val yesterday: LocalDate get() = today.minusDays(1)

    /** Days with a day record, newest first. */
    val days: List<String> by lazy { envelopes.filter { it.kind == RecordKind.DAY }.map { it.key }.sortedDescending() }

    /** Days with meetings, newest first. */
    val meetingDays: List<String> by lazy { meetings.map { it.day }.distinct().sortedDescending() }

    fun dueDate(actionId: String): String = meetings.flatMap { it.actions }.single { it.id == actionId }.dueDate!!

    fun repository(): FixtureRepository = FixtureRepository.fromJson(json, fixedNow = now, streamDelayMillis = 0)

    const val DESIGN_REVIEW = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01"
    const val STANDUP = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e02"
    const val NORTHWIND = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e03"
    const val ONBOARDING = "7a1d0c55-2b8f-4f3a-a6c4-5e6f7a8b9c01"
}
