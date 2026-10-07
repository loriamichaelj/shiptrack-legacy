import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { REFRESH_INTERVAL_MS } from "../pages/TrackPage";
import {
  errorEnvelope,
  jsonResponse,
  renderApp,
  stubFetch,
  trackView,
  TRACKING_NUMBER,
} from "./helpers";

const trackPath = `/track/${TRACKING_NUMBER}`;

// Fake only the interval timers: Testing Library's polling needs the real setTimeout.
function fakeIntervals() {
  vi.useFakeTimers({ toFake: ["setInterval", "clearInterval"] });
}

async function advance(ms: number) {
  await act(async () => {
    vi.advanceTimersByTime(ms);
    await Promise.resolve();
  });
}

describe("track page: loading and found", () => {
  it("shows a loading state while the request is in flight", () => {
    vi.stubGlobal("fetch", vi.fn(() => new Promise<Response>(() => undefined)));
    renderApp(trackPath);
    expect(screen.getByRole("status")).toHaveTextContent("Loading…");
  });

  it("shows status, carrier, estimate, and the timeline newest first", async () => {
    stubFetch(jsonResponse(trackView(), { stack: "legacy" }));
    renderApp(trackPath);

    expect(await screen.findByText("In transit", { selector: ".badge" })).toBeVisible();
    expect(screen.getByRole("heading", { name: `Shipment ${TRACKING_NUMBER}` })).toBeVisible();
    expect(screen.getByText("ACME")).toBeVisible();
    expect(screen.getByText("2026-10-09 08:00 UTC")).toBeVisible();
    expect(screen.getByText("—")).toBeVisible(); // not delivered yet

    const items = within(screen.getByRole("list")).getAllByRole("listitem");
    expect(items[0]).toHaveTextContent("Hamburg");
    expect(items[1]).toHaveTextContent("Rotterdam");
    expect(screen.getByRole("button", { name: "Refresh" })).toBeVisible();
    expect(screen.getByText(/refreshes automatically every 30 seconds/)).toBeVisible();
  });

  it("puts the result in a polite live region", async () => {
    stubFetch(jsonResponse(trackView()));
    const { container } = renderApp(trackPath);
    await screen.findByText("In transit", { selector: ".badge" });
    const region = container.querySelector('[aria-live="polite"]');
    expect(region).not.toBeNull();
    expect(region).toHaveTextContent("Hamburg");
  });

  it("shows the stack that served the response in the footer", async () => {
    stubFetch(jsonResponse(trackView(), { stack: "modern" }));
    renderApp(trackPath);
    expect(await screen.findByText("Served by: modern")).toBeVisible();
  });

  it("shows the delivery time for a delivered shipment and no auto-refresh note", async () => {
    stubFetch(
      jsonResponse(
        trackView({
          status: "DELIVERED",
          delivered_at: "2026-10-08T15:45:00Z",
          estimated_delivery_at: "2026-10-08T15:45:00Z",
        }),
      ),
    );
    renderApp(trackPath);
    expect(await screen.findByText("Delivered", { selector: ".badge" })).toBeVisible();
    expect(screen.getAllByText("2026-10-08 15:45 UTC")).toHaveLength(2);
    expect(screen.queryByText(/refreshes automatically/)).not.toBeInTheDocument();
  });
});

describe("track page: refreshing", () => {
  it("refreshes every 30 seconds while the shipment is not delivered", async () => {
    fakeIntervals();
    const fetchMock = stubFetch(
      jsonResponse(trackView({ status: "IN_TRANSIT" }), { stack: "legacy" }),
      jsonResponse(trackView({ status: "OUT_FOR_DELIVERY" }), { stack: "modern" }),
    );
    renderApp(trackPath);
    await screen.findByText("In transit", { selector: ".badge" });
    expect(fetchMock).toHaveBeenCalledTimes(1);

    await advance(REFRESH_INTERVAL_MS);
    expect(await screen.findByText("Out for delivery", { selector: ".badge" })).toBeVisible();
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(screen.getByText("Served by: modern")).toBeVisible();
  });

  it("stops refreshing once the shipment is delivered", async () => {
    fakeIntervals();
    const fetchMock = stubFetch(
      jsonResponse(trackView({ status: "IN_TRANSIT" })),
      jsonResponse(trackView({ status: "DELIVERED", delivered_at: "2026-10-08T15:45:00Z" })),
    );
    renderApp(trackPath);
    await screen.findByText("In transit", { selector: ".badge" });

    await advance(REFRESH_INTERVAL_MS);
    await screen.findByText("Delivered", { selector: ".badge" });
    expect(fetchMock).toHaveBeenCalledTimes(2);

    await advance(REFRESH_INTERVAL_MS * 4);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("does not refresh a shipment that was not found", async () => {
    fakeIntervals();
    const fetchMock = stubFetch(jsonResponse(errorEnvelope("NOT_FOUND", "x"), { status: 404 }));
    renderApp("/track/MF0000000000");
    await screen.findByText(/No shipment found/);
    await advance(REFRESH_INTERVAL_MS * 3);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("refreshes on demand with the Refresh button", async () => {
    const fetchMock = stubFetch(
      jsonResponse(trackView({ status: "IN_TRANSIT" })),
      jsonResponse(trackView({ status: "OUT_FOR_DELIVERY" })),
    );
    const user = userEvent.setup();
    renderApp(trackPath);
    await screen.findByText("In transit", { selector: ".badge" });
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    expect(await screen.findByText("Out for delivery", { selector: ".badge" })).toBeVisible();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("keeps the last known status when a refresh fails", async () => {
    const user = userEvent.setup();
    stubFetch(jsonResponse(trackView()), new TypeError("Failed to fetch"));
    renderApp(trackPath);
    await screen.findByText("In transit", { selector: ".badge" });
    await user.click(screen.getByRole("button", { name: "Refresh" }));
    expect(await screen.findByText(/Could not refresh/)).toBeVisible();
    expect(screen.getByText("In transit", { selector: ".badge" })).toBeVisible();
    expect(screen.getByText("Hamburg")).toBeVisible();
  });
});

describe("track page: error states", () => {
  it("says no shipment was found for a 404", async () => {
    stubFetch(jsonResponse(errorEnvelope("NOT_FOUND", "x"), { status: 404, stack: "legacy" }));
    renderApp("/track/MF0000000000");
    expect(await screen.findByText("No shipment found for MF0000000000.")).toBeVisible();
    expect(screen.getByText("Served by: legacy")).toBeVisible();
    expect(screen.getByRole("link", { name: "Search for another shipment" })).toHaveAttribute(
      "href",
      "/",
    );
  });

  it("shows the validation message for a 422", async () => {
    stubFetch(
      jsonResponse(errorEnvelope("VALIDATION_ERROR", "Tracking number rejected"), { status: 422 }),
    );
    renderApp(trackPath);
    expect(await screen.findByText("Tracking number rejected")).toBeVisible();
  });

  it("shows a retry prompt with the request id for a 5xx", async () => {
    const user = userEvent.setup();
    const fetchMock = stubFetch(
      jsonResponse(errorEnvelope("INTERNAL", "boom", "req-42"), { status: 500 }),
      jsonResponse(trackView()),
    );
    renderApp(trackPath);
    expect(await screen.findByText(/had a problem handling that request/)).toBeVisible();
    expect(screen.getByText("Reference: req-42")).toBeVisible();

    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText("In transit", { selector: ".badge" })).toBeVisible();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("omits the reference line when the error has no request id", async () => {
    stubFetch(jsonResponse(errorEnvelope("INTERNAL", "boom"), { status: 500 }));
    renderApp(trackPath);
    await screen.findByRole("button", { name: "Try again" });
    expect(screen.queryByText(/Reference:/)).not.toBeInTheDocument();
  });

  it("shows a retry prompt on a network error", async () => {
    stubFetch(new TypeError("Failed to fetch"));
    renderApp(trackPath);
    expect(await screen.findByText(/Could not reach ShipTrack/)).toBeVisible();
    expect(screen.getByRole("button", { name: "Try again" })).toBeVisible();
  });

  it("rejects a malformed tracking number without calling the API", async () => {
    const fetchMock = stubFetch(jsonResponse({}));
    renderApp("/track/hello");
    expect(await screen.findByText(/is not a valid tracking number/)).toBeVisible();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("renders hostile tracking numbers as text, never as markup", async () => {
    stubFetch(jsonResponse({}));
    const { container } = renderApp("/track/%3Cimg%20src=x%20onerror=alert(1)%3E");
    await screen.findByText(/is not a valid tracking number/);
    expect(container.querySelector("img")).toBeNull();
    expect(container).toHaveTextContent("<img src=x onerror=alert(1)>");
  });
});

describe("navigation", () => {
  it("shows a not-found page with a link back to search", () => {
    stubFetch(jsonResponse({}));
    renderApp("/no/such/page");
    expect(screen.getByRole("heading", { name: "Page not found" })).toBeVisible();
    expect(screen.getByRole("link", { name: "Back to search" })).toHaveAttribute("href", "/");
  });

  it("links the brand back to the search page", async () => {
    stubFetch(jsonResponse(trackView()));
    renderApp(trackPath);
    await waitFor(() => {
      expect(screen.getByRole("link", { name: "ShipTrack" })).toHaveAttribute("href", "/");
    });
  });
});
