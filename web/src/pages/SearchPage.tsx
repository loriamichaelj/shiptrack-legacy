import { useState, type FormEvent } from "react";
import { useNavigate } from "react-router";
import { isValidTrackingNumber, normalizeTrackingNumber } from "../api";

export const SEARCH_ERROR = "Enter a tracking number: MF followed by 10 digits.";

export function SearchPage() {
  const navigate = useNavigate();
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const trackingNumber = normalizeTrackingNumber(value);
    if (!isValidTrackingNumber(trackingNumber)) {
      setError(SEARCH_ERROR);
      return;
    }
    setError(null);
    void navigate(`/track/${trackingNumber}`);
  }

  return (
    <section aria-labelledby="search-heading">
      <h1 id="search-heading">Track a shipment</h1>
      <form onSubmit={onSubmit} noValidate>
        <label htmlFor="tracking-number">Tracking number</label>
        <div className="search-row">
          <input
            id="tracking-number"
            name="tracking-number"
            type="text"
            autoComplete="off"
            spellCheck={false}
            placeholder="MF0123456789"
            value={value}
            onChange={(event) => setValue(event.target.value)}
            aria-invalid={error !== null}
            aria-describedby={error === null ? "tracking-hint" : "tracking-hint tracking-error"}
          />
          <button type="submit">Track</button>
        </div>
        <p id="tracking-hint" className="muted">
          Tracking numbers start with MF followed by 10 digits.
        </p>
        {error !== null && (
          <p id="tracking-error" className="error" role="alert">
            {error}
          </p>
        )}
      </form>
    </section>
  );
}
