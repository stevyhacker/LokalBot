package me.dotenv.lokalbot.companion.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Keeps this device's long-term X25519 private key encrypted with an AES-GCM
 * key that never leaves the Android Keystore (StrongBox when the device has
 * one). The encrypted key lives in no-backup storage, so it is never copied
 * to another device.
 */
class DeviceKeyVault(
    private val file: File,
    private val alias: String = "me.dotenv.lokalbot.device-key-wrap",
) {
    fun loadOrCreate(generate: () -> ByteArray): ByteArray {
        load()?.let { return it }
        val key = generate()
        store(key)
        return key
    }

    fun load(): ByteArray? {
        if (!file.exists()) return null
        val bytes = file.readBytes()
        require(bytes.size > 2 && bytes[0] == FORMAT) { "Unknown device key format" }
        val ivLength = bytes[1].toInt()
        val iv = bytes.copyOfRange(2, 2 + ivLength)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, iv))
        return cipher.doFinal(bytes, 2 + ivLength, bytes.size - 2 - ivLength)
    }

    fun store(privateKey: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val iv = cipher.iv
        val sealed = cipher.doFinal(privateKey)
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeBytes(byteArrayOf(FORMAT, iv.size.toByte()) + iv + sealed)
        check(temp.renameTo(file)) { "Could not save the device key" }
    }

    /** Forgets the device key; pairing again creates a new one. */
    fun erase() {
        file.delete()
        runCatching { keyStore().deleteEntry(alias) }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun wrappingKey(): SecretKey {
        (keyStore().getKey(alias, null) as? SecretKey)?.let { return it }
        return try {
            generateWrappingKey(strongBox = true)
        } catch (_: StrongBoxUnavailableException) {
            generateWrappingKey(strongBox = false)
        }
    }

    private fun generateWrappingKey(strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .setIsStrongBoxBacked(strongBox)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).run {
            init(spec)
            generateKey()
        }
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val FORMAT: Byte = 1
    }
}
