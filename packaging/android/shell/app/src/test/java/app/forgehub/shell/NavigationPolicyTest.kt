package app.forgehub.shell

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Exercises NavigationPolicy.decide as a plain JVM unit test -- no
 * Robolectric, no WebView, no device, same rationale as BackendProbeTest:
 * the object under test has no android.* import, so there is nothing here
 * that needs one.
 */
class NavigationPolicyTest {

    @Test
    fun allowsTheBackendOriginItself() {
        assertEquals(
            "the exact origin the WebView is told to load must never be blocked by its own check",
            NavigationPolicy.Decision.LoadInWebView,
            NavigationPolicy.decide(BackendProbe.BACKEND_ORIGIN),
        )
    }

    @Test
    fun allowsAPathUnderTheBackendOrigin() {
        assertEquals(
            NavigationPolicy.Decision.LoadInWebView,
            NavigationPolicy.decide("${BackendProbe.BACKEND_ORIGIN}/upload"),
        )
    }

    @Test
    fun blocksSameHostDifferentPort() {
        // Same host as the backend, but a port nothing here ever serves on --
        // must not be treated as same-origin just because the host matches.
        // (Routed out, same as any other non-backend http/https URL, not
        // Block -- the scheme itself is still fine, only the origin differs.)
        assertEquals(
            NavigationPolicy.Decision.OpenExternally,
            NavigationPolicy.decide("http://${BackendProbe.HOST}:9999/"),
        )
    }

    @Test
    fun routesAnExternalHttpsUrlOutToAnExternalApp() {
        assertEquals(
            NavigationPolicy.Decision.OpenExternally,
            NavigationPolicy.decide("https://example.com/phishing"),
        )
    }

    @Test
    fun blocksAFileUrlOutright() {
        assertEquals(
            NavigationPolicy.Decision.Block,
            NavigationPolicy.decide("file:///etc/passwd"),
        )
    }

    @Test
    fun blocksAContentUrlOutright() {
        assertEquals(
            NavigationPolicy.Decision.Block,
            NavigationPolicy.decide("content://com.android.providers.downloads.documents/document/1"),
        )
    }

    @Test
    fun blocksAnIntentUrlOutright() {
        assertEquals(
            NavigationPolicy.Decision.Block,
            NavigationPolicy.decide("intent://scan/#Intent;scheme=zxing;package=com.example;end"),
        )
    }

    @Test
    fun blocksAJavascriptUrlOutright() {
        assertEquals(
            NavigationPolicy.Decision.Block,
            NavigationPolicy.decide("javascript:alert(document.cookie)"),
        )
    }

    @Test
    fun blocksUnparseableInput() {
        assertEquals(
            NavigationPolicy.Decision.Block,
            NavigationPolicy.decide("not a url at all"),
        )
    }

    // The following three cases lock in a hand-verified review finding (not re-derived
    // here): java.net.URL parses each of these in a way that keeps NavigationPolicy safe
    // today, but only because of how URL itself behaves -- a future swap to
    // android.net.Uri or a hand-rolled parser could silently reopen any of them. Each
    // assertion is on the resulting Decision, not merely that parsing didn't throw.

    @Test
    fun routesUserinfoHostTrickOutExternallyNotToTheBackend() {
        // "http://127.0.0.1@evil.com/" -- java.net.URL reads this as
        // userInfo="127.0.0.1", host="evil.com", so it must NOT be treated as the
        // backend origin just because "127.0.0.1" appears before the "@". A parser
        // that instead keyed off the substring before "@" would wrongly load this
        // inside the trusted WebView.
        assertEquals(
            NavigationPolicy.Decision.OpenExternally,
            NavigationPolicy.decide("http://127.0.0.1@evil.com/"),
        )
    }

    @Test
    fun routesIpv6LoopbackOutExternallyNotToTheBackend() {
        // "http://[::1]:8484/" is IPv6 loopback, a distinct host string from the
        // backend's "127.0.0.1" -- same port, different host, so it must not match.
        assertEquals(
            NavigationPolicy.Decision.OpenExternally,
            NavigationPolicy.decide("http://[::1]:8484/"),
        )
    }

    @Test
    fun loadsBackendOriginRegardlessOfSchemeCase() {
        // "HTTP://127.0.0.1:8484/" -- java.net.URL lowercases the scheme it returns
        // from getProtocol(), so an uppercase-scheme spelling of the exact backend
        // origin must still match and load in the WebView, not get treated as some
        // other/unknown scheme.
        assertEquals(
            NavigationPolicy.Decision.LoadInWebView,
            NavigationPolicy.decide("HTTP://${BackendProbe.HOST}:${BackendProbe.PORT}/"),
        )
    }
}
