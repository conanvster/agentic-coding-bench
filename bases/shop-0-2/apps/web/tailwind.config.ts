import type { Config } from "tailwindcss";

// Дизайн-токени з docs/design/mockups.md (§5): темна тема, неонові акценти
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "#0B0B14",
        surface: "#151526",
        violet: "#7C3AED",
        pink: "#EC4899",
        emerald: "#10B981",
        teal: "#14B8A6",
      },
    },
  },
  plugins: [],
} satisfies Config;
