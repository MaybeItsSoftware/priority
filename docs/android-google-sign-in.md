# Google sign-in on Android

Android signs in with Google natively, through Credential Manager
(`settings/GoogleSignIn.kt`). Google returns an ID token for Takt's **Web**
OAuth client, with a hashed nonce. The app gives that token and the raw nonce
to Supabase's `id_token` grant, and Supabase checks the token's audience
against the client ids configured on its Google provider. The Mac and iPhone
use Supabase's web flow instead, and that flow needs the same Web client.

The Google button is hidden until the build has a Web client id. Its Settings
row also stays hidden when sync points at a Supabase project other than
Takt's, because the client id belongs to Takt's project.

Getting it working takes three OAuth clients in one Google Cloud project, one
Supabase setting and one build value.

## 1. The Web application client

This client's id and secret go to Supabase, and its id goes into the Android
build.

1. Google Cloud console → **APIs & Services → OAuth consent screen**. Set up
   the consent screen if it isn't already: app name Takt, support email, the
   `email`, `profile` and `openid` scopes, and the privacy policy URL from the
   store listing. Publish it, because a consent screen still in Testing only
   lets the test users you list sign in.
2. **Credentials → Create credentials → OAuth client ID → Web application.**
   Name it `Takt web (Supabase)`.
3. Under **Authorized redirect URIs**, add Supabase's callback:
   `https://rsckzmldfpfjdrvulwke.supabase.co/auth/v1/callback`. This is the
   hosted project. A self-hosted project uses its own URL with the same path.
   The web flow on the Mac and iPhone comes back through this URI. Android's
   native flow does not use it.
4. Copy the **Client ID** (`….apps.googleusercontent.com`) and the **Client
   secret**.

## 2. Supabase: the Google provider

Supabase dashboard → the project → **Authentication → Sign In / Providers →
Google**:

- **Enable** it.
- **Client IDs**: the Web client id from step 1. If you later add more
  audiences (an iOS client, say), this field takes them comma-separated, with
  the Web client first.
- **Client Secret**: the Web client's secret.
- Leave **Skip nonce checks** off. The app sends a nonce.

Also check that **Authentication → URL Configuration → Redirect URLs**
includes `takt://auth-callback`, which Apple sign-in and the email links use
to get back to the app.

## 3. The Android clients

Google accepts a native sign-in only from an app whose package name and
signing certificate match an **Android** OAuth client in the same Cloud
project. You never put these clients' ids anywhere; they only need to exist.
A client takes one SHA-1, so make one client for each signing key:

| Client | Package | SHA-1 of |
| --- | --- | --- |
| `Takt Android (Play)` | `uk.co.maybeitssoftware.takt` | Play's **app signing key**, which signs every install from the Play Store |
| `Takt Android (upload)` | `uk.co.maybeitssoftware.takt` | your **upload key** (`keystore.properties`), which signs `scripts/install_android.sh` and sideloaded release builds |
| `Takt Android (debug)`, optional | `uk.co.maybeitssoftware.takt` | `~/.android/debug.keystore`, for `./gradlew installDebug` |

For each one, go to **Credentials → Create credentials → OAuth client ID →
Android**, enter the package name and the SHA-1, and save.

**The Play app signing SHA-1** is in Play Console → the app → **Test and
release → Setup → App signing** (older consoles show it as *Release → Setup →
App integrity → App signing*), under "App signing key certificate". It exists
only after Play App Signing is turned on, which happens on the first bundle
upload. Copy the SHA-1 itself, not the SHA-256.

**The upload key SHA-1**, from the values in `mobile/android/keystore.properties`:

```bash
cd mobile/android
prop() { grep -m1 "^$1=" keystore.properties | cut -d= -f2-; }
keytool -list -v -keystore "$(prop storeFile)" -alias "$(prop keyAlias)" \
  -storepass "$(prop storePassword)" | grep -E '^\s*SHA1:'
```

(`storeFile` is relative to `mobile/android`, as Gradle reads it.) The Play
Console shows the same fingerprint under "Upload key certificate".

**The debug key SHA-1:**

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey \
  -storepass android | grep -E '^\s*SHA1:'
```

## 4. The Web client id in the build

The build reads the **Web** client id from step 1, never an Android client
id, and uses the first of these that is set:

1. The Gradle property: `./gradlew -PpriorityGoogleWebClientId=….apps.googleusercontent.com …`,
   or `priorityGoogleWebClientId=…` in `~/.gradle/gradle.properties`.
2. The environment variable `TAKT_GOOGLE_WEB_CLIENT_ID`. Use this in CI, as a
   repository secret exported into the build step's environment.
3. `priorityGoogleWebClientId=…` in `mobile/android/local.properties`. That
   file is gitignored, so the id stays on the machine that builds releases.

The id is not a secret, because it ships inside the app. It stays out of the
repository because a self-hosted build should not inherit it.

To check that a build picked it up:

```bash
cd mobile/android
./gradlew -q :app:generateReleaseBuildConfig
grep GOOGLE_WEB_CLIENT_ID app/build/generated/source/buildConfig/release/uk/co/maybeitsadam/takt/BuildConfig.java
```

`scripts/build_play_bundle.sh` and `scripts/install_android.sh` run Gradle
from `mobile/android`, so they pick up any of the three.

## When it fails

- **The Google button is missing.** The build had no Web client id, or sync
  points at a different Supabase project.
- **"No credentials available", or the sheet closes straight away.** No
  Android client matches this install's package name and SHA-1. A Play
  install needs the app signing key's client. A sideloaded release build
  needs the upload key's. A debug build needs the debug key's. Newly created
  clients can take a few minutes to take effect.
- **Supabase rejects the token** (`Unacceptable audience` or `invalid id
  token`). The id built into the app is not listed in the provider's Client
  IDs. It must be the Web client, not an Android client.
