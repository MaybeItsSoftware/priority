package uk.co.maybeitsadam.priority.settings

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.edit
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import uk.co.maybeitsadam.priority.core.SyncCredentials

/** Ciphertext and the nonce it was sealed with. */
class SealedBytes(val iv: ByteArray, val ciphertext: ByteArray)

/** Seals and opens bytes. The app's is [KeystoreCredentialCipher]; tests use a fake. */
interface CredentialCipher {
    fun seal(plaintext: ByteArray): SealedBytes
    fun open(sealed: SealedBytes): ByteArray
}

/**
 * Credentials to and from the string kept on disk: the credentials' JSON,
 * sealed by a [CredentialCipher], then `{"v":1,"iv":…,"ciphertext":…}` in
 * base64. [decode] answers null for anything it cannot open (a corrupt file,
 * or a Keystore key that was wiped with the lock screen), which reads as
 * "not paired" rather than as a crash.
 */
class SyncCredentialCodec(private val cipher: CredentialCipher) {
    @Serializable
    private data class Envelope(val v: Int = 1, val iv: String, val ciphertext: String)

    private val json = Json { ignoreUnknownKeys = true }
    private val base64 = Base64.getEncoder()
    private val unbase64 = Base64.getDecoder()

    fun encode(credentials: SyncCredentials): String {
        val sealed = cipher.seal(json.encodeToString(SyncCredentials.serializer(), credentials).toByteArray(Charsets.UTF_8))
        return json.encodeToString(
            Envelope.serializer(),
            Envelope(iv = base64.encodeToString(sealed.iv), ciphertext = base64.encodeToString(sealed.ciphertext)),
        )
    }

    fun decode(text: String): SyncCredentials? = runCatching {
        val envelope = json.decodeFromString(Envelope.serializer(), text)
        if (envelope.v != 1) return null
        val plain = cipher.open(SealedBytes(unbase64.decode(envelope.iv), unbase64.decode(envelope.ciphertext)))
        json.decodeFromString(SyncCredentials.serializer(), plain.toString(Charsets.UTF_8))
    }.getOrNull()
}

/** AES-256-GCM with a key that lives in the AndroidKeyStore and never leaves it. */
class KeystoreCredentialCipher(private val alias: String = "priority.sync.credentials") : CredentialCipher {
    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    override fun seal(plaintext: ByteArray): SealedBytes {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return SealedBytes(cipher.iv, cipher.doFinal(plaintext))
    }

    override fun open(sealed: SealedBytes): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed.iv))
        return cipher.doFinal(sealed.ciphertext)
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
    }
}

/**
 * Where the sync credentials live: sealed by [codec] in a private
 * SharedPreferences file, outside the workspace database (which syncs and is
 * readable by the CLI on the Mac; the token must be neither).
 */
class SyncCredentialStore(
    context: Context,
    private val codec: SyncCredentialCodec = SyncCredentialCodec(KeystoreCredentialCipher()),
) {
    private val prefs = context.applicationContext.getSharedPreferences("sync_credentials", Context.MODE_PRIVATE)

    fun load(): SyncCredentials? = prefs.getString(KEY, null)?.let(codec::decode)

    fun save(credentials: SyncCredentials) {
        prefs.edit(commit = true) { putString(KEY, codec.encode(credentials)) }
    }

    fun clear() {
        prefs.edit(commit = true) { remove(KEY) }
    }

    /**
     * What to prefill once the device is signed out: the server and email
     * (sealed like the credentials, with no token), and whether the server
     * signed it out rather than the user.
     */
    fun loadSignedOut(): SignedOutHint? {
        val sealed = prefs.getString(KEY_SIGNED_OUT, null) ?: return null
        val remembered = codec.decode(sealed) ?: return null
        return SignedOutHint(remembered.email, remembered.serverURL.takeIf { it.isNotBlank() }, prefs.getBoolean(KEY_EXPIRED, false))
    }

    fun saveSignedOut(hint: SignedOutHint) {
        val remembered = SyncCredentials(hint.serverURL ?: "", deviceId = "", token = "", email = hint.email)
        prefs.edit(commit = true) {
            putString(KEY_SIGNED_OUT, codec.encode(remembered))
            putBoolean(KEY_EXPIRED, hint.expired)
        }
    }

    fun clearSignedOut() {
        prefs.edit(commit = true) {
            remove(KEY_SIGNED_OUT)
            remove(KEY_EXPIRED)
        }
    }

    private companion object {
        const val KEY = "sealed"
        const val KEY_SIGNED_OUT = "signed_out"
        const val KEY_EXPIRED = "signed_out_expired"
    }
}
