import { createContext, useContext, useMemo, useState, type ReactNode } from "react";

interface StackContextValue {
  /** The stack that served this page, then the X-ShipTrack-Stack of the latest API response. */
  stack: string | null;
  setStack: (stack: string) => void;
}

const StackContext = createContext<StackContextValue | null>(null);

/**
 * The stack that served this page, read from the Server-Timing header of the document response
 * (`stack;desc="modern"`). The browser exposes it on the navigation entry, so it is known at the
 * first render, before any API call. Null when the header is absent or unreadable.
 */
export function stackFromNavigation(): string | null {
  if (typeof performance === "undefined" || typeof performance.getEntriesByType !== "function") {
    return null;
  }
  const entry = performance.getEntriesByType("navigation")[0] as
    | PerformanceNavigationTiming
    | undefined;
  const timing = entry?.serverTiming?.find((item) => item.name === "stack");
  return timing !== undefined && timing.description !== "" ? timing.description : null;
}

export function StackProvider({ children }: { children: ReactNode }) {
  const [stack, setStack] = useState<string | null>(stackFromNavigation);
  const value = useMemo(() => ({ stack, setStack }), [stack]);
  return <StackContext.Provider value={value}>{children}</StackContext.Provider>;
}

export function useStack(): StackContextValue {
  const value = useContext(StackContext);
  if (value === null) throw new Error("useStack must be used inside <StackProvider>");
  return value;
}
