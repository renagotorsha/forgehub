import { useLayoutEffect } from "react";

// Published on the document root so any component can read it with a plain
// CSS `var(--fh-header-h)` — no prop drilling needed for OutputsGallery and
// ChatDrawer, which are siblings of the header in the tree, not descendants.
const CSS_VAR = "--fh-header-h";

/**
 * Keeps `--fh-header-h` on the document root in sync with the header's own
 * rendered height, via ResizeObserver.
 *
 * Why not a hardcoded pixel offset: the header's height is content-driven
 * (it grows a second line when the selected workflow has a `description`,
 * shrinks back to one line for the "Select a workflow" placeholder, and
 * shifts with font-size/i18n-string-length changes) — a fixed number would
 * either clip the header or leave a gap above the mobile sheets and would
 * silently go stale the next time the header's padding/typography changes.
 * Measuring it live is the robust option and was practical here because the
 * header is a single, already-ref-able DOM node with no server-rendering
 * step to worry about.
 */
export function useHeaderHeightVar(ref: React.RefObject<HTMLElement>) {
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const publish = () => {
      document.documentElement.style.setProperty(CSS_VAR, `${el.offsetHeight}px`);
    };
    publish();
    const ro = new ResizeObserver(publish);
    ro.observe(el);
    return () => ro.disconnect();
  }, [ref]);
}
