package me.dotenv.lokalbot.companion.pairing

import com.google.common.truth.Truth.assertThat
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import me.dotenv.lokalbot.companion.data.MacRoute
import me.dotenv.lokalbot.companion.data.hostOf
import me.dotenv.lokalbot.companion.data.routeForAddress
import me.dotenv.lokalbot.companion.sync.DiscoveredMac
import me.dotenv.lokalbot.companion.sync.MacDiscovery
import org.junit.Test

class PairingLinkTest {
    private val now = Instant.parse("2026-10-31T10:00:00Z")
    private val macKey = ByteArray(32) { it.toByte() }

    private fun link(version: Int = 1, exp: Long = now.epochSecond + 300): String {
        val key = Base64.getUrlEncoder().withoutPadding().encodeToString(macKey)
        val json = """{"v":$version,"macName":"Stevan's MacBook Pro","macKey":"$key","addrs":["192.168.1.20","100.101.102.103","macbook.tail1234.ts.net"],"port":17890,"pid":"AAECAwQFBgcICQoLDA0ODw","psk":"$key","exp":$exp,"future":true}"""
        return "lokalbot://pair?d=" + Base64.getUrlEncoder().withoutPadding().encodeToString(json.toByteArray())
    }

    @Test
    fun `a valid link decodes what the phone shows before pairing`() {
        val result = PairingLink.parse("  ${link()}\n", now) as PairingLinkResult.Valid
        assertThat(result.payload.macName).isEqualTo("Stevan's MacBook Pro")
        assertThat(result.payload.addrs).hasSize(3)
        assertThat(result.payload.port).isEqualTo(17890)
        assertThat(result.link).isEqualTo(link())
    }

    @Test
    fun `links are found inside pasted text`() {
        assertThat(PairingLink.parse("Pair with this: ${link()} (expires soon)", now)).isInstanceOf(PairingLinkResult.Valid::class.java)
    }

    @Test
    fun `rejects other text, expired codes and newer versions`() {
        assertThat(PairingLink.parse("https://example.com", now)).isEqualTo(PairingLinkResult.NotALink)
        assertThat(PairingLink.parse("lokalbot://pair?d=%%%", now)).isEqualTo(PairingLinkResult.NotALink)
        assertThat(PairingLink.parse(link(exp = now.epochSecond - 1), now)).isEqualTo(PairingLinkResult.Expired)
        assertThat(PairingLink.parse(link(version = 2), now)).isEqualTo(PairingLinkResult.Unsupported)
    }

    @Test
    fun `fingerprint is the first 16 hex characters of SHA-256 of the Mac key`() {
        val payload = (PairingLink.parse(link(), now) as PairingLinkResult.Valid).payload
        val expected = MessageDigest.getInstance("SHA-256").digest(macKey).joinToString("") { "%02x".format(it) }.take(16)
        assertThat(payload.fingerprint).isEqualTo(expected)
        assertThat(payload.fingerprint).hasLength(16)
    }

    @Test
    fun `addresses map to Wi-Fi or Tailscale`() {
        assertThat(routeForAddress("192.168.1.20:17890")).isEqualTo(MacRoute.Wifi)
        assertThat(routeForAddress("10.0.0.4")).isEqualTo(MacRoute.Wifi)
        assertThat(routeForAddress("100.101.102.103:17890")).isEqualTo(MacRoute.Tailscale)
        assertThat(routeForAddress("100.63.0.1")).isEqualTo(MacRoute.Wifi)
        assertThat(routeForAddress("macbook.tail1234.ts.net:17890")).isEqualTo(MacRoute.Tailscale)
        assertThat(routeForAddress("[fd7a:115c:a1e0::1]:17890")).isEqualTo(MacRoute.Tailscale)
        assertThat(hostOf("[fe80::1]:17890")).isEqualTo("fe80::1")
        assertThat(hostOf("fd7a:115c:a1e0::1")).isEqualTo("fd7a:115c:a1e0::1")
    }

    @Test
    fun `discovery prefers the paired Mac and skips Macs with other keys`() {
        val found = listOf(
            DiscoveredMac("LokalBot-AAAA", "192.168.1.30", 17890, "ffffffffffffffff"),
            DiscoveredMac("LokalBot-BBBB", "192.168.1.31", 17890, null),
            DiscoveredMac("LokalBot-CCCC", "192.168.1.20", 17890, "0123456789abcdef"),
            DiscoveredMac("LokalBot-CCCC", "fd00::20", 17890, "0123456789ABCDEF"),
        )
        assertThat(MacDiscovery.orderedAddresses(found, "0123456789abcdef"))
            .containsExactly("192.168.1.20:17890", "[fd00::20]:17890", "192.168.1.31:17890").inOrder()
        assertThat(MacDiscovery.orderedAddresses(found, null)).hasSize(4)
    }
}
