/* c8 ignore start — точка входу лише запускає buildApp() (§7, виняток) */
import { buildApp } from "./app.js";

const port = Number(process.env.PORT ?? 4000);
const app = buildApp();
app.listen({ port, host: "0.0.0.0" }).catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
/* c8 ignore stop */
