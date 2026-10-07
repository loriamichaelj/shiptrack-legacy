import { useEffect, useState } from "react";
import { Link, useParams } from "react-router";
import { fetchTrack, isValidTrackingNumber, type TrackOutcome, type TrackView } from "../api";
import { StatusBadge } from "../components/StatusBadge";
import { Timeline } from "../components/Timeline";
import { formatTimestamp } from "../format";
import { useStack } from "../stack";

export const REFRESH_INTERVAL_MS = 30_000;

interface Loaded {
  trackingNumber: string;
  outcome: TrackOutcome;
  /** Last successfully loaded view for this tracking number, kept if a refresh fails. */
  view: TrackView | null;
}

export function TrackPage() {
  const { trackingNumber = "" } = useParams();
  const { setStack } = useStack();
  const valid = isValidTrackingNumber(trackingNumber);
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [refreshCount, setRefreshCount] = useState(0);

  useEffect(() => {
    if (!valid) return;
    const controller = new AbortController();
    void fetchTrack(trackingNumber, controller.signal).then((outcome) => {
      if (controller.signal.aborted) return;
      if (outcome.stack !== null) setStack(outcome.stack);
      setLoaded((previous) => {
        const sameShipment = previous?.trackingNumber === trackingNumber;
        const view =
          outcome.kind === "found" ? outcome.view : sameShipment ? (previous?.view ?? null) : null;
        return { trackingNumber, outcome, view };
      });
    });
    return () => {
      controller.abort();
    };
  }, [trackingNumber, valid, refreshCount, setStack]);

  const current = loaded?.trackingNumber === trackingNumber ? loaded : null;
  const status = current?.view?.status ?? null;

  // Auto-refresh every 30 seconds until the shipment is delivered.
  useEffect(() => {
    if (!valid || status === null || status === "DELIVERED") return;
    const timer = setInterval(() => {
      setRefreshCount((count) => count + 1);
    }, REFRESH_INTERVAL_MS);
    return () => {
      clearInterval(timer);
    };
  }, [valid, status]);

  const refresh = () => {
    setRefreshCount((count) => count + 1);
  };

  return (
    <section aria-labelledby="track-heading">
      <h1 id="track-heading">Shipment {trackingNumber}</h1>
      <div aria-live="polite">
        {!valid ? (
          <Message tone="error">
            “{trackingNumber}” is not a valid tracking number. Tracking numbers are MF followed by
            10 digits.
          </Message>
        ) : current === null ? (
          <p role="status">Loading…</p>
        ) : (
          <Result loaded={current} onRetry={refresh} />
        )}
      </div>
      <p>
        <Link to="/">Search for another shipment</Link>
      </p>
    </section>
  );
}

function Message({ tone, children }: { tone: "error" | "info"; children: React.ReactNode }) {
  return <p className={tone === "error" ? "error" : undefined}>{children}</p>;
}

function Result({ loaded, onRetry }: { loaded: Loaded; onRetry: () => void }) {
  const { outcome, view, trackingNumber } = loaded;

  if (outcome.kind === "found") return <Details view={outcome.view} onRefresh={onRetry} />;

  if (view !== null) {
    // A refresh failed: keep showing the last known status and say so.
    return (
      <>
        <Message tone="error">Could not refresh. Showing the last known status.</Message>
        <Details view={view} onRefresh={onRetry} />
      </>
    );
  }

  switch (outcome.kind) {
    case "not_found":
      return <Message tone="error">No shipment found for {trackingNumber}.</Message>;
    case "invalid":
      return <Message tone="error">{outcome.message}</Message>;
    case "error":
      return (
        <>
          <Message tone="error">{outcome.message}</Message>
          {outcome.requestId !== null && <p className="muted">Reference: {outcome.requestId}</p>}
          <button type="button" onClick={onRetry}>
            Try again
          </button>
        </>
      );
  }
}

function Details({ view, onRefresh }: { view: TrackView; onRefresh: () => void }) {
  return (
    <>
      <p>
        <StatusBadge status={view.status} />
      </p>
      <dl className="details">
        <dt>Carrier</dt>
        <dd>{view.carrier_code}</dd>
        <dt>Estimated delivery</dt>
        <dd>{formatTimestamp(view.estimated_delivery_at)}</dd>
        <dt>Delivered</dt>
        <dd>{formatTimestamp(view.delivered_at)}</dd>
      </dl>
      <h2>History</h2>
      <Timeline events={view.events} />
      <button type="button" onClick={onRefresh}>
        Refresh
      </button>
      {view.status !== "DELIVERED" && (
        <p className="muted">This page refreshes automatically every 30 seconds.</p>
      )}
    </>
  );
}
