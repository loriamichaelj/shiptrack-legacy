import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  // The app is served under /ui/ by nginx (legacy) and by the API pods (modern).
  base: "/ui/",
  plugins: [react()],
  build: {
    outDir: "dist",
    sourcemap: false,
    // No data: URIs for assets, so the built page needs nothing beyond same-origin files.
    assetsInlineLimit: 0,
  },
  server: {
    proxy: { "/api": "http://127.0.0.1:8000" },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/__tests__/setup.ts"],
    css: false,
  },
});
