# ForgeHub on Android — on-phone verification checklist

This is a **run-and-record** document, not reading material. It assumes `packaging/android/README.md`
has already been read for prerequisites/bootstrap/install/start — this file does not repeat
those commands, it only tells you what to point them at and what counts as success. Where a
step says "per the README", go run that section's command now and come back.

The checks below are ordered so a failure stops you **early**, before you've sunk setup time
into a phone that was never going to pass anyway: provenance and the rebase check first (no
phone needed, minutes), then provisioning, then the functional walkthrough, then the four
checks the final design review flagged as **only provable on a real device** — no server-side
test or code review can settle these, which is also why they get a check each instead of being
folded into "does it generally work". The brief lists the fork-rebase step later (its own Step
7); it is moved up here because it is cheap and needs no phone time at all.

Fill this in as you go. Don't check a box from memory of a previous run — every box here is for
*this* run, on *this* phone.

```
Phone model:            ______________________
Android version:        ______________________
Date tested:             ______________________
Build-host commit (git rev-parse --short HEAD):  ______________________
```

---

## 0. APK provenance (run on the build host, before touching the phone)

The APK at `packaging/android/shell/app/build/outputs/apk/release/app-release.apk` is a
gitignored build artifact — nothing about the file itself says which commit it came from. Pin
that down before sideloading anything, so a stale or wrong-branch build doesn't waste the rest
of this checklist.

**Do:**
```bash
cd /home/deploy/ForgeHub
sha256sum packaging/android/shell/app/build/outputs/apk/release/app-release.apk
```

**Expect:** the hash matches exactly:

```
0698279fe2c9bba300878af435a05a0257bbd2f1503e876803f51cb4eab36d2d  app-release.apk
```

This is the APK built from commit `f18cbc0` ("fix(android): бюджет проб догоняет 60с
backend-а, re-probe в onResume, защита от обращения к уничтоженному WebView") — the last commit
that touched `packaging/android/shell/`. That commit's own message records the build
(`:app:assembleRelease`) and signature verification (`apksigner verify`, v2 scheme) that
produced this exact file; `git diff --stat` / `git show --stat f18cbc0` confirm no shell/ source
has changed since. (The file's mtime is ~45s *before* that commit's timestamp, not after —
build-then-commit, not commit-then-build — but what matters is that the working tree under
`packaging/android/shell/` is clean against that commit, which it is.)

**If it fails (hash doesn't match):** the APK on disk is not the one this checklist was written
against. Rebuild: `cd packaging/android/shell && ./gradlew --no-daemon :app:assembleRelease`
(signed, if `FORGEHUB_RELEASE_KEYSTORE` and friends are exported — see
`make-release-keystore.sh`), re-run `sha256sum`, and treat the new hash as what you're testing —
note it here instead of the one above, along with the commit it was built from.

**Result:** PASS / FAIL — hash recorded: ______________________

---

## 1. The fork rebases cleanly (run on the build host, no phone needed)

**Do:**
```bash
cd /home/deploy/ForgeHub
git fetch upstream
git rebase upstream/main
```

**Expect:** no conflicts outside `forgehub-app/src`; any conflict that does land inside
`forgehub-app/src` is a class-string merge (two different `className` edits on the same line),
not a structural one. See the README's "Living in a fork" section for what "surgical and
additive" is supposed to mean here.

**If it fails:** a conflict outside `forgehub-app/src` means something in `packaging/android/`
collided with an upstream change, which shouldn't happen since that whole tree is new and
upstream doesn't touch it — worth understanding *why* before resolving, not just resolving it. A
structural conflict inside `forgehub-app/src` (not a class-string) means a later change broke the
"surgical and additive" rule the README commits this branch to.

**If it succeeds but you don't want to actually move `HEAD` right now:** `git rebase --abort`
after confirming no conflicts were reported, or do this check on a disposable clone/worktree.

**Result:** PASS / FAIL — conflicts (if any): ______________________

---

## 2. Provision the phone

Prerequisites, Bootstrap, and Installing sections of the README, in order. Do not skip ahead —
each later step assumes the previous one actually finished.

**Do:**
1. Install Termux, Termux:API, Termux:Boot from **F-Droid** (README "Prerequisites"). Open the
   Termux:API app once and the Termux:Boot app once — both require a manual first launch to
   grant permissions / register the boot receiver; `install.sh` cannot do this for you.
2. README "Bootstrap": clone the Termux-side checkout at `~/ForgeHub`, with
   `FORGEHUB_REPO_URL=<your fork's URL>` exported (same convention as the README — do not
   hardcode a literal URL, it isn't public).
3. README "Installing on the phone": `bash packaging/android/install.sh`.

**Expect:** `install.sh` finishes with "install.sh: provisioning complete" and prints the
`start-backend.sh` next-step hint. No FATAL lines.

**If it fails:** read the FATAL text literally — every one in `install.sh` and
`guest-provision.sh` names its own remedy. The one most likely to surprise you here specifically
is **knowable only on the phone, not from this repo**: `guest-provision.sh` pins to Python 3.12
(`REQUIRED_PYTHON_MM`), but `proot-distro install ubuntu` resolves `"ubuntu"` to whatever release
proot-distro currently calls that alias — if it has moved past 24.04 since this checklist was
written, provisioning FATALs loudly with both version numbers rather than failing deep inside
`pip install`. The README's "A note on the guest's Ubuntu version and the dependency lock"
section documents the remedy (`verify-aarch64-deps.sh --freeze` + commit the regenerated lock).
Nothing in this repo can tell you in advance whether this will trigger — it depends on what
proot-distro's package index currently serves, which changes over time independent of this
branch.

**Result:** PASS / FAIL — if FAILed on the Python/Ubuntu check, which versions did it report?
______________________

---

## 3. Start the backend

**Do:** README "Running the backend": `bash packaging/android/start-backend.sh`.

**Expect:** ends with "backend is up: http://127.0.0.1:8484/config answers" and "running (pid
…)". Along the way: `termux-wake-lock` acquired, `termux-notification` raised (check the
notification shade — an ongoing "ForgeHub backend" notification with a Stop button should be
sitting there). If `ss` is available it reports the bind as `127.0.0.1:8484` only, never
`0.0.0.0:8484`.

**If it fails:**
- `FATAL: ... already answers` — a previous instance is still running; stop it via the
  notification's Stop button or `pkill -f 'uvicorn forgehub_backend\.main:app'`, then retry.
- `FATAL: ... not found or not executable` — provisioning (step 2) didn't actually finish; go
  back to it.
- `WARNING: termux-wake-lock failed` / `WARNING: termux-notification failed` — Termux:API the
  *app* was never opened once (see step 2.1). The backend still starts, but a long job can die
  silently the moment the screen turns off. Fix this before step 10 (doze survival) — a doze
  test run without a real wake-lock will tell you nothing about the actual feature.
- `FATAL: ... listening on 0.0.0.0` — stop immediately and treat as a real security
  regression, not a checklist nit; this is the control that keeps the Runpod API key off the
  local Wi-Fi. (The backend being unauthenticated on `127.0.0.1` itself is a decision the owner
  already made and accepted — see `docs/superpowers/specs/2026-10-27-forgehub-android-design.md`
  — this is not that; this is the bind leaking past loopback entirely.)

**Result:** PASS / FAIL — wake-lock acquired? Y/N — notification visible? Y/N — bind confirmed
127.0.0.1-only? Y/N

---

## 4. Sideload and launch the APK

No script owns this step — it was explicitly left for this checklist (see
`.superpowers/sdd/forgehub-android-plan/task-5-report.md`'s "Noticed but not verified" list).

**Do:** get `app-release.apk` (the one hashed in step 0) onto the phone by whichever of these is
convenient — `adb install app-release.apk` over USB, or copy the file to the phone (cloud
storage, USB file transfer, email-to-self, etc.) and open it from a file manager — and allow
"install unknown apps" for whichever app you used to open it, if Android asks. Then tap the
**ForgeHub** home-screen icon.

**Expect:** a spinner and "Waiting for the ForgeHub backend to start…" (or, if step 3's backend
is already up, this may resolve almost immediately) — never a blank page or a raw
`ERR_CONNECTION_REFUSED`-style browser error page. Once `/config` answers, the screen swaps to
the real ForgeHub UI with no further tap needed.

**If it fails:**
- Install refused / "app not installed" — check the APK is the one from step 0 (not a stale
  debug build) and that minSdk 26 is satisfied by this phone's Android version.
- A blank page or a browser-style error page instead of the waiting screen — this means
  `MainActivity`'s retry screen (`MainActivity.kt`'s `showUnreachable()`/`WebViewClient`) isn't
  intercepting the failure the way it's supposed to; file this as a real bug, not a
  "backend's not started yet" case.
- Waiting screen never clears even though step 3 reported success — re-check step 3's bind; the
  WebView loads `http://127.0.0.1:8484` specifically (`BackendProbe.BACKEND_ORIGIN`), so anything
  that answers on a different host/port won't satisfy it.

**Result:** PASS / FAIL

---

## 5. Runpod API key and endpoint autodetection

**Do:** open Settings inside the app, paste the Runpod API key, and let it autodetect.

**Expect:** the Settings dialog reports "`N` endpoints — pick one below" (or auto-selects the
only one) listing the real Runpod Serverless endpoints on the account; the sidebar's endpoint
indicator goes from the red "not set" dot to a green one showing the chosen endpoint ID.

**If it fails:** a key that's valid but shows 0 endpoints, or a request that hangs/errors, points
at network egress from inside the proot guest (DNS/TLS to Runpod's API) rather than anything
Android-specific — check connectivity from inside the guest directly
(`proot-distro login ubuntu -- curl -sI https://api.runpod.ai`) before assuming it's a phone
problem.

**Result:** PASS / FAIL — endpoints detected: ______

---

## 6. Image job end to end

**Do:** pick any image workflow, fill in a prompt, run it.

**Expect:** job appears in the queue (state ticks from `IN_QUEUE`), status polls to completion,
the result lands at the top of the outputs gallery with a thumbnail, and tapping download on it
produces a system "Download complete" notification (don't open the file yet — the next checks
depend on that notification behaving a specific way; just confirm it fired here).

**If it fails:** a job that queues but never resolves points at `App.tsx`'s `resolveJob` /
`startPolling` (the 4s interval poller) or at the Runpod endpoint itself, not at anything
Android-only — reproduce the same workflow against the same backend from a desktop browser
pointed at `http://127.0.0.1:8484` (via `adb forward` or similar) to tell those apart before
assuming it's phone-specific.

**Result:** PASS / FAIL

---

## 7. Video job end to end

**Do:** pick a video workflow, run it.

**Expect:** the video output saves into the gallery, its thumbnail renders (this is
`ffmpeg`-generated — there is no bundled fallback, see the README's and the design doc's note
that `imageio-ffmpeg`'s desktop binary does not run on Android, so this specifically exercises
the guest's own `apt`-installed `ffmpeg`/`ffprobe`, not a vendored one), and the container
metadata is readable: `GET /outputs/meta` (the prompt-history endpoint backing the gallery) and
`GET /outputs/{filename}/meta` both return non-empty metadata for it, not a 404 "No embedded
metadata".

**Do (to actually check the metadata, not just assume it since the thumbnail rendered):** open
the output in the gallery and confirm the prompt/parameters shown for it are non-empty — the
gallery reads exactly `/outputs/meta`, so a populated info panel on this entry *is* the check.

**If it fails:** a thumbnail that never renders points at `ffmpeg`/`ffprobe` missing or not on
`PATH` inside the guest — `guest-provision.sh`'s own install block is a hard precondition here
and would normally have FATALed already in step 2 if that were true, so a failure *here specifically*
(provisioning succeeded, but this one workflow's thumbnail/metadata comes up empty) is a real bug
in `forgehub_backend/files.py`'s video path, not a provisioning gap — worth cross-checking against
the same workflow run on the Win11 desktop install before concluding it's Android-specific.

**Result:** PASS / FAIL

---

## 8. Upload parity — camera and gallery, both into `POST /upload`

**Do:** open a workflow with an image input, tap its upload control, and run it once choosing
**Camera** from the picker (capture a photo) and once choosing a gallery/file picker image —
two separate runs, not one. Confirm the uploaded image actually reaches the job's result (e.g.
an img2img-style workflow whose output visibly reflects the input you picked) for both.

**Expect:** both pickers appear in the chooser `MainActivity.onShowFileChooser` builds, both
produce a file that `POST /upload` accepts, and both uploaded images are the ones that were
actually picked (not a stale/previous capture).

**If it fails:**
- No "Camera" entry in the chooser at all — `createCameraCaptureUri()` /
  `packageManager.resolveActivity` in `MainActivity.kt` decided nothing on this phone can handle
  `ACTION_IMAGE_CAPTURE`; check whether a camera app is actually installed and set as default.
- Camera entry present but the captured photo never reaches the job — the
  `pendingCameraUri`/`FileProvider` handoff in `MainActivity.kt` (`onShowFileChooser` /
  `fileChooserLauncher`) is the thing to inspect; `res/xml/file_paths.xml` governs what
  `FileProvider` is allowed to expose.
- Gallery picker works but camera doesn't (or vice versa) — treat as two independent bugs, not
  one; they go through genuinely different code paths (`cameraUri != null` branch vs.
  `WebChromeClient.FileChooserParams.parseResult`).

**Result:** camera upload PASS / FAIL — gallery upload PASS / FAIL

---

## 9. Chat/LLM prompt-enhancer round-trip

**Do:** tap "Prompt assist" (the speech-bubble icon in the header) to open the chat drawer, send
a message asking it to improve or rewrite a prompt.

**Expect:** the model list loaded without error when the drawer opened (`GET /chat/models`), and
the round-trip returns a real, non-error assistant message with a usable rewritten prompt — not
the drawer's own rate-limit/error text (`friendlyError` in `ChatDrawer.tsx` turns a raw 429/503
into a readable message; that readable text appearing *is* a real failure here, just a
legible one).

**If it fails:** an error here almost always traces to the chosen chat model/provider in Settings
rather than anything phone-specific — same cross-check idea as step 6: reproduce against the same
backend from a desktop browser before concluding the phone is at fault.

**Result:** PASS / FAIL

---

## 10. WebView `visibilitychange` delivery — isolated, not inferred from step 12

This is one of the things the final design review called out as **provable only on a real
device**: whether Android's WebView actually fires the page's `visibilitychange` listener on
activity resume. `MainActivity` deliberately does **not** re-poll on resume itself anymore — see
its `onResume()` comment, "a JS re-poll on resume is NOT this activity's job... that moved to
Task 6 as an additive `visibilitychange` listener in the frontend" (`App.tsx`'s
`onVisibilityChange` effect). If the WebView never delivers that event, the feature is **silently
absent** — and the catch is that the end-to-end doze test in step 12 below can still *look* like
it passed, because `onResume()` also calls `webView.resumeTimers()` unconditionally, which on its
own resumes the frontend's existing 4-second `setInterval` poller (`startPolling` in `App.tsx`)
regardless of whether `visibilitychange` ever fires. A job recovering on resume therefore does
NOT by itself prove this event is delivered — it only proves *something* polls eventually.

**How to tell the difference, without a debug port** (this release build has no
`setWebContentsDebuggingEnabled`, so `chrome://inspect` is not available here):

**Do:** start a job, lock the screen for at least 15–20 seconds (long enough that the job is
still genuinely in progress), then unlock. With a stopwatch (or just counting), measure the time
from the screen becoming visible again to the job's state visibly updating in the UI (progress
text changing, or the result appearing if it finished while locked).

**Expect / how to read it:**
- **Under ~1–1.5s** (roughly just network round-trip to `getExecutionStatus`) — consistent with
  `visibilitychange` firing immediately on resume and triggering `resolveJob` directly. Feature
  present.
- **A consistent extra delay of up to ~4 seconds** before anything updates — consistent with
  `visibilitychange` **not** firing at all, and the update only arriving once the resumed
  `setInterval` poller's next natural tick happens to land. Feature silently absent, even though
  the job still resolves. Worth repeating 2–3 times to see if the delay is consistently near the
  4s ceiling (strong signal) vs. essentially random (less conclusive — could just be poller
  phase).

This check does not need to "pass" to leave the app usable — either way the job still recovers,
just with a different worst-case latency on resume. Record which pattern you saw; it is a fact
about this phone's WebView build, not a pass/fail gate for the rest of this checklist.

**Result:** fast (<1.5s, visibilitychange likely firing) / slow (~4s, visibilitychange likely
absent) / inconsistent — timings observed: ______________________

---

## 11. `DownloadManager` acceptance of `http://127.0.0.1:...8484/outputs/...`

Also flagged by the final review as **provable only on a real device**: `network_security_config.xml`
only governs *this app's own process* — once a download is enqueued, it is handed to Android's
separate `DownloadManager` system process, which is not this app and is not covered by that file.
Separately, `/outputs/{filename}` sends no `Content-Disposition` header, so it is not proven that
tapping download even reaches `MainActivity`'s `setDownloadListener` at all, rather than just
having the WebView navigate in-frame to display the raw file (since it's a type — image/video —
the WebView can render itself).

**Do:** from the outputs gallery, tap the download icon on one image output. Watch what actually
happens on screen, don't just assume success because step 6 showed a notification.

**Expect (success):** the ForgeHub UI stays exactly where it was, and shortly after a system
"Download complete" notification appears (`DownloadManager.Request`'s
`VISIBILITY_VISIBLE_NOTIFY_COMPLETED`, set in `downloadToDownloads()`). Open the Downloads app /
notification and confirm the file is really there, with a sane filename and the same byte size
as what the gallery reported.

**If it fails (the other shape this can take):** the WebView navigates away from the app to
display the raw image/video full-screen, replacing the ForgeHub UI — meaning the anchor's
`download` attribute never reached `setDownloadListener` at all; the hardware back button returns
you to the app, and **nothing lands in Downloads.** This is exactly the risk this check exists
for: `setDownloadListener`'s Javadoc contract is that it only fires for content the WebView
itself declines to render, and a `Content-Disposition`-less image/video response is squarely the
kind of content a WebView usually *can* render. If this happens, the fix is server-side
(`forgehub_backend/main.py`'s `output_proxy` would need a `Content-Disposition: attachment`
header) — which this checklist cannot apply itself, since `forgehub_backend/**` is off-limits to
this branch (see the README's "Ground rule"). Record it as a real, named gap instead.

**Result:** downloaded via DownloadManager (file in Downloads, app stayed put) / navigated
in-frame instead (file NOT in Downloads) — which one: ______________________

---

## 12. Doze survival (Review Focus 2)

**Do:** queue a long-running job (a video job, or a large batch, whatever takes the longest in
your workflow catalog), lock the screen, and actually wait — past Android's adaptive-battery doze
threshold, not just a few seconds. Several minutes with the screen off and the phone stationary
and not charging is the realistic target; shorter and you may just be re-testing step 10's resume
behaviour, not doze. Then unlock and reopen the app.

**Expect:** the job is still tracked (not silently dropped), its result is recovered into the
outputs gallery, and nothing is left orphaned (no job stuck showing `RUNNING` forever, no
duplicate entries).

**If it fails:** this is the scenario `start-backend.sh`'s wake-lock exists for — if step 3 above
showed the wake-lock warning (Termux:API never opened), this is expected to fail and isn't
informative about anything else; fix that first and re-run. If the wake-lock was genuinely held
and this still fails, suspect the guest process itself getting OOM-killed under memory pressure
during the long wait (see step 13) rather than Doze CPU suspension, since the wake-lock's whole
job is to prevent the latter.

**Also worth knowing going in, not a failure of this check specifically:** if Android kills the
*Activity* under memory pressure while it's backgrounded (not just suspends it — actually destroys
it), reopening reloads the page from scratch with no persisted job IDs (`pollers`/`jobs` in
`App.tsx` are in-memory `useState`/`useRef`, never written to `localStorage`). Resume recovery as
tested here covers a *surviving, backgrounded* page; it does not cover a page that got torn down
and rebuilt. There is no way to distinguish these two outcomes from the UI alone — if the gallery
simply doesn't show the result and the job also isn't listed as running, you cannot tell from
here whether it's a doze bug or an Activity-kill, only that the recovery didn't happen.

**Result:** PASS / FAIL — wait duration: ______ — wake-lock held throughout (notification still
present on unlock)? Y/N

---

## 13. Memory headroom (numpy + Pillow under proot)

Also only answerable on the real device — flagged in the design doc's own "Known risks" as
"small, but not zero on a modest phone," never measured.

**Do:** while the video job from step 7 (or another numpy/Pillow-heavy workflow) is running, from
a second Termux session run:
```bash
proot-distro login ubuntu -- free -h
```
once or twice during the run, and note the lowest "available" figure you see.

**Expect:** the backend survives the job without the guest process disappearing — if it dies
mid-job, `start-backend.sh`'s wrapper exits, the persistent notification disappears on its own
(not via the Stop button), and `/config` stops answering. That combination, happening
*unprompted* during a job, is the OOM signature to watch for on an unrooted phone where `dmesg`
isn't accessible.

**If it fails:** record the phone's total RAM and the lowest "available" figure observed — this
is informational for the owner's phone specifically, not something this checklist can fix; the
remedy (if it recurs) is choosing workflows / batch sizes that fit, not a code change.

**Result:** PASS / FAIL — total RAM: ______ — lowest "available" observed: ______

---

## 14. Cold start after a reboot (Review Focus 1)

**Do:** reboot the phone. Immediately after it finishes booting (don't wait for Termux:Boot to
visibly do anything), open the ForgeHub app. Time from tapping the icon to the real UI appearing.

**Expect:** the retry screen ("Waiting for the ForgeHub backend to start…"), then the UI loads on
its own, with no manual Retry tap needed, once Termux:Boot's `boot/start-forgehub.sh` has the
backend up. Compare the actual elapsed time against the budget this was tuned to:
`MainActivity.kt`'s `probeTimeoutMs` (60s) was deliberately raised to match
`start-backend.sh`'s own "polling … for up to 60s" allowance — so if the real cold start
(proot + uvicorn, right after Termux:Boot, on this specific phone) regularly takes close to or
over 60 seconds, the budget that looked generous on paper is actually tight in practice, and the
retry screen will show "isn't answering yet" and require a manual Retry even though the backend
was about to come up on its own.

**If it fails (never recovers automatically):**
- Still shows the "isn't answering yet" manual-retry text after a minute or two — check
  `~/forgehub-backend-boot.log` (where Termux:Boot output goes, per the README) for why
  `start-forgehub.sh`/`start-backend.sh` didn't come up; most likely Termux:Boot's one-time
  "open the app once" step (checklist step 2.1) was skipped, so the boot broadcast was never
  delivered at all.
- Comes up, but routinely takes noticeably longer than 60s — note the actual time; this is a
  real finding about this phone (CPU speed under proot, storage speed, however many other apps
  compete for CPU right after boot), not something any script here can fix by itself, but worth
  recording since it tells you how much of `probeTimeoutMs`'s margin is actually being used.

**Result:** PASS / FAIL — elapsed time from icon tap to UI: ______ — required manual Retry? Y/N

---

## Known going in — not re-tested here, just recorded so it isn't a surprise

- **A `SIGKILL`'d `start-backend.sh`** (as opposed to a normal stop via the notification's Stop
  button, Ctrl-C, or `TERM`) leaves the wake-lock held and the notification stuck — the cleanup
  trap only catches `EXIT`/`INT`/`TERM`, and nothing can trap `SIGKILL`. If you ever see a
  "ForgeHub backend" notification with no corresponding running process, this is why; release it
  manually with `termux-wake-unlock` and `termux-notification-remove forgehub-backend`.
- **The backend has no authentication of any kind on `127.0.0.1:8484`.** This is a known,
  recorded decision the owner already made, not an open question —
  `docs/superpowers/specs/2026-10-27-forgehub-android-design.md`'s "Accepted risk" section. What
  this checklist *did* verify (steps 3 and above) is the two things that decision depends on
  staying true: the bind is loopback-only, and CORS is pinned to the GUI's own origin rather than
  upstream's permissive default.

---

## What a clean run of this checklist does NOT settle

Even with every box above checked PASS:

- **Longevity.** One cold start, one doze cycle, one of each job type is not the same as a week
  of real use — intermittent proot/Termux flakiness, battery-optimization settings the owner
  might change later, or a different `ffmpeg` behavior on a future proot-distro Ubuntu bump are
  all out of scope for a single pass.
- **The visibilitychange and DownloadManager findings (steps 10, 11) are phone/OS-build specific.**
  A different phone, a different WebView (Chrome) version pushed by Play Services, or a future
  Android update can change either answer without anything in this repository changing. Re-run
  those two checks after any OS/WebView update, not just once.
- **The Activity-kill-under-memory-pressure gap (noted under step 12) is structural, not a bug
  with a pending fix** — nothing in this checklist exercises it directly (that would require
  reliably forcing Android to destroy a backgrounded Activity, which isn't something you can
  trigger on demand from the UI), so its real-world frequency on this phone specifically remains
  unknown after this run.
- **The `SIGKILL` wake-lock/notification leak** (above) was described, not reproduced — forcing it
  deliberately would mean killing the backend process with `-9` mid-job, which is destructive to
  whatever job happens to be running; this checklist does not require doing that.
