import { useStack } from "../stack";

/** Shows which stack served the last API response, so the audience can watch traffic shift. */
export function StackBadge() {
  const { stack } = useStack();
  return (
    <span className="stack-badge" data-stack={stack ?? "unknown"}>
      Served by: {stack ?? "—"}
    </span>
  );
}
