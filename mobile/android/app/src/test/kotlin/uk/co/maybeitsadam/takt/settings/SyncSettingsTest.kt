package uk.co.maybeitsadam.takt.settings

import java.security.SecureRandom
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uk.co.maybeitsadam.takt.core.SyncCredentials
import uk.co.maybeitsadam.takt.data.sync.SyncEngine
import uk.co.maybeitsadam.takt.ui.settings.SyncStatusText

/** XOR with a fixed byte and a counter IV: reversible, and not the identity. */
private class FakeCipher : CredentialCipher {
    private var counter = 0
    override fun seal(plaintext: ByteArray): SealedBytes {
        val iv = byteArrayOf((++counter).toByte())
        return SealedBytes(iv, ByteArray(plaintext.size) { (plaintext[it].toInt() xor 0x5A xor iv[0].toInt()).toByte() })
    }

    override fun open(sealed: SealedBytes): ByteArray =
        ByteArray(sealed.ciphertext.size) { (sealed.ciphertext[it].toInt() xor 0x5A xor sealed.iv[0].toInt()).toByte() }
}

class SyncCredentialCodecTest {
    private val credentials = SyncCredentials("https://sync.example.com", "7d1f3c2a-0000-4000-8000-000000000001", "me@example.com", "acct-1")

    @Test
    fun roundTrips() {
        val codec = SyncCredentialCodec(FakeCipher())
        val text = codec.encode(credentials)
        assertFalse("the email must not be stored in the clear", "me@example.com" in text)
        assertEquals(credentials, codec.decode(text))
    }

    @Test
    fun sealsTheSupabaseSession() {
        val codec = SyncCredentialCodec(FakeCipher())
        val session = """{"access_token":"secret-access","refresh_token":"secret-refresh"}"""
        val text = codec.seal(session)
        assertFalse("secret-access" in text)
        assertFalse("secret-refresh" in text)
        assertEquals(session, codec.open(text))
    }

    @Test
    fun freshNonceEachTime() {
        val codec = SyncCredentialCodec(FakeCipher())
        assertNotEquals(codec.encode(credentials), codec.encode(credentials))
    }

    @Test
    fun corruptOrForeignTextReadsAsSignedOut() {
        val codec = SyncCredentialCodec(FakeCipher())
        assertNull(codec.decode("not json"))
        assertNull(codec.decode("""{"v":2,"iv":"AQ==","ciphertext":"AQ=="}"""))
        assertNull(codec.decode("""{"v":1,"iv":"AQ==","ciphertext":"AAAA"}"""))
        assertNull(codec.open("not json"))
    }

    @Test
    fun readsWhatABuildBeforeSupabaseSealedWithoutItsToken() {
        val codec = SyncCredentialCodec(FakeCipher())
        val old = codec.seal(
            """{"serverURL":"https://sync.example.com","deviceId":"7d1f3c2a-0000-4000-8000-000000000009","token":"old-token","email":"me@example.com","accountId":"acct-1"}""",
        )
        assertEquals(
            LegacySignIn("https://sync.example.com", "me@example.com", "7d1f3c2a-0000-4000-8000-000000000009"),
            codec.decodeLegacy(old),
        )
        // Credentials from before accounts had no email.
        val older = codec.seal("""{"serverURL":"https://sync.example.com","deviceId":"d","token":"t"}""")
        assertNull(codec.decodeLegacy(older)!!.email)
        // What this build seals has no token, so it isn't mistaken for the old kind.
        assertNull(codec.decodeLegacy(codec.encode(credentials)))
    }
}

class SyncDeviceIdTest {
    @Test
    fun keepsAnOldIdOnlyWhenTheServerWouldTakeIt() {
        val old = "7d1f3c2a-0000-4000-8000-000000000009"
        assertEquals(old, SyncCredentialStore.stableDeviceId(old))
        listOf(null, "", "device-1", "1-1-1-1-1").forEach { candidate ->
            val made = SyncCredentialStore.stableDeviceId(candidate)
            assertNotEquals(candidate, made)
            assertEquals(made, UUID.fromString(made).toString())
        }
    }
}

class GoogleSignInNonceTest {
    @Test
    fun googleIsGivenTheSha256OfTheNonceSupabaseIsGiven() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", GoogleSignIn.sha256Hex("abc"))
        val nonce = GoogleSignIn.newNonce(SecureRandom())
        assertEquals(64, nonce.length)
        assertTrue(nonce.all { it in "0123456789abcdef" })
        assertNotEquals(nonce, GoogleSignIn.newNonce(SecureRandom()))
    }
}

class SupabaseMessagesTest {
    @Test
    fun knownCodesReadInTheAppsWordsAndTheRestAsSupabaseSaysThem() {
        assertEquals("Wrong email or password.", SupabaseAccounts.describe("invalid_credentials", "Invalid login credentials"))
        assertEquals("There's already an account for that email. Sign in instead.", SupabaseAccounts.describe("user_already_exists", "User already registered"))
        assertEquals("Signups not allowed for this instance.", SupabaseAccounts.describe("signup_disabled", "Signups not allowed for this instance"))
        assertEquals("Something_odd.", SupabaseAccounts.describe("something_odd", null))
    }
}

class SyncStatusTest {
    private val creds = SyncCredentials("https://x", "d")
    private val now = Instant.parse("2026-10-02T14:30:00Z")

    @Test
    fun combinesEngineAndStoredState() {
        assertEquals(SyncUiState.Unpaired, SyncController.describe(null, SyncEngine.Status.Syncing, null))
        assertEquals(SyncUiState.Syncing, SyncController.describe(creds, SyncEngine.Status.Syncing, null))
        assertEquals(SyncUiState.Failed("down"), SyncController.describe(creds, SyncEngine.Status.Failed("down"), null))
        assertEquals(SyncUiState.Idle(now), SyncController.describe(creds, SyncEngine.Status.Synced(now), null))
        assertEquals(SyncUiState.Idle(null), SyncController.describe(creds, SyncEngine.Status.Idle, null))
    }

    @Test
    fun aRefusedRefreshReadsAsSignedOutNotAsAFailure() {
        assertEquals(SyncUiState.SessionExpired, SyncController.describe(creds, SyncEngine.Status.SignedOut, null))
        assertEquals(SyncUiState.SessionExpired, SyncController.describe(null, null, null, expired = true))
        assertEquals(SyncUiState.Unpaired, SyncController.describe(null, null, null, expired = false))
        assertEquals("Signed out — sign in again", SyncStatusText.describe(SyncController.describe(creds, SyncEngine.Status.SignedOut, null)))
    }

    @Test
    fun describesTheStatusLine() {
        val utc = ZoneOffset.UTC
        assertEquals("Not signed in", SyncStatusText.describe(SyncUiState.Unpaired, now, utc))
        assertEquals("Signed in", SyncStatusText.describe(SyncUiState.Idle(null), now, utc))
        assertEquals("Synced just now", SyncStatusText.describe(SyncUiState.Idle(now.minusSeconds(20)), now, utc))
        assertEquals("Synced at 14:05", SyncStatusText.describe(SyncUiState.Idle(now.minusSeconds(25 * 60)), now, utc))
        assertEquals("Synced 1 Oct 09:00", SyncStatusText.describe(SyncUiState.Idle(Instant.parse("2026-10-01T09:00:00Z")), now, utc))
        assertEquals("Signed out — sign in again", SyncStatusText.describe(SyncUiState.SessionExpired, now, utc))
        assertEquals("Couldn't sync: offline", SyncStatusText.describe(SyncUiState.Failed("offline"), now, utc))
    }

    @Test
    fun parsesExpiry() {
        assertEquals(Instant.parse("2026-10-02T15:00:00Z"), SyncController.parseExpiry("2026-10-02T15:00:00Z"))
        assertEquals(Instant.parse("2026-10-02T15:00:00Z"), SyncController.parseExpiry("2026-10-02T16:00:00+01:00"))
        assertNull(SyncController.parseExpiry("soon"))
    }

    @Test
    fun checksTheServerAddressScheme() {
        assertTrue(SyncController.isHttpURL("https://sync.example.com"))
        assertTrue(SyncController.isHttpURL("http://10.0.0.2:8080"))
        assertFalse(SyncController.isHttpURL("ftp://x.example"))
        assertFalse(SyncController.isHttpURL("x.example"))
    }

    @Test
    fun theNoticesNameTheEmailWithoutSayingTheAccountExists() {
        assertEquals(
            "If there's an account for me@example.com, we've sent it a link. Open it on this device to choose a new password.",
            SyncController.passwordResetNotice("me@example.com"),
        )
        assertTrue(SyncController.confirmEmailNotice("me@example.com").startsWith("Check your email to confirm."))
    }
}
