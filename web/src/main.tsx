import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { applyTheme, loadTheme } from "./theme";
import "./styles.css";

// Before the first render, so a dark-mode reader never sees a flash of light.
applyTheme(loadTheme());

// Only in a built app. A service worker in front of the Vite dev server would
// serve stale modules and make every change a mystery.
if (import.meta.env.PROD && "serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {
      // Installability is a nicety; the app works fine without it.
    });
  });
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
