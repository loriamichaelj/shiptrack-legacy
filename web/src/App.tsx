import { Link, Route, Routes } from "react-router";
import { StackBadge } from "./components/StackBadge";
import { NotFoundPage } from "./pages/NotFoundPage";
import { SearchPage } from "./pages/SearchPage";
import { TrackPage } from "./pages/TrackPage";
import { StackProvider } from "./stack";

export function App() {
  return (
    <StackProvider>
      <div className="app">
        <header className="app-header">
          <Link to="/" className="brand">
            ShipTrack
          </Link>
        </header>
        <main>
          <Routes>
            <Route path="/" element={<SearchPage />} />
            <Route path="/track/:trackingNumber" element={<TrackPage />} />
            <Route path="*" element={<NotFoundPage />} />
          </Routes>
        </main>
        <footer className="app-footer">
          <StackBadge />
        </footer>
      </div>
    </StackProvider>
  );
}
