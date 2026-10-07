import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
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
