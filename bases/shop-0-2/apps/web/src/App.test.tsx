import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { App } from "./App";

describe("App shell", () => {
  it("F-001: логотип CyberSphere веде на /", () => {
    render(
      <MemoryRouter>
        <App />
      </MemoryRouter>,
    );
    expect(screen.getByRole("link", { name: "CyberSphere" })).toHaveAttribute("href", "/");
  });

  it("F-002: навігація має Catalog, News, Support, Account", () => {
    render(
      <MemoryRouter>
        <App />
      </MemoryRouter>,
    );
    for (const [name, href] of [
      ["Catalog", "/catalog"],
      ["News", "/news"],
      ["Support", "/support"],
      ["Account", "/account"],
    ]) {
      expect(screen.getByRole("link", { name })).toHaveAttribute("href", href);
    }
  });

  it("F-062: невідомий шлях показує сторінку «не знайдено»", () => {
    render(
      <MemoryRouter initialEntries={["/nope"]}>
        <App />
      </MemoryRouter>,
    );
    expect(screen.getByRole("heading", { name: "Сторінку не знайдено" })).toBeInTheDocument();
  });
});
