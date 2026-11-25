package me.dotenv.lokalbot.companion.security

import com.google.common.truth.Truth.assertThat
import java.io.File
import java.nio.file.Files
import javax.crypto.AEADBadTagException
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertThrows
import org.junit.Test

class DeviceKeyVaultTest {

    private fun testKey(): SecretKeySpec = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")

    @Test
    fun `loadOrCreate generates once then reloads the same private key`() {
        val dir = Files.createTempDirectory("device-key-vault").toFile()
        try {
            val file = File(dir, "device.key")
            val key = testKey()
            var erased = false
            val vault = DeviceKeyVault(file, keyProvider = { key }, keyEraser = { erased = true })

            assertThat(vault.load()).isNull()
            val expected = ByteArray(32) { (0xA0 + it).toByte() }
            var calls = 0
            val created = vault.loadOrCreate {
                calls += 1
                expected
            }
            assertThat(created).isEqualTo(expected)
            assertThat(calls).isEqualTo(1)
            assertThat(file.exists()).isTrue()

            val reloaded = vault.loadOrCreate {
                calls += 1
                ByteArray(32)
            }
            assertThat(reloaded).isEqualTo(expected)
            assertThat(calls).isEqualTo(1)

            vault.erase()
            assertThat(erased).isTrue()
            assertThat(file.exists()).isFalse()
            assertThat(vault.load()).isNull()
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `tampered ciphertext is rejected by GCM tag verification`() {
        val dir = Files.createTempDirectory("device-key-vault-tamper").toFile()
        try {
            val file = File(dir, "device.key")
            val key = testKey()
            val vault = DeviceKeyVault(file, keyProvider = { key })
            vault.store(ByteArray(32) { it.toByte() })

            val corrupted = file.readBytes()
            corrupted[corrupted.lastIndex] = (corrupted.last().toInt() xor 0xFF).toByte()
            file.writeBytes(corrupted)

            assertThrows(AEADBadTagException::class.java) {
                vault.load()
            }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `envelope handles high-bit iv lengths and rejects malformed headers`() {
        val longIv = ByteArray(130) { it.toByte() }
        val body = byteArrayOf(1, 2, 3, 4)
        val packed = DeviceKeyVault.packEnvelope(longIv, body)
        val (unpackedIv, unpackedBody) = DeviceKeyVault.unpackEnvelope(packed)
        assertThat(unpackedIv).isEqualTo(longIv)
        assertThat(unpackedBody).isEqualTo(body)

        assertThrows(IllegalArgumentException::class.java) {
            DeviceKeyVault.unpackEnvelope(byteArrayOf(1, 12))
        }
        assertThrows(IllegalArgumentException::class.java) {
            DeviceKeyVault.unpackEnvelope(byteArrayOf(9, 12) + ByteArray(20))
        }
        assertThrows(IllegalArgumentException::class.java) {
            DeviceKeyVault.unpackEnvelope(byteArrayOf(1, 0, 5, 6))
        }
        assertThrows(IllegalArgumentException::class.java) {
            DeviceKeyVault.unpackEnvelope(byteArrayOf(1, 20) + ByteArray(10))
        }
        assertThrows(IllegalArgumentException::class.java) {
            DeviceKeyVault.unpackEnvelope(byteArrayOf(1, 4, 1, 2, 3, 4))
        }
    }
}
