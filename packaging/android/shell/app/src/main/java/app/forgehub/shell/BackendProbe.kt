package app.forgehub.shell

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Polls the backend's `/config` endpoint until it answers 2xx or a
 * deadline is reached. Used by [MainActivity] to decide when it is safe
 * to load the WebView instead of showing the retry screen -- "safe" here
 * means "a GET actually got a 2xx back", not merely "a socket connected",
 * since a server can briefly accept connections before it has any routes
 * registered.
 *
 * Deliberately framework-free (no android.* import): correctness is
 * exercised by BackendProbeTest.kt as a plain JVM unit test, with no
 * Robolectric/instrumentation and no device required -- a stub socket on
 * the host is enough to prove the backoff-and-retry logic and the "late
 * arrival" case the cold-start retry screen exists for.
 */
object BackendProbe {

    // Controller ruling 2 (also see MainActivity, which loads this same
    // origin in the WebView): 127.0.0.1, never "localhost". Those are two
    // different origins to a browser engine's same-origin checks, and
    // start-backend.sh pins FORGEHUB_CORS_ORIGINS to
    // "http://127.0.0.1:${PORT}" exactly (see its CORS_ORIGINS comment).
    // Spelling this "localhost" would make every request this probe (and
    // the WebView) makes cross-origin from the backend's point of view and
    // get refused by its CORS middleware -- the app would open and then
    // silently fail to work, with the cause hidden in a URL spelling
    // nobody thinks to check twice. Do not "tidy" this to localhost.
    const val HOST = "127.0.0.1"
    const val PORT = 8484
    const val BACKEND_ORIGIN = "http://$HOST:$PORT"
    const val CONFIG_URL = "$BACKEND_ORIGIN/config"

    private const val CONNECT_TIMEOUT_MS = 1_000
    private const val READ_TIMEOUT_MS = 1_000
    private const val INITIAL_BACKOFF_MS = 200L
    private const val MAX_BACKOFF_MS = 1_500L

    /**
     * Polls [url] (default: this backend's own `/config`) on a backoff
     * until it answers 2xx or [timeoutMs] elapses. Never throws -- every
     * failure mode (connection refused because nothing is listening yet, a
     * read/connect timeout, a non-2xx status) is treated the same way:
     * "not up yet, try again", right up until the deadline, where it
     * resolves to a plain `false` rather than propagating anything to the
     * caller. Callers (MainActivity) run this on a background thread and
     * rely on that contract to never need a try/catch of their own.
     */
    fun await(timeoutMs: Long, url: String = CONFIG_URL): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        var backoff = INITIAL_BACKOFF_MS
        while (true) {
            if (probeOnce(url)) return true

            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) return false

            val sleepMs = minOf(backoff, remaining)
            try {
                Thread.sleep(sleepMs)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
            backoff = minOf(backoff * 2, MAX_BACKOFF_MS)
        }
    }

    private fun probeOnce(url: String): Boolean {
        var connection: HttpURLConnection? = null
        return try {
            connection =
                (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = CONNECT_TIMEOUT_MS
                    readTimeout = READ_TIMEOUT_MS
                }
            connection.responseCode in 200..299
        } catch (_: IOException) {
            // The expected case before the backend has started:
            // connection refused. Not an error worth surfacing -- it is
            // exactly the signal this loop exists to wait out.
            false
        } catch (_: Exception) {
            // Anything else must not escape this loop either -- "never
            // throws" is part of the contract described above.
            false
        } finally {
            connection?.disconnect()
        }
    }
}
