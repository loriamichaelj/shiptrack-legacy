import { Link } from "react-router";

export function NotFoundPage() {
  return (
    <section aria-labelledby="not-found-heading">
      <h1 id="not-found-heading">Page not found</h1>
      <p>We could not find that page.</p>
      <p>
        <Link to="/">Back to search</Link>
      </p>
    </section>
  );
}
