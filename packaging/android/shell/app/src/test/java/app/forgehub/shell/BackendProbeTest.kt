package app.forgehub.shell

import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.SocketException
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Exercises BackendProbe.await against a real local socket, not a mock --
 * the thing under test is backoff-and-retry timing against an actual
 * connection (refused, then later accepted), which a mocked
 * HttpURLConnection cannot reproduce faithfully. Deliberately plain JUnit:
 * no Robolectric, no device, no AndroidManifest -- BackendProbe itself has
 * no android.* import, so this runs as an ordinary JVM test in well under
 * a second per case.
 *
 * The stub is a hand-rolled ServerSocket responder, not
 * com.sun.net.httpserver.HttpServer: that JDK class lives in the
 * jdk.httpserver module, which is outside the module set AGP's Kotlin unit
 * test compilation resolves against (observed directly here -- it failed
 * with "Unresolved reference: com" the first time this test was written
 * against it, not a plausible guess). A raw ServerSocket needs only
 * java.base, which is always available, and is just as faithful a stand-in
 * for "nothing listening yet, then something listening and answering 200".
 *
 * The stub binds to an OS-assigned ephemeral port (`ServerSocket(0, ...)`),
 * never BackendProbe.PORT (8484) -- that is the production backend's real
 * port, and this is the exact kind of host (the owner's own phone, or any
 * dev box) where something may genuinely be listening there already. A
 * hardcoded 8484 here would make these tests non-hermetic: a real backend
 * on 8484 would make returnsFalseWhenBackendNeverAppears see a genuine 200
 * and fail, while returnsTrueWhenBackendAppearsLate's own bind would throw
 * BindException. BackendProbe.await() takes an explicit `url` parameter
 * precisely so callers are never forced onto the default CONFIG_URL/PORT --
 * every call below passes the stub's actual ephemeral port through it.
 */
class BackendProbeTest {

    // @Volatile: written on the stub's background thread, read (for
    // cleanup) from the test thread. Without this, tearDown() could run
    // before the write becomes visible and leak a bound socket into the
    // next test.
    @Volatile
    private var stubSocket: ServerSocket? = null

    @After
    fun tearDown() {
        try {
            stubSocket?.close()
        } catch (_: IOException) {
            // Already closed or never opened -- nothing to clean up.
        }
        stubSocket = null
    }

    @Test
    fun returnsTrueWhenBackendAppearsLate() {
        // The normal cold-start case this task exists for: the owner opens
        // the app before Termux has started uvicorn. Nothing listens on
        // this port at all for the first two seconds -- a real connection
        // refusal, not a slow or erroring response -- then the stub starts
        // answering 200 on /config. await() must catch that within its
        // 10s budget.
        val port = reserveFreePort()
        startStubAfter(port = port, delayMs = 2_000)

        assertTrue(
            "await() must return true once /config starts answering, even if that" +
                " happens partway through the timeout window",
            BackendProbe.await(timeoutMs = 10_000, url = configUrl(port)),
        )
    }

    @Test
    fun returnsFalseWhenBackendNeverAppears() {
        // Nothing is ever started here -- every attempt inside the window
        // hits connection-refused. await() must resolve to a plain false,
        // not throw, and not block past its own timeout budget.
        val port = reserveFreePort()
        assertFalse(
            "await() must return false, not throw, when nothing ever answers",
            BackendProbe.await(timeoutMs = 1_000, url = configUrl(port)),
        )
    }

    private fun configUrl(port: Int): String = "http://${BackendProbe.HOST}:$port/config"

    /**
     * Binds to an OS-assigned ephemeral port, reads the port number back,
     * then immediately closes the socket -- freeing it for [startStubAfter]
     * to rebind by exact number later, or for [returnsFalseWhenBackendNeverAppears]
     * to simply never rebind. The gap between this close and any later
     * rebind is a theoretical race (another process could grab the same
     * port), but it is vanishingly unlikely in a short-lived test process
     * and is the standard way to get a guaranteed-free port number without
     * keeping a socket open the whole time.
     */
    private fun reserveFreePort(): Int =
        ServerSocket(0, 0, InetAddress.getByName(BackendProbe.HOST)).use { it.localPort }

    /** Starts a stub HTTP server on [port], answering 200 on /config, after [delayMs] of silence. */
    private fun startStubAfter(port: Int, delayMs: Long) {
        val thread = Thread {
            Thread.sleep(delayMs)
            val socket = ServerSocket(port, 0, InetAddress.getByName(BackendProbe.HOST))
            // Assigned before the accept loop starts: the probe thread can
            // connect the instant the socket is bound, and tearDown() must
            // be able to see this field by then.
            stubSocket = socket
            acceptLoop(socket)
        }
        thread.isDaemon = true
        thread.start()
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client =
                try {
                    socket.accept()
                } catch (_: SocketException) {
                    // tearDown() closed the socket -- this is the normal
                    // way the accept loop ends, not a failure.
                    return
                }
            // Handled on its own daemon thread so one client can never
            // stall the accept loop for the next -- not exercised by these
            // two tests (each makes at most a handful of requests), but
            // cheap insurance against a hang turning into a stuck test.
            Thread {
                client.use { respond(it) }
            }.apply { isDaemon = true }.start()
        }
    }

    private fun respond(client: java.net.Socket) {
        // The stub only needs to prove a 2xx arrives -- it reads and
        // discards the request line rather than parsing it, since
        // BackendProbe.await() doesn't care about anything this stub could
        // extract from it.
        client.getInputStream().bufferedReader().readLine()
        val body = "{}"
        val response =
            "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: ${body.length}\r\n" +
                "Connection: close\r\n" +
                "\r\n" +
                body
        client.getOutputStream().write(response.toByteArray())
        client.getOutputStream().flush()
    }
}
