const express = require("express");
const fs = require("fs");
const path = require("path");
const { v4: uuidv4 } = require("uuid");

const app = express();
const PORT = 3000;
const ZONES_FILE = path.join(__dirname, "zones.json");
const REPORTS_FILE = path.join(__dirname, "reports.json");
const EVENTS_FILE = path.join(__dirname, "events.json");
const OPTIONS_REPORTS_FILE = path.join(__dirname, "options-reports.json");

app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

// ── Helpers ───────────────────────────────────────────────────────────────────

function readZones() {
  return JSON.parse(fs.readFileSync(ZONES_FILE, "utf8"));
}
function writeZones(z) {
  fs.writeFileSync(ZONES_FILE, JSON.stringify(z, null, 2));
}

function readReports() {
  if (!fs.existsSync(REPORTS_FILE)) return [];
  return JSON.parse(fs.readFileSync(REPORTS_FILE, "utf8"));
}
function writeReports(r) {
  fs.writeFileSync(REPORTS_FILE, JSON.stringify(r, null, 2));
}

function readEvents() {
  try {
    return JSON.parse(fs.readFileSync(EVENTS_FILE, "utf8"));
  } catch {
    return [];
  }
}
function writeEvents(e) {
  fs.writeFileSync(EVENTS_FILE, JSON.stringify(e, null, 2));
}

function readOptionsReports() {
  if (!fs.existsSync(OPTIONS_REPORTS_FILE)) return [];
  return JSON.parse(fs.readFileSync(OPTIONS_REPORTS_FILE, "utf8"));
}
function writeOptionsReports(r) {
  fs.writeFileSync(OPTIONS_REPORTS_FILE, JSON.stringify(r, null, 2));
}

function isAfterCutoff() {
  return new Date().getHours() >= 20;
}
function todayDate() {
  return new Date().toISOString().slice(0, 10);
}

// ── Routes ────────────────────────────────────────────────────────────────────

// Serve GUI
app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

// GUI: full zone history
app.get("/zones/all", (req, res) => {
  res.json(readZones());
});

// EA: fetch a single zone by ID
app.get("/zones/:id", (req, res) => {
  const zone = readZones().find((z) => z.id === req.params.id);
  if (!zone) return res.status(404).json({ error: "Zone not found" });
  res.json(zone);
});

// Events: get all  ← must be defined before the /:symbol wildcard
app.get("/events", (req, res) => {
  res.json(readEvents());
});

// Options EA: fetch today's options zones (above/below) for a symbol — no cutoff, EA handles timing
app.get("/options/:symbol", (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  const today = todayDate();
  const result = readZones().filter((z) => z.symbol === symbol && z.date === today && (z.direction === "above" || z.direction === "below"));
  res.json(result);
});

// Options EA: view all options reports (for analysis)  ← must be before /:symbol wildcard
app.get("/options-reports", (req, res) => {
  res.json(readOptionsReports());
});

// EA: active zones for a symbol (today only, before cutoff)
app.get("/:symbol", (req, res) => {
  if (isAfterCutoff()) return res.json([]);
  const symbol = req.params.symbol.toUpperCase();
  const today = todayDate();
  const result = readZones().filter((z) => z.symbol === symbol && z.date === today);
  res.json(result);
});

// GUI: add a zone
app.post("/zones", (req, res) => {
  const { symbol, direction, strength, watchedOnly, kind, size, time, price, from, to } = req.body;

  if (!symbol || !direction || !strength || !kind) return res.status(400).json({ error: "Missing required fields" });
  if (!["buy", "sell", "above", "below"].includes(direction)) return res.status(400).json({ error: "direction must be buy, sell, above, or below" });
  if (!["strong", "regular"].includes(strength)) return res.status(400).json({ error: "strength must be strong or regular" });
  if (!["point", "zone"].includes(kind)) return res.status(400).json({ error: "kind must be point or zone" });
  if (size !== undefined && !["small", "medium", "large"].includes(size))
    return res.status(400).json({ error: "size must be small, medium, or large" });
  if (kind === "point" && price == null) return res.status(400).json({ error: "price required for kind=point" });
  if (kind === "zone" && (from == null || to == null)) return res.status(400).json({ error: "from and to required for kind=zone" });

  const zone = {
    id: uuidv4(),
    symbol: symbol.toUpperCase(),
    direction,
    strength,
    watchedOnly: watchedOnly === true,
    kind,
    ...(size !== undefined ? { size } : {}),
    ...(time ? { time } : {}),
    ...(kind === "point" ? { price: parseFloat(price) } : { from: parseFloat(from), to: parseFloat(to) }),
    date: todayDate(),
    createdAt: new Date().toISOString(),
  };

  const zones = readZones();
  zones.push(zone);
  writeZones(zones);
  res.status(201).json(zone);
});

// GUI: clear all zones for a symbol
app.delete("/zones/:symbol", (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  const zones = readZones();
  const filtered = zones.filter((z) => z.symbol !== symbol);
  writeZones(filtered);
  res.json({ cleared: symbol, removed: zones.length - filtered.length });
});

// EA: receive a position report
app.post("/reports", (req, res) => {
  const report = req.body;
  if (!report || !report.ticket) return res.status(400).json({ error: "Invalid report payload" });
  report.receivedAt = new Date().toISOString();
  const reports = readReports();
  reports.push(report);
  writeReports(reports);
  console.log(`Report received: ticket=${report.ticket} symbol=${report.symbol} closedBy=${report.closedBy}`);
  res.status(201).json({ ok: true });
});

// Options EA: receive a 5m statistics report
app.post("/options-reports", (req, res) => {
  const report = req.body;
  if (!report || !report.zoneId) return res.status(400).json({ error: "Invalid options report payload" });
  report.receivedAt = new Date().toISOString();
  const reports = readOptionsReports();
  reports.push(report);
  writeOptionsReports(reports);
  console.log(
    `Options report: zone=${report.zoneId} symbol=${report.symbol} dir=${report.direction} status=${report.status} minsLeft=${report.minsBeforeExpiry}`,
  );
  res.status(201).json({ ok: true });
});

// Events: add
app.post("/events", (req, res) => {
  const { time, suspendMinutes } = req.body;
  if (!time) return res.status(400).json({ error: "time is required" });
  const event = {
    id: uuidv4(),
    time,
    suspendMinutes: parseInt(suspendMinutes) || 5,
    createdAt: new Date().toISOString(),
  };
  const events = readEvents();
  events.push(event);
  writeEvents(events);
  res.status(201).json(event);
});

// Events: clear all
app.delete("/events", (req, res) => {
  writeEvents([]);
  res.json({ cleared: true });
});

// ── Start ──────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Zone server running at http://localhost:${PORT}`);
});
