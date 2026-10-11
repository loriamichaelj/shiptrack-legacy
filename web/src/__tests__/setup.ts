import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, vi } from "vitest";

// The page asks the server which stack it is; no test has a server, so by default there is no answer.
vi.mock("../stackProbe", () => ({ probeStack: () => Promise.resolve(null) }));

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
