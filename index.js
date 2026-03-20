const express = require('express');
const fs      = require('fs');
const path    = require('path');
const { v4: uuidv4 } = require('uuid');

const app        = express();
const PORT       = 3000;
const ZONES_FILE   = path.join(__dirname, 'zones.json');
const REPORTS_FILE = path.join(__dirname, 'reports.json');

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ── Helpers ──────────────────────────────────────────────────────────────────

function readZones()          { return JSON.parse(fs.readFileSync(ZONES_FILE,   'utf8')); }
function writeZones(z)        { fs.writeFileSync(ZONES_FILE,   JSON.stringify(z, null, 2)); }
function readReports()        {
  if (!fs.existsSync(REPORTS_FILE)) return [];
  return JSON.parse(fs.readFileSync(REPORTS_FILE, 'utf8'));
}
function writeReports(r)      { fs.writeFileSync(REPORTS_FILE, JSON.stringify(r, null, 2)); }
function isAfterCutoff()      { return new Date().getHours() >= 20; }
function todayDate()          { return new Date().toISOString().slice(0, 10); }

// ── Routes ───────────────────────────────────────────────────────────────────

// Serve GUI
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// GUI: full zone history, no filtering
app.get('/zones/all', (req, res) => {
  res.json(readZones());
});

// EA: fetch a single zone by ID (used for reports)
app.get('/zones/:id', (req, res) => {
  const zone = readZones().find(z => z.id === req.params.id);
  if (!zone) return res.status(404).json({ error: 'Zone not found' });
  res.json(zone);
});

// EA: active zones for a symbol (today only, before 20:00)
app.get('/:symbol', (req, res) => {
  if (isAfterCutoff()) return res.json([]);
  const symbol = req.params.symbol.toUpperCase();
  const today  = todayDate();
  const result = readZones().filter(z => z.symbol === symbol && z.date === today);
  res.json(result);
});

// GUI: add a zone
app.post('/zones', (req, res) => {
  const { symbol, direction, strength, kind, price, from, to } = req.body;

  if (!symbol || !direction || !strength || !kind)
    return res.status(400).json({ error: 'Missing required fields' });
  if (!['buy','sell'].includes(direction))
    return res.status(400).json({ error: 'direction must be buy or sell' });
  if (!['strong','regular'].includes(strength))
    return res.status(400).json({ error: 'strength must be strong or regular' });
  if (!['point','zone'].includes(kind))
    return res.status(400).json({ error: 'kind must be point or zone' });
  if (kind === 'point' && price == null)
    return res.status(400).json({ error: 'price required for kind=point' });
  if (kind === 'zone' && (from == null || to == null))
    return res.status(400).json({ error: 'from and to required for kind=zone' });

  const zone = {
    id:        uuidv4(),
    symbol:    symbol.toUpperCase(),
    direction, strength, kind,
    ...(kind === 'point'
      ? { price: parseFloat(price) }
      : { from: parseFloat(from), to: parseFloat(to) }),
    date:      todayDate(),
    createdAt: new Date().toISOString(),
  };

  const zones = readZones();
  zones.push(zone);
  writeZones(zones);
  res.status(201).json(zone);
});

// GUI: clear all zones for a symbol
app.delete('/zones/:symbol', (req, res) => {
  const symbol  = req.params.symbol.toUpperCase();
  const zones   = readZones();
  const filtered = zones.filter(z => z.symbol !== symbol);
  writeZones(filtered);
  res.json({ cleared: symbol, removed: zones.length - filtered.length });
});

// EA: receive a position report
app.post('/reports', (req, res) => {
  const report  = req.body;
  if (!report || !report.ticket)
    return res.status(400).json({ error: 'Invalid report payload' });

  report.receivedAt = new Date().toISOString();
  const reports = readReports();
  reports.push(report);
  writeReports(reports);
  console.log(`Report received: ticket=${report.ticket} symbol=${report.symbol} closedBy=${report.closedBy}`);
  res.status(201).json({ ok: true });
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Zone server running at http://localhost:${PORT}`);
});
