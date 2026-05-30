// ─────────────────────────────────────────────────────────────────────────
//  log-ingest — Recibe logs de la app de taxis y los guarda en disco.
//
//  La app (RemoteLogService) hace POST /logs con un lote de líneas + contexto
//  (device, user, role, ver). Aquí se anexan a /logs/<user|device>-<fecha>.log
//  para poder depurar pruebas de campo SIN tener el teléfono por USB.
//
//  Auth: header `Authorization: Bearer <INGEST_TOKEN>` (secreto compartido).
//  Retención: borra archivos > 7 días (barrido horario). Sin cron del SO.
// ─────────────────────────────────────────────────────────────────────────
const express = require("express");
const fs = require("fs");
const path = require("path");

const TOKEN = process.env.INGEST_TOKEN || "";
const LOG_DIR = process.env.LOG_DIR || "/logs";
const PORT = parseInt(process.env.PORT || "9099", 10);
const RETENTION_DAYS = parseInt(process.env.RETENTION_DAYS || "7", 10);

const app = express();
app.use(express.json({ limit: "4mb" }));

function sanitize(s) {
  return String(s || "")
    .replace(/[^A-Za-z0-9_.-]/g, "_")
    .slice(0, 48) || "unknown";
}

// Fecha YYYY-MM-DD en America/Guayaquil (UTC-5).
function ecDate() {
  const d = new Date(Date.now() - 5 * 3600 * 1000);
  return d.toISOString().slice(0, 10);
}

function handleIngest(req, res) {
  const ip = req.headers["x-forwarded-for"] || req.socket.remoteAddress;
  const authOk = !TOKEN || req.get("Authorization") === `Bearer ${TOKEN}`;
  const b = req.body || {};
  console.log(
    `[ingest] POST ${req.path} ip=${ip} authOk=${authOk} ` +
      `user=${b.user || "?"} device=${b.device || "?"} lines=${Array.isArray(b.lines) ? b.lines.length : "n/a"}`,
  );
  if (TOKEN && req.get("Authorization") !== `Bearer ${TOKEN}`) {
    return res.sendStatus(401);
  }
  const body = req.body || {};
  const lines = body.lines;
  if (!Array.isArray(lines) || lines.length === 0) return res.sendStatus(400);

  const label = sanitize(body.user || body.device);
  const file = path.join(LOG_DIR, `${label}-${ecDate()}.log`);
  // Encabezado de contexto por lote (device/role/version + hora servidor).
  const hdr =
    `\n===== lote ${new Date().toISOString()} ` +
    `device=${body.device || "?"} role=${body.role || "?"} ver=${body.ver || "?"} =====\n`;
  const out = hdr + lines.map((l) => String(l)).join("\n") + "\n";
  try {
    fs.mkdirSync(LOG_DIR, { recursive: true });
    fs.appendFileSync(file, out);
    res.sendStatus(200);
  } catch (e) {
    console.error("append fail:", e.message);
    res.sendStatus(500);
  }
}

app.post("/logs", handleIngest);
app.post("/", handleIngest); // tolerante a la ruta que use Caddy
app.get("/health", (_req, res) => res.send("ok"));

// Retención: borrar logs > RETENTION_DAYS.
function sweep() {
  let removed = 0;
  try {
    const cutoff = Date.now() - RETENTION_DAYS * 24 * 3600 * 1000;
    for (const f of fs.readdirSync(LOG_DIR)) {
      const fp = path.join(LOG_DIR, f);
      try {
        if (fs.statSync(fp).mtimeMs < cutoff) {
          fs.unlinkSync(fp);
          removed++;
        }
      } catch (_) { /* noop */ }
    }
  } catch (_) { /* noop */ }
  if (removed > 0) console.log(`retención: borrados ${removed} logs > ${RETENTION_DAYS}d`);
}

fs.mkdirSync(LOG_DIR, { recursive: true });
app.listen(PORT, "127.0.0.1", () => {
  console.log(`[log-ingest] escuchando en 127.0.0.1:${PORT}, dir ${LOG_DIR}`);
  sweep();
  setInterval(sweep, 3600 * 1000);
});
