package app.forgehub.shell

import android.annotation.SuppressLint
import android.app.Activity
import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.Gravity
import android.view.View
import android.webkit.URLUtil
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.addCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The whole UI of the ForgeHub shell: a WebView loading the backend's own
 * origin, and a retry screen shown until [BackendProbe] confirms that
 * origin is actually answering.
 *
 * Deliberately built in code, not an XML layout -- this activity has one
 * job and three views; a layout resource would just be one more file that
 * could get out of sync with the code that inflates it.
 */
class MainActivity : AppCompatActivity() {

    // Cold start on the owner's own phone means: open the app, THEN go
    // start Termux. 15s covers a `start-backend.sh` that was already
    // running or started moments before; it is not meant to cover someone
    // who hasn't touched Termux yet at all -- that case lands on
    // showUnreachable(), with the manual Retry button for exactly that
    // "I just started it, give it a second longer" situation (controller
    // ruling 2: a plain wait-and-retry state, never a WebView error page).
    private val probeTimeoutMs: Long = 15_000L

    private lateinit var rootView: FrameLayout
    private lateinit var webView: WebView
    private lateinit var retryContainer: LinearLayout
    private lateinit var statusText: TextView
    private lateinit var retryButton: Button
    private lateinit var progressBar: ProgressBar

    // Executor rather than a bare Thread per attempt: BackendProbe.await()
    // blocks for up to probeTimeoutMs, and this keeps at most one such
    // block in flight (the Retry button is hidden while one is running --
    // see showWaiting()), so a single-thread pool is already serial by
    // construction, not just by convention.
    private val probeExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // WebChromeClient.onShowFileChooser's callback, held between the call
    // that opens the picker and the ActivityResult that reports what was
    // picked -- the two happen on different turns of the main loop, so
    // there is no other place to carry it.
    private var pendingFileChooserCallback: ValueCallback<Array<Uri>>? = null

    // ACTION_IMAGE_CAPTURE returns no data Intent of its own on success --
    // the only way back to the file it wrote is the Uri this activity
    // handed it ahead of time. Cleared as soon as it's consumed (success
    // or not) so a later gallery-only pick can't be mistaken for a camera
    // result.
    private var pendingCameraUri: Uri? = null

    private val fileChooserLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
            val callback = pendingFileChooserCallback
            pendingFileChooserCallback = null
            val cameraUri = pendingCameraUri
            pendingCameraUri = null

            if (callback == null) return@registerForActivityResult

            val data = result.data
            val uris: Array<Uri>? =
                when {
                    result.resultCode != Activity.RESULT_OK -> null
                    // Gallery / document picker: a real result Intent came back.
                    data != null -> WebChromeClient.FileChooserParams.parseResult(result.resultCode, data)
                    // Camera: RESULT_OK with no data Intent means the capture
                    // at cameraUri succeeded -- that Uri is the only result.
                    cameraUri != null -> arrayOf(cameraUri)
                    else -> null
                }
            callback.onReceiveValue(uris)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildViews()
        setContentView(rootView)

        onBackPressedDispatcher.addCallback(this) {
            if (webView.canGoBack()) {
                webView.goBack()
            } else {
                isEnabled = false
                onBackPressedDispatcher.onBackPressed()
            }
        }

        startProbe(isInitialAttempt = true)
    }

    override fun onResume() {
        super.onResume()
        // Controller ruling 3: a JS re-poll on resume is NOT this
        // activity's job -- that moved to Task 6 as an additive
        // `visibilitychange` listener in the frontend itself, because no
        // such entry point existed to call into from here. All this does
        // is undo whatever onPause() below suspended, so the WebView isn't
        // left frozen (stopped rendering, stopped JS timers) after the
        // owner switches back to the app -- a prerequisite for that
        // frontend-side listener ever getting a chance to run at all.
        if (::webView.isInitialized) {
            webView.onResume()
            webView.resumeTimers()
        }
    }

    override fun onPause() {
        if (::webView.isInitialized) {
            webView.onPause()
            webView.pauseTimers()
        }
        super.onPause()
    }

    override fun onDestroy() {
        probeExecutor.shutdownNow()
        if (::webView.isInitialized) {
            webView.destroy()
        }
        super.onDestroy()
    }

    // ---- view construction -------------------------------------------------

    private fun buildViews() {
        webView =
            WebView(this).apply {
                layoutParams =
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                    )
                visibility = View.GONE
            }
        configureWebView(webView)

        progressBar =
            ProgressBar(this).apply {
                layoutParams =
                    LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    )
            }

        statusText =
            TextView(this).apply {
                textSize = 16f
                gravity = Gravity.CENTER
                val padding = dp(24)
                setPadding(padding, dp(16), padding, dp(16))
            }

        retryButton =
            Button(this).apply {
                text = "Retry"
                visibility = View.GONE
                setOnClickListener { startProbe(isInitialAttempt = false) }
            }

        retryContainer =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                layoutParams =
                    FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT,
                    )
                addView(progressBar)
                addView(statusText)
                addView(retryButton)
            }

        rootView =
            FrameLayout(this).apply {
                addView(webView)
                addView(retryContainer)
            }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    // ---- WebView configuration ---------------------------------------------

    @SuppressLint("SetJavaScriptEnabled")
    private fun configureWebView(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // Neither is needed for anything this app does: the frontend's
            // upload picker goes through WebChromeClient.onShowFileChooser
            // plus a system Intent (see onShowFileChooser below), which is
            // governed by the OS's normal document-picker/FileProvider
            // permissions, not by these two settings -- those two only
            // control whether the WebView may itself *load* file:/content:
            // URLs as navigation targets. Leaving them on would let a
            // compromised or phished page inside the WebView read local
            // files via a file:/content: URL; shouldOverrideUrlLoading
            // below also blocks those schemes outright as a second layer.
            allowFileAccess = false
            allowContentAccess = false
        }

        view.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest,
                ): Boolean {
                    // Enforces the same single-origin boundary
                    // start-backend.sh's CORS pin enforces on the fetch/XHR
                    // side (see BackendProbe.BACKEND_ORIGIN's comment) --
                    // here, for navigation. Without this, any link or
                    // redirect inside the page could carry the owner to a
                    // phishing page asking for the Runpod API key, rendered
                    // inside the window they trust as ForgeHub.
                    return when (NavigationPolicy.decide(request.url.toString())) {
                        // false = "didn't override it" = the WebView proceeds
                        // with its own normal load, exactly as if this
                        // override didn't exist. This is also what keeps
                        // the initial showWebView() -> loadUrl(BACKEND_ORIGIN)
                        // call working: that origin always decides to
                        // LoadInWebView here.
                        NavigationPolicy.Decision.LoadInWebView -> false
                        NavigationPolicy.Decision.OpenExternally -> {
                            openExternally(request.url)
                            true
                        }
                        // true = "overridden, do nothing" -- the WebView's
                        // current page stays exactly where it was.
                        NavigationPolicy.Decision.Block -> true
                    }
                }

                override fun onReceivedError(
                    view: WebView,
                    request: WebResourceRequest,
                    error: WebResourceError,
                ) {
                    // Controller ruling 2: never let the WebView's own
                    // error page (blank page / ERR_CONNECTION_REFUSED) show.
                    // Only the main-frame navigation matters here --
                    // sub-resource failures (a missing favicon, etc.) don't
                    // mean the backend is down and must not throw the
                    // owner back to the retry screen.
                    if (request.isForMainFrame) {
                        showUnreachable()
                    }
                }

                override fun onReceivedHttpError(
                    view: WebView,
                    request: WebResourceRequest,
                    errorResponse: WebResourceResponse,
                ) {
                    // A 4xx/5xx is a real response from a live backend, not
                    // the "nothing is listening" case the retry screen
                    // exists for -- leave whatever the page rendered on
                    // screen, same as a desktop browser would.
                }
            }

        view.webChromeClient =
            object : WebChromeClient() {
                override fun onShowFileChooser(
                    webView: WebView?,
                    filePathCallback: ValueCallback<Array<Uri>>?,
                    fileChooserParams: FileChooserParams?,
                ): Boolean = this@MainActivity.onShowFileChooser(filePathCallback)
            }

        view.setDownloadListener { url, userAgent, contentDisposition, mimeType, _ ->
            downloadToDownloads(url, userAgent, contentDisposition, mimeType)
        }
    }

    /**
     * Hands an http/https URL that is NOT the backend's own origin to whatever app the
     * OS resolves ACTION_VIEW to (normally the system browser), instead of ever
     * rendering it inside this app's WebView. If nothing can handle it (no browser
     * installed), the navigation is simply dropped -- there is no sane in-app fallback
     * for a URL this app has already decided not to show itself.
     */
    private fun openExternally(uri: Uri) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (_: ActivityNotFoundException) {
            // Nothing installed can view it -- dropped, not loaded in the WebView.
        }
    }

    /** Camera + gallery file chooser backing `<input type=file>` in the frontend. */
    private fun onShowFileChooser(filePathCallback: ValueCallback<Array<Uri>>?): Boolean {
        // A second picker opened before the first resolved: answer the
        // stale one with "nothing selected" rather than leak it forever.
        pendingFileChooserCallback?.onReceiveValue(null)
        pendingFileChooserCallback = filePathCallback
        pendingCameraUri = null

        val initialIntents = mutableListOf<Intent>()
        val cameraUri =
            try {
                createCameraCaptureUri()
            } catch (_: IOException) {
                null
            }
        if (cameraUri != null) {
            val captureIntent =
                Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                    putExtra(MediaStore.EXTRA_OUTPUT, cameraUri)
                    addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                }
            // Only offered if something can actually handle it -- an
            // unresolvable intent in EXTRA_INITIAL_INTENTS would make the
            // chooser show a dead "Camera" entry instead of just omitting it.
            if (packageManager.resolveActivity(captureIntent, PackageManager.MATCH_DEFAULT_ONLY) != null) {
                initialIntents += captureIntent
                pendingCameraUri = cameraUri
            }
        }

        val galleryIntent =
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "*/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }

        val chooser =
            Intent.createChooser(galleryIntent, "Choose a file for ForgeHub").apply {
                if (initialIntents.isNotEmpty()) {
                    putExtra(Intent.EXTRA_INITIAL_INTENTS, initialIntents.toTypedArray())
                }
            }

        return try {
            fileChooserLauncher.launch(chooser)
            true
        } catch (_: ActivityNotFoundException) {
            pendingFileChooserCallback = null
            pendingCameraUri = null
            filePathCallback?.onReceiveValue(null)
            false
        }
    }

    private fun createCameraCaptureUri(): Uri {
        // cache-path, matching res/xml/file_paths.xml: these are scratch
        // files with the OS's cache lifetime, not the real copy -- that one
        // is whatever the frontend does with the upload once the WebView
        // hands it over.
        val dir = File(cacheDir, "camera-captures").apply { mkdirs() }
        val file = File(dir, "capture-${System.currentTimeMillis()}.jpg")
        return FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
    }

    private fun downloadToDownloads(
        url: String,
        userAgent: String,
        contentDisposition: String,
        mimeType: String,
    ) {
        val request =
            DownloadManager.Request(Uri.parse(url))
                .setMimeType(mimeType)
                .addRequestHeader("User-Agent", userAgent)
                .setDestinationInExternalPublicDir(
                    Environment.DIRECTORY_DOWNLOADS,
                    URLUtil.guessFileName(url, contentDisposition, mimeType),
                )
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
        val downloadManager = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
        downloadManager.enqueue(request)
    }

    // ---- backend probe / retry screen --------------------------------------

    private fun startProbe(isInitialAttempt: Boolean) {
        showWaiting(isInitialAttempt)
        probeExecutor.execute {
            // BackendProbe.await() does real network I/O -- it must not run
            // on the main thread (NetworkOnMainThreadException), hence this
            // executor and the post back below.
            val isUp = BackendProbe.await(timeoutMs = probeTimeoutMs)
            mainHandler.post {
                if (isUp) showWebView() else showUnreachable()
            }
        }
    }

    private fun showWaiting(isInitialAttempt: Boolean) {
        webView.visibility = View.GONE
        retryContainer.visibility = View.VISIBLE
        progressBar.visibility = View.VISIBLE
        retryButton.visibility = View.GONE
        statusText.text =
            if (isInitialAttempt) {
                "Waiting for the ForgeHub backend to start…"
            } else {
                "Checking again…"
            }
    }

    private fun showUnreachable() {
        webView.visibility = View.GONE
        retryContainer.visibility = View.VISIBLE
        progressBar.visibility = View.GONE
        retryButton.visibility = View.VISIBLE
        // Controller ruling 2: plain words, not a technical error -- the
        // owner opening this before Termux is up is the NORMAL case, not a
        // fault, and the fix is always the same two steps.
        statusText.text =
            "ForgeHub's backend isn't answering yet.\n\n" +
                "Open Termux and run start-backend.sh (or check its notification " +
                "if you think it's already running), then tap Retry."
    }

    private fun showWebView() {
        retryContainer.visibility = View.GONE
        webView.visibility = View.VISIBLE
        // BackendProbe.BACKEND_ORIGIN, not a literal string: it is defined
        // once, at "http://127.0.0.1:8484" (see BackendProbe.kt's comment
        // on HOST for the full reasoning -- 127.0.0.1, never "localhost",
        // because start-backend.sh's CORS origin is pinned to the former).
        // Reusing the constant instead of repeating the literal here means
        // the probe and the page the WebView actually loads can never
        // silently drift apart.
        webView.loadUrl(BackendProbe.BACKEND_ORIGIN)
    }
}
