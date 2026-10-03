package uk.co.maybeitsadam.priority.settings

import java.time.Instant
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import uk.co.maybeitsadam.priority.core.SyncCredentials
import uk.co.maybeitsadam.priority.data.sync.SyncEngine
import uk.co.maybeitsadam.priority.ui.settings.SyncStatusText

class SyncPairingLinkTest {
    @Test
    fun formatsAsSwiftDoes() {
        val link = SyncPairingLink("https://sync.example.com:8443/base", "ABC-123")
        assertEquals("priority-sync://pair?server=https://sync.example.com:8443/base&code=ABC-123", link.url)
    }

    @Test
    fun encodesWhatAQueryValueCannotHold() {
        val link = SyncPairingLink("https://example.com/a b", "x&y=z#")
        assertEquals("priority-sync://pair?server=https://example.com/a%20b&code=x%26y%3Dz%23", link.url)
        assertEquals(link, SyncPairingLink.parse(link.url))
    }

    @Test
    fun parsesAndRoundTrips() {
        val parsed = SyncPairingLink.parse("  priority-sync://pair?server=http://10.0.0.2:8080&code=K7Q2  ")
        assertEquals(SyncPairingLink("http://10.0.0.2:8080", "K7Q2"), parsed)
        assertEquals(parsed, SyncPairingLink.parse(parsed!!.url))
    }

    @Test
    fun takesTheFirstOfRepeatedItemsAndIgnoresOthers() {
        val parsed = SyncPairingLink.parse("priority-sync://pair/?extra=1&code=one&server=https://a.example&code=two#frag")
        assertEquals(SyncPairingLink("https://a.example", "one"), parsed)
    }

    @Test
    fun keepsPlusAsPlus() {
        assertEquals("a+b", SyncPairingLink.parse("priority-sync://pair?server=https://x.example&code=a+b")?.code)
    }

    @Test
    fun rejectsWhatSwiftRejects() {
        listOf(
            "priority-sync://pair?server=ftp://x.example&code=abc",
            "priority-sync://pair?server=x.example&code=abc",
            "priority-sync://pair?server=https://x.example&code=",
            "priority-sync://pair?server=https://x.example",
            "priority-sync://pair?code=abc",
            "priority-sync://other?server=https://x.example&code=abc",
            "https://pair?server=https://x.example&code=abc",
            "PRIORITY-SYNC://pair?server=https://x.example&code=abc",
            "priority-sync:pair?server=https://x.example&code=abc",
            "priority-sync://pair?server=https://x.example&code=%zz",
            "",
        ).forEach { assertNull(it, SyncPairingLink.parse(it)) }
    }
}

class SyncCredentialCodecTest {
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

    private val credentials = SyncCredentials("https://sync.example.com", "device-1", "secret-token")

    @Test
    fun roundTrips() {
        val codec = SyncCredentialCodec(FakeCipher())
        val text = codec.encode(credentials)
        assertFalse("the token must not be stored in the clear", "secret-token" in text)
        assertEquals(credentials, codec.decode(text))
    }

    @Test
    fun keepsTheEmailAndAccountWithTheToken() {
        val codec = SyncCredentialCodec(FakeCipher())
        val signedIn = SyncCredentials("https://sync.example.com", "device-1", "secret-token", email = "adam@example.com", accountId = "acct-1")
        val text = codec.encode(signedIn)
        assertFalse("the email must not be stored in the clear", "adam@example.com" in text)
        assertEquals(signedIn, codec.decode(text))
    }

    @Test
    fun readsCredentialsSavedBeforeAccounts() {
        val codec = SyncCredentialCodec(FakeCipher())
        // What a build before accounts sealed: no email, no account id.
        val old = codec.encode(credentials).let(codec::decode)
        assertEquals(null, old?.email)
        assertEquals(credentials, old)
    }

    @Test
    fun freshNonceEachTime() {
        val codec = SyncCredentialCodec(FakeCipher())
        assertNotEquals(codec.encode(credentials), codec.encode(credentials))
    }

    @Test
    fun corruptOrForeignTextReadsAsUnpaired() {
        val codec = SyncCredentialCodec(FakeCipher())
        assertNull(codec.decode("not json"))
        assertNull(codec.decode("""{"v":2,"iv":"AQ==","ciphertext":"AQ=="}"""))
        assertNull(codec.decode("""{"v":1,"iv":"AQ==","ciphertext":"AAAA"}"""))
    }
}

class SyncStatusTest {
    private val creds = SyncCredentials("https://x", "d", "t")
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
    fun aRevokedTokenReadsAsSignedOutNotAsAFailure() {
        assertEquals(SyncUiState.SessionExpired, SyncController.describe(creds, SyncEngine.Status.SignedOut, null))
        assertEquals(SyncUiState.SessionExpired, SyncController.describe(null, null, null, expired = true))
        assertEquals(SyncUiState.Unpaired, SyncController.describe(null, null, null, expired = false))
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
    fun thePasswordResetNoticeNamesTheEmailWithoutSayingTheAccountExists() {
        assertEquals(
            "If there's an account for me@example.com, we've sent a link to reset its password. It works for an hour.",
            SyncController.passwordResetNotice("me@example.com"),
        )
    }
}
