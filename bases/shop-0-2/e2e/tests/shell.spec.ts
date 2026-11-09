import { expect, test } from "@playwright/test";

// Етап 2: каркас. Повні сценарії §7 (golden path тощо) — етап 6.
test("F-001: лендінг відкривається, логотип веде на /", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("link", { name: "CyberSphere" })).toHaveAttribute("href", "/");
});
