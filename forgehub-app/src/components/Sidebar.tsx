import clsx from "clsx";
import { Clapperboard, Image as ImageIcon, Package, Search, Sparkles, Video, X } from "lucide-react";
import { useMemo, useState } from "react";
import type { Workflow } from "../api";
import { useT } from "../i18n";

const CATEGORY_ICONS: Record<string, React.ReactNode> = {
  video: <Video size={13} />,
  image: <ImageIcon size={13} />,
  agent: <Sparkles size={13} />,
  audio: <Clapperboard size={13} />,
  other: <Package size={13} />,
};

interface Props {
  workflows: Workflow[];
  selectedId: string;
  onSelect: (id: string) => void;
  endpointId: string;
  // Mobile drawer state — optional, so existing call sites render exactly as
  // before (docked sidebar, no drawer behavior) when they don't pass these.
  mobileOpen?: boolean;
  onMobileClose?: () => void;
}

export default function Sidebar({ workflows, selectedId, onSelect, endpointId, mobileOpen = false, onMobileClose }: Props) {
  const t = useT();
  const [query, setQuery] = useState("");
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return workflows;
    return workflows.filter((w) =>
      `${w.name} ${w.category} ${(w.tags || []).join(" ")}`.toLowerCase().includes(q),
    );
  }, [workflows, query]);

  const grouped = useMemo(() => {
    const g: Record<string, Workflow[]> = {};
    for (const w of filtered) (g[w.category || "other"] ||= []).push(w);
    return g;
  }, [filtered]);

  return (
    <aside
      data-testid="sidebar"
      className={clsx(
        "fixed inset-y-0 left-0 z-50 flex w-[290px] max-w-[85vw] shrink-0 flex-col border-r border-border bg-bg-elev shadow-[var(--shadow-pop)] md:static md:z-auto md:w-[290px] md:max-w-none md:bg-bg-elev/70 md:shadow-none",
        mobileOpen ? "translate-x-0" : "-translate-x-full md:translate-x-0",
      )}
    >
      <div className="border-b border-border px-4 py-4">
        <div className="flex items-center gap-2.5">
          <img
            src="./logo.png"
            alt="ForgeHub"
            className="h-9 w-9 rounded-xl object-cover ring-1 ring-border-strong shadow-[0_0_16px_rgb(124_92_255/0.15)]"
          />
          <div>
            <div className="bg-gradient-to-r from-text to-accent-hover bg-clip-text text-[15px] font-bold tracking-tight text-transparent">
              ForgeHub
            </div>
            <div className="text-[11px] tracking-wide text-faint">{t.tagline}</div>
          </div>
          {onMobileClose && (
            <button
              data-testid="sidebar-close"
              onClick={onMobileClose}
              title="Close"
              className="ml-auto rounded-md p-1.5 text-muted transition-colors hover:bg-panel-hover hover:text-text md:hidden"
            >
              <X size={16} />
            </button>
          )}
        </div>
        <div className="relative mt-4">
          <Search size={13} className="absolute left-2.5 top-1/2 -translate-y-1/2 text-faint" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t.searchWorkflows}
            className="w-full rounded-lg border border-border bg-panel py-1.5 pl-8 pr-3 text-[12px] text-text outline-none transition-all placeholder:text-faint hover:border-border-strong focus:border-accent/70 focus:shadow-[var(--shadow-glow)]"
          />
        </div>
      </div>

      <div className="flex-1 overflow-y-auto p-2">
        {Object.entries(grouped).map(([cat, list]) => (
          <div key={cat} className="mb-3">
            <div className="flex items-center gap-1.5 px-2 py-1.5 text-[10px] font-semibold uppercase tracking-[0.1em] text-faint">
              {CATEGORY_ICONS[cat] ?? CATEGORY_ICONS.other}
              {(t.categories as Record<string, string>)[cat] ?? cat}
              <span className="ml-auto rounded-md border border-border bg-panel px-1.5 text-[10px] text-muted">
                {list.length}
              </span>
            </div>
            {list.map((w) => (
              <button
                key={w.id}
                data-testid="workflow-item"
                data-workflow-id={w.id}
                onClick={() => onSelect(w.id)}
                className={clsx(
                  "relative mb-0.5 w-full rounded-lg px-3 py-2 text-left transition-all duration-150",
                  w.id === selectedId
                    ? "bg-accent/12 text-text shadow-[inset_0_1px_0_rgb(255_255_255/0.04)] ring-1 ring-accent/50"
                    : "text-muted hover:bg-panel-hover hover:text-text",
                )}
              >
                {w.id === selectedId && (
                  <span className="absolute left-0 top-1/2 h-5 w-[3px] -translate-y-1/2 rounded-full bg-gradient-to-b from-accent-hover to-magenta shadow-[0_0_8px_rgb(124_92_255/0.6)]" />
                )}
                <div className="text-[13px] font-medium leading-tight">{w.name}</div>
                {w.description && (
                  <div className="mt-0.5 line-clamp-1 text-[11px] text-faint">{w.description}</div>
                )}
              </button>
            ))}
          </div>
        ))}
        {filtered.length === 0 && (
          <div className="px-3 py-8 text-center text-[12px] text-faint">{t.noWorkflows}</div>
        )}
      </div>

      <div className="border-t border-border px-4 py-3">
        <div className="flex items-center gap-2 rounded-lg border border-border bg-panel px-3 py-2 text-[11px]">
          <span className={clsx(
            "h-1.5 w-1.5 shrink-0 rounded-full",
            endpointId ? "bg-success shadow-[0_0_8px_rgb(52_211_153/0.6)]" : "bg-danger shadow-[0_0_8px_rgb(255_92_108/0.6)]",
          )} />
          <span className="shrink-0 text-faint">endpoint</span>
          <span className="truncate font-mono text-muted">{endpointId || "not set"}</span>
        </div>
      </div>
    </aside>
  );
}
