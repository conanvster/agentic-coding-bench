import { defineConfig, devices } from "@playwright/test";

// E2E у Docker (§7, етап 6): BASE_URL — сервіс web у compose
export default defineConfig({
  testDir: "./tests",
  use: { baseURL: process.env.BASE_URL ?? "http://localhost:8088" },
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } } },
  ],
});
