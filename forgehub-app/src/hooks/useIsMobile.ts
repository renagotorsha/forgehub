import { useEffect, useState } from "react";

// Tailwind's `md` breakpoint (768px) — below it, the shell renders drawers
// and full-screen sheets instead of docked side panels.
const MOBILE_QUERY = "(max-width: 767px)";

function readIsMobile(): boolean {
  // SSR-safe: no window/matchMedia (e.g. a non-browser render pass) means
  // "not mobile" rather than throwing.
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return false;
  return window.matchMedia(MOBILE_QUERY).matches;
}

/**
 * True when the viewport is narrower than Tailwind's `md` breakpoint
 * (768px). Use this only for behavior a CSS class cannot express (e.g.
 * whether opening one mobile sheet should close another) — pure layout
 * should stay in `md:`/`sm:` classes instead.
 */
export function useIsMobile(): boolean {
  const [isMobile, setIsMobile] = useState(readIsMobile);

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return;
    const mql = window.matchMedia(MOBILE_QUERY);
    const onChange = () => setIsMobile(mql.matches);
    onChange();
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);

  return isMobile;
}
