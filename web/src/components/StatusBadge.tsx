import { statusLabel } from "../format";

/** Status is always shown as text; the colour is decoration only. */
export function StatusBadge({ status }: { status: string }) {
  return (
    <span className={`badge badge-${status.toLowerCase().replaceAll("_", "-")}`} data-status={status}>
      {statusLabel(status)}
    </span>
  );
}
