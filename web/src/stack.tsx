import { createContext, useContext, useMemo, useState, type ReactNode } from "react";

interface StackContextValue {
  /** The X-ShipTrack-Stack value from the most recent API response, or null before any. */
  stack: string | null;
  setStack: (stack: string) => void;
}

const StackContext = createContext<StackContextValue | null>(null);

export function StackProvider({ children }: { children: ReactNode }) {
  const [stack, setStack] = useState<string | null>(null);
  const value = useMemo(() => ({ stack, setStack }), [stack]);
  return <StackContext.Provider value={value}>{children}</StackContext.Provider>;
}

export function useStack(): StackContextValue {
  const value = useContext(StackContext);
  if (value === null) throw new Error("useStack must be used inside <StackProvider>");
  return value;
}
