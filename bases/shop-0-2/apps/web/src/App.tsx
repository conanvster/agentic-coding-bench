import { Link, Route, Routes } from "react-router-dom";

/** Каркас (етап 2): шапка з навігацією §4.1; сторінки — етап 5. */
export function App() {
  return (
    <div className="min-h-screen">
      <header className="flex items-center gap-6 px-6 py-4">
        <Link to="/" className="text-xl font-bold">
          CyberSphere
        </Link>
        <nav aria-label="Головна навігація" className="flex gap-4">
          <Link to="/catalog">Catalog</Link>
          <Link to="/news">News</Link>
          <Link to="/support">Support</Link>
          <Link to="/account">Account</Link>
        </nav>
      </header>
      <main className="px-6">
        <Routes>
          <Route path="/" element={<h1>CyberSphere</h1>} />
          <Route path="*" element={<h1>Сторінку не знайдено</h1>} />
        </Routes>
      </main>
    </div>
  );
}
