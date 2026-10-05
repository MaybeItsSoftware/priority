package uk.co.maybeitsadam.takt.settings

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.edit
import java.security.KeyStore
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import uk.co.maybeitsadam.takt.core.SyncCredentials

/** Ciphertext and the nonce it was sealed with. */
class SealedBytes(val iv: ByteArray, val ciphertext: ByteArray)

/** Seals and opens bytes. The app's is [KeystoreCredentialCipher]; tests use a fake. */
interface CredentialCipher {
    fun seal(plaintext: ByteArray): SealedBytes
    fun open(sealed: SealedBytes): ByteArray
}

/**
 * Text to and from the string kept on disk: sealed by a [CredentialCipher],
 * then `{"v":1,"iv":…,"ciphertext":…}` in base64. [open] answers null for
 * anything it cannot open (a corrupt file, or a Keystore key that was wiped
 * with the lock screen), which reads as "signed out" rather than as a crash.
 */
class SyncCredentialCodec(private val cipher: CredentialCipher) {
    @Serializable
    private data class Envelope(val v: Int = 1, val iv: String, val ciphertext: String)

    /**
     * What builds before Supabase sealed: the server's own device id and the
     * bearer token it issued, which the server no longer takes.
     */
    @Serializable
    private data class LegacyCredentials(
        val serverURL: String,
        val deviceId: String,
        val token: String,
        val email: String? = null,
    )

    private val json = Json { ignoreUnknownKeys = true }
    private val base64 = Base64.getEncoder()
    private val unbase64 = Base64.getDecoder()

    fun seal(text: String): String {
        val sealed = cipher.seal(text.toByteArray(Charsets.UTF_8))
        return json.encodeToString(
            Envelope.serializer(),
            Envelope(iv = base64.encodeToString(sealed.iv), ciphertext = base64.encodeToString(sealed.ciphertext)),
        )
    }

    fun open(text: String): String? = runCatching {
        val envelope = json.decodeFromString(Envelope.serializer(), text)
        if (envelope.v != 1) return null
        cipher.open(SealedBytes(unbase64.decode(envelope.iv), unbase64.decode(envelope.ciphertext))).toString(Charsets.UTF_8)
    }.getOrNull()

    fun encode(credentials: SyncCredentials): String = seal(json.encodeToString(SyncCredentials.serializer(), credentials))

    fun decode(text: String): SyncCredentials? =
        open(text)?.let { runCatching { json.decodeFromString(SyncCredentials.serializer(), it) }.getOrNull() }

    /**
     * Credentials a build before Supabase sealed, as what to prefill and the
     * device id worth keeping; null when [text] isn't one.
     */
    fun decodeLegacy(text: String): LegacySignIn? = open(text)
        ?.let { runCatching { json.decodeFromString(LegacyCredentials.serializer(), it) }.getOrNull() }
        ?.let { LegacySignIn(it.serverURL, it.email, it.deviceId) }
}

/** What a device signed in before Supabase leaves behind once its token is dropped. */
data class LegacySignIn(val serverURL: String, val email: String?, val deviceId: String)

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
 * Where sync keeps what it needs between launches, in a private
 * SharedPreferences file outside the workspace database (which syncs, and
 * the CLI on the Mac can read; the tokens must be in neither):
 *
 * - the Supabase session (access and refresh tokens), sealed by [codec];
 * - which server this device syncs with and as whom ([SyncCredentials]), sealed;
 * - the device's own id, made once and kept across sign-outs;
 * - while signed out, what to prefill.
 */
class SyncCredentialStore(
    context: Context,
    private val codec: SyncCredentialCodec = SyncCredentialCodec(KeystoreCredentialCipher()),
) {
    private val prefs = context.applicationContext.getSharedPreferences("sync_credentials", Context.MODE_PRIVATE)

    fun load(): SyncCredentials? = prefs.getString(KEY_ACCOUNT, null)?.let(codec::decode)

    fun save(credentials: SyncCredentials) {
        prefs.edit(commit = true) { putString(KEY_ACCOUNT, codec.encode(credentials)) }
    }

    fun clear() {
        prefs.edit(commit = true) { remove(KEY_ACCOUNT) }
    }

    /** The Supabase session's JSON, or null when there is none (or it can't be opened). */
    fun loadSession(): String? = prefs.getString(KEY_SESSION, null)?.let(codec::open)

    fun saveSession(json: String) {
        prefs.edit(commit = true) { putString(KEY_SESSION, codec.seal(json)) }
    }

    fun clearSession() {
        prefs.edit(commit = true) { remove(KEY_SESSION) }
    }

    /**
     * This device's id: made once, the first time it is asked for, and kept.
     * [adopting] is an id to keep instead when there is none yet, if it is a uuid.
     */
    @Synchronized
    fun deviceId(adopting: String? = null): String {
        prefs.getString(KEY_DEVICE_ID, null)?.let { return it }
        val id = stableDeviceId(adopting)
        prefs.edit(commit = true) { putString(KEY_DEVICE_ID, id) }
        return id
    }

    /**
     * Credentials a build before Supabase left, removed as they are read:
     * their token is no use to the server any more.
     */
    fun takeLegacy(): LegacySignIn? {
        val sealed = prefs.getString(KEY_LEGACY, null) ?: return null
        prefs.edit(commit = true) { remove(KEY_LEGACY) }
        return codec.decodeLegacy(sealed)
    }

    /** The server a browser sign-in (Apple, or an emailed link) started with, for when it comes back. */
    var pendingServer: String?
        get() = prefs.getString(KEY_PENDING_SERVER, null)
        set(value) = prefs.edit(commit = true) { if (value == null) remove(KEY_PENDING_SERVER) else putString(KEY_PENDING_SERVER, value) }

    /** Set when a password-reset link was asked for here, so the sign-in it brings back asks for a new password. */
    var recoveryPending: Boolean
        get() = prefs.getBoolean(KEY_RECOVERY, false)
        set(value) = prefs.edit(commit = true) { putBoolean(KEY_RECOVERY, value) }

    /**
     * What to prefill once the device is signed out: the server and email
     * (sealed like the credentials), and whether it was signed out for it
     * rather than by the user.
     */
    fun loadSignedOut(): SignedOutHint? {
        val sealed = prefs.getString(KEY_SIGNED_OUT, null) ?: return null
        val remembered = codec.decode(sealed) ?: return null
        return SignedOutHint(remembered.email, remembered.serverURL.takeIf { it.isNotBlank() }, prefs.getBoolean(KEY_EXPIRED, false))
    }

    fun saveSignedOut(hint: SignedOutHint) {
        val remembered = SyncCredentials(hint.serverURL ?: "", deviceId = "", email = hint.email)
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

    companion object {
        /** Where builds before Supabase kept their sealed device token. */
        private const val KEY_LEGACY = "sealed"
        private const val KEY_ACCOUNT = "account"
        private const val KEY_SESSION = "supabase_session"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_PENDING_SERVER = "pending_server"
        private const val KEY_RECOVERY = "recovery_pending"
        private const val KEY_SIGNED_OUT = "signed_out"
        private const val KEY_EXPIRED = "signed_out_expired"

        /** [candidate] when it is a uuid (the server takes nothing else), or a new random one. */
        fun stableDeviceId(candidate: String?): String =
            candidate?.let { runCatching { UUID.fromString(it).toString() }.getOrNull() }?.takeIf { it.equals(candidate, ignoreCase = true) }
                ?: UUID.randomUUID().toString()
    }
}
