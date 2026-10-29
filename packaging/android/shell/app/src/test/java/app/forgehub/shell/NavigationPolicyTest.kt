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
}
