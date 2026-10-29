package app.forgehub.shell

import java.net.MalformedURLException
import java.net.URL

/**
 * Decides what a WebView navigation to a given URL is allowed to do.
 *
 * This enforces, on the navigation side, the same single-origin boundary
 * start-backend.sh's CORS pin already enforces on the fetch/XHR side (see
 * BackendProbe.BACKEND_ORIGIN's comment): the backend only ever talks to
 * "http://127.0.0.1:8484", so the WebView should only ever render that
 * origin. Without this, any link or redirect rendered inside the window
 * the owner trusts as ForgeHub could carry them to an attacker page asking
 * for the Runpod API key, under ForgeHub's own chrome -- a phishing attack
 * on the window, not a network attack on the backend.
 *
 * Framework-free (no android.* import) so this can be unit tested as a
 * plain JVM test -- same rationale as BackendProbe, see its own doc
 * comment -- in NavigationPolicyTest.kt.
 */
object NavigationPolicy {

    /** What [decide] says MainActivity's WebViewClient should do with a navigation. */
    sealed class Decision {
        /** Same origin as the backend -- let the WebView load it normally. */
        object LoadInWebView : Decision()

        /** A different http/https origin -- hand off to an external app (e.g. a browser). */
        object OpenExternally : Decision()

        /** Any other scheme (file:, content:, intent:, javascript:, data:, ...) -- refuse outright. */
        object Block : Decision()
    }

    /**
     * [url]'s scheme, host and port must match [BackendProbe.BACKEND_ORIGIN] exactly to
     * load inside this app's WebView. Any other `http`/`https` URL is routed to an
     * external app instead of rendering inside the trusted window. Every other scheme is
     * blocked outright -- there is no legitimate reason for ForgeHub's own frontend to
     * navigate the WebView to a `file:`/`content:`/`intent:`/`javascript:` URL, and
     * `file:`/`content:` in particular are exactly what `allowFileAccess`/
     * `allowContentAccess` being true used to let a compromised page reach.
     *
     * Unparseable input is treated the same as an unapproved scheme: blocked, not loaded
     * and not handed off anywhere.
     */
    fun decide(url: String): Decision {
        val parsed =
            try {
                URL(url)
            } catch (_: MalformedURLException) {
                return Decision.Block
            }

        val scheme = parsed.protocol.lowercase()
        if (scheme != "http" && scheme != "https") {
            return Decision.Block
        }

        return if (isBackendOrigin(parsed)) {
            Decision.LoadInWebView
        } else {
            Decision.OpenExternally
        }
    }

    private fun isBackendOrigin(parsed: URL): Boolean {
        // Re-parsed from the single source of truth on every call rather than cached,
        // because this is a handful of calls per navigation, not a hot loop, and it keeps
        // this object from being able to drift out of sync with BackendProbe.BACKEND_ORIGIN.
        val backend = URL(BackendProbe.BACKEND_ORIGIN)
        return parsed.protocol.equals(backend.protocol, ignoreCase = true) &&
            parsed.host.equals(backend.host, ignoreCase = true) &&
            effectivePort(parsed) == effectivePort(backend)
    }

    /** [URL.getPort] is -1 when the URL has no explicit port; this resolves that to the scheme's default. */
    private fun effectivePort(url: URL): Int =
        if (url.port != -1) {
            url.port
        } else {
            when (url.protocol.lowercase()) {
                "https" -> 443
                else -> 80
            }
        }
}
