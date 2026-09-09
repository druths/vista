import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Hosts the dev server will answer to. It runs inside a container, so requests
// arrive addressed to the compose service name as well as localhost; Vite
// rejects unknown Host headers with a 403 otherwise.
const allowedHosts = (process.env.VITE_ALLOWED_HOSTS ?? "localhost,127.0.0.1,web")
  .split(",")
  .map((host) => host.trim())
  .filter(Boolean);

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    port: 5173,
    allowedHosts,
    // The source is bind-mounted; file events don't propagate without polling.
    watch: { usePolling: true },
  },
});
