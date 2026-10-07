import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router";
import { App } from "./App";
import "./styles.css";

const container = document.getElementById("root");
if (container === null) throw new Error("Missing #root element");

createRoot(container).render(
  <StrictMode>
    <BrowserRouter basename="/ui">
      <App />
    </BrowserRouter>
  </StrictMode>,
);
