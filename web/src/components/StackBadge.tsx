import { useStack } from "../stack";

/** Shows which stack served this page, then the latest API response, so traffic can be watched. */
export function StackBadge() {
  const { stack } = useStack();
  return (
    <span className="stack-badge" data-stack={stack ?? "unknown"}>
      Served by: {stack ?? "—"}
    </span>
  );
}
