import { describe, expect, it } from "vitest";
import { buildApp } from "./app.js";

describe("health", () => {
  it("F-062: GET /api/health повертає 200 і status ok", async () => {
    const app = buildApp();
    const res = await app.inject({ method: "GET", url: "/api/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ status: "ok" });
    await app.close();
  });
});
