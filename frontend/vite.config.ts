import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 3000,
    // Acceso desde otras PCs de la red: escucha en todas las interfaces y
    // acepta cualquier Host (la app se comparte por http://<IP>:3000).
    host: "0.0.0.0",
    allowedHosts: true,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8000",
        changeOrigin: true,
      },
      "/storage": {
        target: "http://127.0.0.1:8000",
        changeOrigin: true,
      },
    },
  },
});