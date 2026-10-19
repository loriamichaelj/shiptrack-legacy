import type { ShipmentStatus } from "./api";

export const STATUS_LABELS: Record<ShipmentStatus, string> = {
  CREATED: "Created",
  PICKED_UP: "Picked up",
  IN_TRANSIT: "In transit",
  OUT_FOR_DELIVERY: "Out for delivery",
  DELIVERED: "Delivered",
  EXCEPTION: "Exception",
};

export function statusLabel(status: string): string {
  return STATUS_LABELS[status as ShipmentStatus] ?? status;
}

/** The names the UI shows for the stacks (ADR-0015); `X-ShipTrack-Stack` still says legacy or modern. */
export const STACK_LABELS: Record<string, string> = { legacy: "v1", modern: "v3" };

export function stackLabel(stack: string): string {
  return STACK_LABELS[stack] ?? stack;
}

const pad = (value: number): string => String(value).padStart(2, "0");

/** Render an ISO timestamp as "YYYY-MM-DD HH:MM UTC" so the output never depends on the viewer. */
export function formatTimestamp(iso: string | null): string {
  if (iso === null) return "—";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return (
    `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())} ` +
    `${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())} UTC`
  );
}
