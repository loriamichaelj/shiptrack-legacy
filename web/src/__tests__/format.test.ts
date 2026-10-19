import { describe, expect, it } from "vitest";
import { formatTimestamp, stackLabel, statusLabel } from "../format";

describe("formatTimestamp", () => {
  it("renders UTC regardless of the viewer's timezone", () => {
    expect(formatTimestamp("2026-10-09T08:05:00Z")).toBe("2026-10-09 08:05 UTC");
    expect(formatTimestamp("2026-10-09T10:05:00+02:00")).toBe("2026-10-09 08:05 UTC");
  });

  it("renders a dash for null", () => {
    expect(formatTimestamp(null)).toBe("—");
  });

  it("returns unparseable input unchanged", () => {
    expect(formatTimestamp("soon")).toBe("soon");
  });
});

describe("statusLabel", () => {
  it("humanizes known statuses and passes unknown ones through", () => {
    expect(statusLabel("OUT_FOR_DELIVERY")).toBe("Out for delivery");
    expect(statusLabel("SOMETHING_NEW")).toBe("SOMETHING_NEW");
  });
});

describe("stackLabel", () => {
  it("names legacy v1 and modern v3 and passes unknown stacks through", () => {
    expect(stackLabel("legacy")).toBe("v1");
    expect(stackLabel("modern")).toBe("v3");
    expect(stackLabel("other")).toBe("other");
  });
});
