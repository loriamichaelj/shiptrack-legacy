import { describe, expect, it } from "vitest";
import {
  fetchTrack,
  isValidTrackingNumber,
  normalizeTrackingNumber,
  TRACKING_NUMBER_PATTERN,
} from "../api";
import { errorEnvelope, jsonResponse, stubFetch, trackView } from "./helpers";

describe("tracking number validation", () => {
  it.each(["MF0000000000", "MF0123456789", "MF9999999999"])("accepts %s", (value) => {
    expect(isValidTrackingNumber(value)).toBe(true);
  });

  it.each([
    "",
    "MF",
    "MF012345678",
    "MF01234567890",
    "mf0123456789",
    "XX0123456789",
    "MF01234567A9",
    " MF0123456789",
    "MF0123456789\n",
    "MF0123456789<script>",
  ])("rejects %j", (value) => {
    expect(isValidTrackingNumber(value)).toBe(false);
  });

  it("uses the documented pattern", () => {
    expect(TRACKING_NUMBER_PATTERN.source).toBe("^MF\\d{10}$");
  });

  it("normalizes whitespace and case before validating", () => {
    expect(normalizeTrackingNumber("  mf0123456789 ")).toBe("MF0123456789");
  });
});

describe("fetchTrack", () => {
  it("calls the track endpoint with a same-origin relative URL", async () => {
    const mock = stubFetch(jsonResponse(trackView(), { stack: "legacy" }));
    await fetchTrack("MF0123456789");
    const [url] = mock.mock.calls[0] as unknown as [string];
    expect(url).toBe("/api/v1/track/MF0123456789");
    expect(url.startsWith("/")).toBe(true);
  });

  it("returns the view and the stack header on success", async () => {
    stubFetch(jsonResponse(trackView(), { stack: "modern" }));
    const outcome = await fetchTrack("MF0123456789");
    expect(outcome).toMatchObject({ kind: "found", stack: "modern" });
  });

  it("treats a missing stack header as unknown", async () => {
    stubFetch(jsonResponse(trackView()));
    expect(await fetchTrack("MF0123456789")).toMatchObject({ kind: "found", stack: null });
  });

  it("maps 404 to not_found", async () => {
    stubFetch(jsonResponse(errorEnvelope("NOT_FOUND", "nope"), { status: 404, stack: "legacy" }));
    expect(await fetchTrack("MF0000000000")).toEqual({ kind: "not_found", stack: "legacy" });
  });

  it("maps 422 to invalid with the server message", async () => {
    stubFetch(jsonResponse(errorEnvelope("VALIDATION_ERROR", "bad number"), { status: 422 }));
    expect(await fetchTrack("MF0000000000")).toMatchObject({
      kind: "invalid",
      message: "bad number",
    });
  });

  it("maps 5xx to an error and surfaces the request id", async () => {
    stubFetch(
      jsonResponse(errorEnvelope("INTERNAL", "boom", "req-42"), { status: 503, stack: "modern" }),
    );
    expect(await fetchTrack("MF0123456789")).toMatchObject({
      kind: "error",
      requestId: "req-42",
      stack: "modern",
    });
  });

  it("copes with a 5xx that is not JSON", async () => {
    stubFetch(new Response("<html>Bad gateway</html>", { status: 502 }));
    expect(await fetchTrack("MF0123456789")).toMatchObject({ kind: "error", requestId: null });
  });

  it("maps a network failure to an error", async () => {
    stubFetch(new TypeError("Failed to fetch"));
    expect(await fetchTrack("MF0123456789")).toMatchObject({ kind: "error", stack: null });
  });

  it("rejects a 200 whose body is not a track view", async () => {
    stubFetch(jsonResponse({ hello: "world" }));
    expect(await fetchTrack("MF0123456789")).toMatchObject({ kind: "error" });
  });

  it("escapes the tracking number in the URL", async () => {
    const mock = stubFetch(jsonResponse({}, { status: 404 }));
    await fetchTrack("MF/../x?y=1");
    const [url] = mock.mock.calls[0] as unknown as [string];
    expect(url).toBe("/api/v1/track/MF%2F..%2Fx%3Fy%3D1");
  });
});
