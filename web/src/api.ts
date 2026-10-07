// The UI's only API call: GET /api/v1/track/{tracking_number}, same-origin.

export const TRACKING_NUMBER_PATTERN = /^MF\d{10}$/;
export const STACK_HEADER = "X-ShipTrack-Stack";

export type ShipmentStatus =
  | "CREATED"
  | "PICKED_UP"
  | "IN_TRANSIT"
  | "OUT_FOR_DELIVERY"
  | "DELIVERED"
  | "EXCEPTION";

export interface TrackEvent {
  event_type: ShipmentStatus;
  location: string;
  occurred_at: string;
}

export interface TrackView {
  tracking_number: string;
  carrier_code: string;
  status: ShipmentStatus;
  estimated_delivery_at: string | null;
  delivered_at: string | null;
  events: TrackEvent[];
}

export type TrackOutcome =
  | { kind: "found"; view: TrackView; stack: string | null }
  | { kind: "not_found"; stack: string | null }
  | { kind: "invalid"; message: string; stack: string | null }
  | { kind: "error"; message: string; requestId: string | null; stack: string | null };

export function normalizeTrackingNumber(raw: string): string {
  return raw.trim().toUpperCase();
}

export function isValidTrackingNumber(value: string): boolean {
  return TRACKING_NUMBER_PATTERN.test(value);
}

interface ErrorEnvelope {
  message: string | null;
  requestId: string | null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

async function readEnvelope(response: Response): Promise<ErrorEnvelope> {
  try {
    const body: unknown = await response.json();
    const error = isRecord(body) ? body.error : undefined;
    if (!isRecord(error)) return { message: null, requestId: null };
    return {
      message: typeof error.message === "string" ? error.message : null,
      requestId: typeof error.request_id === "string" ? error.request_id : null,
    };
  } catch {
    return { message: null, requestId: null };
  }
}

function isTrackView(value: unknown): value is TrackView {
  return (
    isRecord(value) &&
    typeof value.tracking_number === "string" &&
    typeof value.carrier_code === "string" &&
    typeof value.status === "string" &&
    Array.isArray(value.events)
  );
}

export async function fetchTrack(
  trackingNumber: string,
  signal?: AbortSignal,
): Promise<TrackOutcome> {
  let response: Response;
  try {
    response = await fetch(`/api/v1/track/${encodeURIComponent(trackingNumber)}`, {
      headers: { Accept: "application/json" },
      signal,
    });
  } catch {
    return {
      kind: "error",
      message: "Could not reach ShipTrack. Check your connection and try again.",
      requestId: null,
      stack: null,
    };
  }

  const stack = response.headers.get(STACK_HEADER);
  if (response.ok) {
    const body: unknown = await response.json().catch(() => null);
    if (isTrackView(body)) return { kind: "found", view: body, stack };
    return {
      kind: "error",
      message: "ShipTrack returned a response this page could not read.",
      requestId: null,
      stack,
    };
  }
  if (response.status === 404) return { kind: "not_found", stack };

  const envelope = await readEnvelope(response);
  if (response.status === 422) {
    return {
      kind: "invalid",
      message: envelope.message ?? "That tracking number was not accepted.",
      stack,
    };
  }
  return {
    kind: "error",
    message: "ShipTrack had a problem handling that request. Please try again.",
    requestId: envelope.requestId,
    stack,
  };
}
