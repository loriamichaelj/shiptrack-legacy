import type { TrackEvent } from "../api";
import { formatTimestamp, statusLabel } from "../format";

/** Event timeline, newest first. The API returns events oldest first. */
export function Timeline({ events }: { events: TrackEvent[] }) {
  if (events.length === 0) return <p className="muted">No tracking events yet.</p>;
  const newestFirst = events.map((event, index) => ({ event, index })).reverse();
  return (
    <ol className="timeline" aria-label="Tracking events, newest first">
      {newestFirst.map(({ event, index }) => (
        <li key={index}>
          <span className="timeline-status">{statusLabel(event.event_type)}</span>
          <span className="timeline-location">{event.location}</span>
          <time className="timeline-time" dateTime={event.occurred_at}>
            {formatTimestamp(event.occurred_at)}
          </time>
        </li>
      ))}
    </ol>
  );
}
