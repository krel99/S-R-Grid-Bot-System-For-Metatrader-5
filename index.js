const express = require("express");
const fs = require("fs");
const path = require("path");
const { v4: uuidv4 } = require("uuid");

const app = express();
const PORT = 3000;
const ZONES_FILE = path.join(__dirname, "zones.json");

app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

// ── Helpers ──────────────────────────────────────────────────────────────────

function readZones() {
  return JSON.parse(fs.readFileSync(ZONES_FILE, "utf8"));
}

function writeZones(zones) {
  fs.writeFileSync(ZONES_FILE, JSON.stringify(zones, null, 2));
}

function isAfterCutoff() {
  return new Date().getHours() >= 20;
}

// ── Routes ───────────────────────────────────────────────────────────────────

// Serve GUI
app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

// GUI: get all zones (for display)
app.get("/zones/all", (req, res) => {
  res.json(readZones());
});

// MT5: get zones for a symbol
app.get("/:symbol", (req, res) => {
  if (isAfterCutoff()) return res.json([]);
  const symbol = req.params.symbol.toUpperCase();
  const zones = readZones().filter((z) => z.symbol === symbol);
  res.json(zones);
});

// GUI: add a zone
app.post("/zones", (req, res) => {
  const { symbol, direction, strength, kind, price, from, to } = req.body;

  if (!symbol || !direction || !strength || !kind) {
    return res.status(400).json({ error: "Missing required fields: symbol, direction, strength, kind" });
  }
  if (!["buy", "sell"].includes(direction)) {
    return res.status(400).json({ error: "direction must be buy or sell" });
  }
  if (!["strong", "regular"].includes(strength)) {
    return res.status(400).json({ error: "strength must be strong or regular" });
  }
  if (!["point", "zone"].includes(kind)) {
    return res.status(400).json({ error: "kind must be point or zone" });
  }
  if (kind === "point" && price == null) {
    return res.status(400).json({ error: "price is required for kind=point" });
  }
  if (kind === "zone" && (from == null || to == null)) {
    return res.status(400).json({ error: "from and to are required for kind=zone" });
  }

  const zone = {
    id: uuidv4(),
    symbol: symbol.toUpperCase(),
    direction,
    strength,
    kind,
    ...(kind === "point" ? { price: parseFloat(price) } : { from: parseFloat(from), to: parseFloat(to) }),
    createdAt: new Date().toISOString(),
  };

  const zones = readZones();
  zones.push(zone);
  writeZones(zones);

  res.status(201).json(zone);
});

// GUI: delete a zone
app.delete("/zones/:symbol", (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  const zones = readZones();
  const filtered = zones.filter((z) => z.symbol !== symbol);
  writeZones(filtered);
  res.json({ cleared: symbol, removed: zones.length - filtered.length });
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Zone server running at http://localhost:${PORT}`);
});
