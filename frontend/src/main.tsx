import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import ONPEPaucarpataDashboard from "./ONPEPaucarpataDashboard";
import LoginGate from "./LoginGate";
import "./index.css";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <LoginGate>
      <ONPEPaucarpataDashboard />
    </LoginGate>
  </StrictMode>
);