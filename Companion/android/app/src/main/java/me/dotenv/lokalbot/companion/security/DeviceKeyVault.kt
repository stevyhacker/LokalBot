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

class DeviceKeyVault(
    private val file: File,
    private val alias: String = "me.dotenv.lokalbot.device-key-wrap",
    private val keyProvider: (() -> SecretKey)? = null,
    private val keyEraser: (() -> Unit)? = null,
) {
    fun loadOrCreate(generate: () -> ByteArray): ByteArray {
        load()?.let { return it }
        val key = generate()
        store(key)
        return key
    }

    fun load(): ByteArray? {
        if (!file.exists()) return null
        val (iv, ciphertext) = unpackEnvelope(file.readBytes())
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext)
    }

    fun store(privateKey: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val iv = cipher.iv
        val sealed = cipher.doFinal(privateKey)
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeBytes(packEnvelope(iv, sealed))
        check(temp.renameTo(file)) { "Could not save the device key" }
    }

    fun erase() {
        file.delete()
        val eraser = keyEraser
        if (eraser != null) {
            runCatching { eraser() }
        } else {
            runCatching { keyStore().deleteEntry(alias) }
        }
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun wrappingKey(): SecretKey {
        keyProvider?.let { return it() }
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

    internal companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val FORMAT: Byte = 1

        fun packEnvelope(iv: ByteArray, ciphertext: ByteArray): ByteArray {
            require(iv.isNotEmpty() && iv.size <= 255) { "Invalid device key IV length" }
            require(ciphertext.isNotEmpty()) { "Empty device key ciphertext" }
            return byteArrayOf(FORMAT, iv.size.toByte()) + iv + ciphertext
        }

        fun unpackEnvelope(bytes: ByteArray): Pair<ByteArray, ByteArray> {
            require(bytes.size > 2 && bytes[0] == FORMAT) { "Unknown device key format" }
            val ivLength = bytes[1].toInt() and 0xFF
            require(ivLength > 0 && 2 + ivLength < bytes.size) { "Corrupt device key envelope" }
            return bytes.copyOfRange(2, 2 + ivLength) to bytes.copyOfRange(2 + ivLength, bytes.size)
        }
    }
}
