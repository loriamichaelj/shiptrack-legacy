import { render } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { vi } from "vitest";
import { App } from "../App";
import type { TrackView } from "../api";

export const TRACKING_NUMBER = "MF0123456789";

export function trackView(overrides: Partial<TrackView> = {}): TrackView {
  return {
    tracking_number: TRACKING_NUMBER,
    carrier_code: "ACME",
    status: "IN_TRANSIT",
    estimated_delivery_at: "2026-10-09T08:00:00Z",
    delivered_at: null,
    events: [
      { event_type: "PICKED_UP", location: "Rotterdam", occurred_at: "2026-10-05T09:30:00Z" },
      { event_type: "IN_TRANSIT", location: "Hamburg", occurred_at: "2026-10-07T08:00:00Z" },
    ],
    ...overrides,
  };
}

export function jsonResponse(
  body: unknown,
  init: { status?: number; stack?: string } = {},
): Response {
  const headers = new Headers({ "Content-Type": "application/json" });
  if (init.stack !== undefined) headers.set("X-ShipTrack-Stack", init.stack);
  return new Response(JSON.stringify(body), { status: init.status ?? 200, headers });
}

export function errorEnvelope(code: string, message: string, requestId: string | null = null) {
  return { error: { code, message, request_id: requestId } };
}

/** Stub fetch with a sequence of responses (the last one repeats). */
export function stubFetch(...responses: (Response | Error)[]) {
  let call = 0;
  const mock = vi.fn((): Promise<Response> => {
    const next = responses[Math.min(call, responses.length - 1)];
    call += 1;
    if (next === undefined) throw new Error("stubFetch needs at least one response");
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next.clone());
  });
  vi.stubGlobal("fetch", mock);
  return mock;
}

export function renderApp(path = "/") {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <App />
    </MemoryRouter>,
  );
}
