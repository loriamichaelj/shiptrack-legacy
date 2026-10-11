import { render, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { StackBadge } from "../components/StackBadge";
import { StatusBadge } from "../components/StatusBadge";
import { Timeline } from "../components/Timeline";
import { StackProvider, useStack } from "../stack";
import { trackView } from "./helpers";

describe("StatusBadge", () => {
  it("conveys the status as text, not colour alone", () => {
    render(<StatusBadge status="OUT_FOR_DELIVERY" />);
    expect(screen.getByText("Out for delivery")).toBeInTheDocument();
  });
});

describe("Timeline", () => {
  it("lists events newest first", () => {
    render(<Timeline events={trackView().events} />);
    const items = within(screen.getByRole("list")).getAllByRole("listitem");
    expect(items).toHaveLength(2);
    expect(items[0]).toHaveTextContent("In transit");
    expect(items[0]).toHaveTextContent("Hamburg");
    expect(items[1]).toHaveTextContent("Picked up");
  });

  it("says so when there are no events", () => {
    render(<Timeline events={[]} />);
    expect(screen.getByText("No tracking events yet.")).toBeInTheDocument();
    expect(screen.queryByRole("list")).not.toBeInTheDocument();
  });
});

describe("StackBadge", () => {
  it("shows a dash until an API response has been seen", () => {
    render(
      <StackProvider>
        <StackBadge />
      </StackProvider>,
    );
    expect(screen.getByText("Served by: —")).toBeInTheDocument();
  });

  it("shows the stack once it is known", () => {
    function Setter() {
      const { setStack } = useStack();
      return (
        <button
          type="button"
          onClick={() => {
            setStack("modern");
          }}
        >
          set
        </button>
      );
    }
    render(
      <StackProvider>
        <Setter />
        <StackBadge />
      </StackProvider>,
    );
    screen.getByRole("button").click();
    return screen.findByText("Served by: modern");
  });

  it("requires its provider", () => {
    expect(() => render(<StackBadge />)).toThrow(/StackProvider/);
  });
});

describe("the stack of the page", () => {
  it("is shown as soon as the probe answers, before any API call", async () => {
    render(
      <StackProvider probe={() => Promise.resolve("legacy")}>
        <StackBadge />
      </StackProvider>,
    );
    expect(await screen.findByText("Served by: legacy")).toBeInTheDocument();
  });

  it("stays a dash when the probe has no answer", async () => {
    const probe = vi.fn(() => Promise.resolve(null));
    render(
      <StackProvider probe={probe}>
        <StackBadge />
      </StackProvider>,
    );
    await waitFor(() => {
      expect(probe).toHaveBeenCalledTimes(1);
    });
    expect(screen.getByText("Served by: —")).toBeInTheDocument();
  });

  it("does not overwrite the stack of an API response that arrived first", async () => {
    let answer: (stack: string) => void = () => undefined;
    const slow = () =>
      new Promise<string | null>((resolve) => {
        answer = resolve;
      });
    function Setter() {
      const { setStack } = useStack();
      return (
        <button
          type="button"
          onClick={() => {
            setStack("modern");
          }}
        >
          set
        </button>
      );
    }
    render(
      <StackProvider probe={slow}>
        <Setter />
        <StackBadge />
      </StackProvider>,
    );
    screen.getByRole("button").click();
    expect(await screen.findByText("Served by: modern")).toBeInTheDocument();
    answer("legacy");
    await Promise.resolve();
    expect(screen.getByText("Served by: modern")).toBeInTheDocument();
  });
});

describe("probeStack", () => {
  async function real() {
    return (await vi.importActual<typeof import("../stackProbe")>("../stackProbe")).probeStack;
  }

  it("reads the stack header of a GET of the UI's base path", async () => {
    const fetchMock = vi.fn(() =>
      Promise.resolve(new Response("<html></html>", { headers: { "X-ShipTrack-Stack": "modern" } })),
    );
    vi.stubGlobal("fetch", fetchMock);
    expect(await (await real())()).toBe("modern");
    // The base path of the build: "/ui/" in the image, whatever the test runner uses here.
    expect(fetchMock).toHaveBeenCalledWith(
      import.meta.env.BASE_URL,
      expect.objectContaining({ cache: "no-store" }),
    );
  });

  it("reads it from an error status too", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() =>
        Promise.resolve(new Response("no", { status: 404, headers: { "X-ShipTrack-Stack": "legacy" } })),
      ),
    );
    expect(await (await real())()).toBe("legacy");
  });

  it("is null when the header is absent or the request fails", async () => {
    vi.stubGlobal("fetch", vi.fn(() => Promise.resolve(new Response("ok"))));
    expect(await (await real())()).toBeNull();
    vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new Error("offline"))));
    expect(await (await real())()).toBeNull();
  });
});
