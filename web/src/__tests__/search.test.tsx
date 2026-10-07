import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { SEARCH_ERROR } from "../pages/SearchPage";
import { jsonResponse, renderApp, stubFetch, trackView, TRACKING_NUMBER } from "./helpers";

describe("search page", () => {
  it("renders a labelled input", () => {
    stubFetch(jsonResponse({}));
    renderApp("/");
    expect(screen.getByRole("heading", { name: "Track a shipment" })).toBeInTheDocument();
    const input = screen.getByLabelText("Tracking number");
    expect(input).toHaveAttribute("type", "text");
    expect(input).not.toHaveAttribute("aria-invalid", "true");
  });

  it.each(["", "   ", "MF123", "hello", "MF01234567890", "XX0123456789"])(
    "shows an inline error for invalid input %j and does not call the API",
    async (value) => {
      const fetchMock = stubFetch(jsonResponse({}));
      const user = userEvent.setup();
      renderApp("/");
      if (value) await user.type(screen.getByLabelText("Tracking number"), value);
      await user.click(screen.getByRole("button", { name: "Track" }));

      expect(await screen.findByRole("alert")).toHaveTextContent(SEARCH_ERROR);
      expect(screen.getByLabelText("Tracking number")).toHaveAttribute("aria-invalid", "true");
      expect(screen.getByRole("heading", { name: "Track a shipment" })).toBeInTheDocument();
      expect(fetchMock).not.toHaveBeenCalled();
    },
  );

  it("navigates to the tracking page for a valid number, normalizing case and spacing", async () => {
    const fetchMock = stubFetch(jsonResponse(trackView(), { stack: "legacy" }));
    const user = userEvent.setup();
    renderApp("/");
    await user.type(screen.getByLabelText("Tracking number"), "  mf0123456789 ");
    await user.click(screen.getByRole("button", { name: "Track" }));

    expect(await screen.findByRole("heading", { name: `Shipment ${TRACKING_NUMBER}` })).toBeVisible();
    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledTimes(1);
    });
  });

  it("submits with the Enter key", async () => {
    stubFetch(jsonResponse(trackView()));
    const user = userEvent.setup();
    renderApp("/");
    await user.type(screen.getByLabelText("Tracking number"), `${TRACKING_NUMBER}{Enter}`);
    expect(await screen.findByRole("heading", { name: `Shipment ${TRACKING_NUMBER}` })).toBeVisible();
  });
});
