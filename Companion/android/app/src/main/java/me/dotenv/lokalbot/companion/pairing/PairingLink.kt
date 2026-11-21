package me.dotenv.lokalbot.companion.pairing

import java.net.URLDecoder
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import kotlinx.serialization.Serializable
import me.dotenv.lokalbot.companion.data.model.RecordJson

private const val EXPIRY_GRACE_SECONDS = 120L

@Serializable
data class PairingPayload(
    val v: Int = 1,
    val macName: String,
    val macKey: String,
    val addrs: List<String> = emptyList(),
    val port: Int = 17890,
    val pid: String,
    val psk: String,
    val exp: Long,
) {
    fun isExpired(now: Instant): Boolean = now.epochSecond > exp + EXPIRY_GRACE_SECONDS

    val fingerprint: String get() = keyFingerprint(Base64.getUrlDecoder().decode(macKey))
}

sealed interface PairingLinkResult {
    data class Valid(val payload: PairingPayload, val link: String) : PairingLinkResult
    data object NotALink : PairingLinkResult
    data object Unsupported : PairingLinkResult
    data object Expired : PairingLinkResult
}

object PairingLink {
    private const val PREFIX = "lokalbot://pair"

    fun parse(text: String, now: Instant): PairingLinkResult {
        val link = text.trim().let { trimmed ->
            val start = trimmed.indexOf(PREFIX)
            if (start < 0) return PairingLinkResult.NotALink
            trimmed.substring(start).takeWhile { !it.isWhitespace() }
        }
        val data = link.substringAfter('?', "").split('&')
            .firstOrNull { it.startsWith("d=") }?.removePrefix("d=")
            ?.let { runCatching { URLDecoder.decode(it, "UTF-8") }.getOrNull() }
            ?: return PairingLinkResult.NotALink
        val payload = runCatching {
            RecordJson.decodeFromString(PairingPayload.serializer(), String(Base64.getUrlDecoder().decode(data), Charsets.UTF_8))
        }.getOrNull() ?: return PairingLinkResult.NotALink
        if (payload.v != 1) return PairingLinkResult.Unsupported
        if (payload.isExpired(now)) return PairingLinkResult.Expired
        return PairingLinkResult.Valid(payload, link)
    }
}

fun keyFingerprint(publicKey: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(publicKey).joinToString("") { "%02x".format(it) }.take(16)
