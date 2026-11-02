// Task 6 — responsive layout, additive only.
//
// Run against the backend serving the built frontend on 127.0.0.1:8484 (the
// same host:port the phone build uses), e.g.:
//
//   FORGEHUB_WORKFLOW_DIR=$(pwd)/../workflows \
//   FORGEHUB_BUNDLED_WILDCARDS=$(pwd)/../wildcards \
//   FORGEHUB_FRONTEND_DIR=$(pwd)/dist \
//   ../.venv/bin/python -m uvicorn forgehub_backend.main:app --host 127.0.0.1 --port 8484
//
// Then from forgehub-app/: npx playwright test tests/layout.spec.ts
//
// @playwright/test is intentionally NOT added to package.json (see Task 6
// report for why) — install it ad hoc with
// `npm install --no-save --no-package-lock @playwright/test` and
// `npx playwright install chromium` before running this file.
import { expect, test } from "@playwright/test";

const BASE_URL = process.env.FORGEHUB_TEST_BASE_URL ?? "http://127.0.0.1:8484";

// A real workflow with the most parameters in this repo's fixtures and an
// explicitly wildcard-driven prompt — stands in for "Review Focus 5" (a
// long, wildcard-heavy recipe) without hardcoding a workflow name that
// doesn't exist in workflows/*.meta.json.
const WILDCARD_HEAVY_WORKFLOW_ID = "pimpmypony-hiresfix-facedet";

async function waitForAppReady(page: import("@playwright/test").Page) {
  await page.goto(BASE_URL);
  // Deliberately independent of any data-testid: this helper also runs
  // against the pre-Task-6 DOM (see the stash-based "before" run in the
  // Task 6 report), which doesn't have those attributes yet. The header
  // title swapping away from the hardcoded "Select a workflow" placeholder
  // is a reliable "workflows have loaded" signal in both the old and new
  // markup, independent of viewport chrome.
  await expect(page.locator("header")).not.toContainText("Select a workflow", { timeout: 15000 });
}

test.describe("mobile viewport (390x844)", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("sidebar is off-canvas until the drawer trigger is tapped", async ({ page }) => {
    await waitForAppReady(page);

    const trigger = page.getByTestId("sidebar-trigger");
    const sidebar = page.getByTestId("sidebar");

    await expect(trigger).toBeVisible();

    // Off-canvas: translated fully out of the 390px-wide viewport, not just
    // styled differently. A bounding box fully to the left of x=0 proves it
    // isn't occupying layout space a phone user could see or tap into.
    const closedBox = await sidebar.boundingBox();
    expect(closedBox).not.toBeNull();
    expect(closedBox!.x + closedBox!.width).toBeLessThanOrEqual(0);

    await trigger.click();

    const openBox = await sidebar.boundingBox();
    expect(openBox).not.toBeNull();
    expect(openBox!.x).toBe(0);
    await expect(sidebar.getByTestId("workflow-item").first()).toBeVisible();

    await page.getByTestId("sidebar-close").click();
    const reclosedBox = await sidebar.boundingBox();
    expect(reclosedBox!.x + reclosedBox!.width).toBeLessThanOrEqual(0);
  });

  test("preview column is not in the document flow", async ({ page }) => {
    await waitForAppReady(page);
    // `hidden` (display:none) below `xl` — absent from layout entirely,
    // not merely scrolled off-screen.
    await expect(page.getByTestId("preview-column")).toBeHidden();
  });

  test("execute button stays visible without scrolling on a long, wildcard-heavy workflow", async ({ page }) => {
    await waitForAppReady(page);

    await page.getByTestId("sidebar-trigger").click();
    await page.getByTestId("sidebar").locator('input[type="text"], input:not([type])').first().fill("PimpMyPony");
    const item = page.locator(`[data-testid="workflow-item"][data-workflow-id="${WILDCARD_HEAVY_WORKFLOW_ID}"]`);
    await item.click();
    await page.getByTestId("sidebar-close").click();

    // The selected recipe has 18 parameters across 4 sections — tall enough
    // that, pre-fix, the header (and its execute button) would require a
    // horizontal scroll to reach because the always-on 290px sidebar left no
    // room for it on a 390px-wide screen.
    const button = page.getByTestId("execute-button");
    await expect(button).toBeVisible();
    const box = await button.boundingBox();
    const viewport = page.viewportSize()!;
    expect(box).not.toBeNull();
    expect(box!.x).toBeGreaterThanOrEqual(0);
    expect(box!.x + box!.width).toBeLessThanOrEqual(viewport.width);
    expect(box!.y).toBeGreaterThanOrEqual(0);
    expect(box!.y + box!.height).toBeLessThanOrEqual(viewport.height);
  });

  test("OutputsGallery occupies the full viewport below the header when opened", async ({ page }) => {
    await waitForAppReady(page);
    // Measured, not hardcoded — mirrors how the component itself positions
    // the sheet (var(--fh-header-h), set from the header's real rendered
    // height). The sheet deliberately stops short of the header now (see
    // the header/sheet mutual-occlusion fix below): it covers the rest of
    // the viewport, not the header's own strip.
    const headerBox = (await page.locator("header").boundingBox())!;
    const headerBottom = headerBox.y + headerBox.height;

    await page.getByTestId("gallery-trigger").click();
    const panel = page.getByTestId("gallery-panel");
    await expect(panel).toBeVisible();
    const box = (await panel.boundingBox())!;
    const viewport = page.viewportSize()!;
    // CSS `top: var(--fh-header-h)` is set from the header's integer
    // offsetHeight, while boundingBox() comes from getBoundingClientRect(),
    // which can report fractional sub-pixel values — a <1px gap here is a
    // rounding artifact of comparing those two APIs, not a layout bug.
    expect(box.x).toBe(0);
    expect(box.y).toBeGreaterThanOrEqual(headerBottom - 1);
    expect(box.y).toBeLessThanOrEqual(headerBottom + 1);
    expect(box.width).toBe(viewport.width);
    expect(box.y + box.height).toBeGreaterThanOrEqual(viewport.height - 1);
    expect(box.y + box.height).toBeLessThanOrEqual(viewport.height + 1);
  });

  test("SettingsDialog occupies the full viewport when opened", async ({ page }) => {
    await waitForAppReady(page);
    await page.getByTestId("settings-trigger").click();
    const panel = page.getByTestId("settings-panel");
    await expect(panel).toBeVisible();
    const box = await panel.boundingBox();
    const viewport = page.viewportSize()!;
    expect(box).toMatchObject({ x: 0, y: 0, width: viewport.width, height: viewport.height });
  });

  test("opening the chat sheet closes an open gallery sheet (mobile-only exclusivity)", async ({ page }) => {
    await waitForAppReady(page);
    await page.getByTestId("gallery-trigger").click();
    await expect(page.getByTestId("gallery-panel")).toBeVisible();

    // Real pointer click, same as a finger on the phone. The sheet now
    // occupies only the area below the header (see the header/sheet
    // mutual-occlusion fix below), so the header's other trigger is never
    // covered by it in either direction and a genuine click reaches it —
    // this is the only input method the owner has; there is no keyboard.
    await page.getByTestId("chat-trigger").click();
    await expect(page.getByTestId("chat-panel")).toBeVisible();
    // Behavioral branch useIsMobile exists for: on mobile two full-screen
    // sheets stacking is a dead end (the one underneath becomes
    // unreachable), so opening one must close the other. A CSS class alone
    // can't express "close a different piece of state."
    await expect(page.getByTestId("gallery-panel")).toBeHidden();
  });

  test("opening the gallery sheet closes an open chat sheet (mobile-only exclusivity)", async ({ page }) => {
    await waitForAppReady(page);
    await page.getByTestId("chat-trigger").click();
    await expect(page.getByTestId("chat-panel")).toBeVisible();

    // See the sibling test above — real pointer click, reachable because
    // the open sheet stops above the header's bottom edge.
    await page.getByTestId("gallery-trigger").click();
    await expect(page.getByTestId("gallery-panel")).toBeVisible();
    // Mirrors the case above: the same isMobile branch exists in the
    // gallery trigger's onClick. Assert the decision — that chat becomes
    // hidden as a result of opening the gallery — not merely that the
    // gallery appeared.
    await expect(page.getByTestId("chat-panel")).toBeHidden();
  });

  // Final-review item 1 (round 1): the header previously painted over the
  // top strip of both full-screen sheets (header z-40 vs sheet z-30),
  // hiding each sheet's own title row — including its close (X) button
  // and, for the gallery, the select-multiple/delete controls — behind the
  // header. Final-review item 1 (round 2, this fix): raising the sheets to
  // z-50 solved that but created the mirror-image bug — the sheet then
  // painted over the header's own trigger buttons while open. Every
  // assertion above this point only proves an element is *present*
  // (`toBeVisible()`) or correctly *sized* (`boundingBox()`); neither one
  // models paint order, so neither bug could have been caught by them. This
  // is the assertion that closes both blind spots: it checks what a real
  // finger/pointer actually hits at the element's own centre point, via the
  // same elementFromPoint hit-test the browser itself uses to decide what
  // receives a click — the only reliable way to tell "visible" apart from
  // "visible but painted over by something else". Used below in both
  // directions: the sheet's own controls (gallery-close/chat-close) and the
  // header's triggers (gallery-trigger/chat-trigger) while a sheet is open.
  async function expectHittable(page: import("@playwright/test").Page, testId: string) {
    const el = page.getByTestId(testId);
    await expect(el).toBeVisible();
    const hit = await el.evaluate((node) => {
      const r = node.getBoundingClientRect();
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      const topmost = document.elementFromPoint(cx, cy);
      return topmost === node || !!topmost?.contains(node) || !!node.contains(topmost);
    });
    expect(hit, `${testId} is covered by another element at its own centre point`).toBe(true);
  }

  test("gallery sheet's close button is hittable, not just present, with the header behind it", async ({ page }) => {
    await waitForAppReady(page);
    await page.getByTestId("gallery-trigger").click();
    await expect(page.getByTestId("gallery-panel")).toBeVisible();
    await expectHittable(page, "gallery-close");
  });

  test("chat sheet's close button is hittable, not just present, with the header behind it", async ({ page }) => {
    await waitForAppReady(page);
    await page.getByTestId("chat-trigger").click();
    await expect(page.getByTestId("chat-panel")).toBeVisible();
    await expectHittable(page, "chat-close");
  });

  // Final-review item 1 (round 2) — the mirror-image direction: with a
  // sheet open, the header's OTHER trigger must remain hittable too. This
  // is what the round-1 fix (z-30 → z-50) broke, and what this round's
  // layout fix (sheet stops below the header instead of overlapping it)
  // restores — proven here the same way as the sheet-side case above, not
  // just by the exclusivity tests passing via a real click.
  test("header's chat trigger stays hittable, not just present, with the gallery sheet open", async ({ page }) => {
    await waitForAppReady(page);
    await page.getByTestId("gallery-trigger").click();
    await expect(page.getByTestId("gallery-panel")).toBeVisible();
    await expectHittable(page, "chat-trigger");
  });

  test("header's gallery trigger stays hittable, not just present, with the chat sheet open", async ({ page }) => {
    await waitForAppReady(page);
    await page.getByTestId("chat-trigger").click();
    await expect(page.getByTestId("chat-panel")).toBeVisible();
    await expectHittable(page, "gallery-trigger");
  });
});

test.describe("desktop reference (1920x1080)", () => {
  test.use({ viewport: { width: 1920, height: 1080 } });

  test("xl+ rendering matches the pre-Task-6 reference screenshot", async ({ page }) => {
    await waitForAppReady(page);
    await page.waitForLoadState("networkidle");
    await expect(page).toHaveScreenshot("reference-1920.png", {
      fullPage: false,
      animations: "disabled",
      caret: "hide",
    });
  });
});
