# ZoneTrader — Agent Reference

> **Process note:** When testing the server, always kill any stale process on port 3000 before starting a new one: `kill $(lsof -ti:3000) 2>/dev/null; sleep 1`. Previous shell sessions leave Node processes alive on the PTY even after the shell exits. A stale old-code server silently intercepts requests and returns data without new fields like `date` or `time`, causing confusing test failures.

This document describes the full system for any AI agent working on this codebase.
Do not modify existing `.mq5` files. New EA files may be created.

---

## System Overview

A two-component trading system for manually-defined price levels:

1. **Zone Server** — Node.js/Express app that stores zones and events, serves them via REST API, and provides a browser GUI for fast input before each session.
2. **MT5 Expert Advisors** — poll the server on a timer, parse the zone list, and execute trades autonomously during the day.

The operator identifies price levels and events before the session opens, enters them in the GUI, and the EA handles execution.

---

## Directory Structure

```
zoneTrader/
├── index.js                  # Zone + events server (Express)
├── zones.json                # Flat-file zone store (starts as [])
├── events.json               # Flat-file event store (created on first POST)
├── reports.json              # Flat-file report store (created on first POST from EA)
├── public/
│   └── index.html            # Single-page GUI (vanilla JS, no dependencies)
├── zoneRaider.mq5            # v1 — REFERENCE ONLY
├── zoneRaider-aggr.mq5       # v2A — closest to working, USE AS BASE
├── zoneRaider-reporter.mq5   # v3 — broken reporter, reference for ideas
├── package.json
└── AGENTS.md                 # this file
```

---

## Zone Server (`index.js`)

### Storage

- `zones.json` — flat JSON array, read/written synchronously on every request.
- `events.json` — flat JSON array for trading events. Created automatically on first POST. `readEvents()` returns `[]` if the file does not exist yet.
- No database. No migrations.

### Route Order Note

`GET /events` **must** be defined before the wildcard `GET /:symbol`, otherwise Express would match `/events` as a symbol lookup. The current file maintains this order. Do not reorder routes.

### REST API

| Method | Route            | Consumer | Description                                                   |
| ------ | ---------------- | -------- | ------------------------------------------------------------- |
| GET    | `/`              | Browser  | Serves `public/index.html`                                    |
| GET    | `/zones/all`     | GUI      | Returns all stored zones                                      |
| GET    | `/events`        | GUI / EA | Returns all stored events (sorted client-side)                |
| GET    | `/:symbol`       | MT5 EA   | Returns zones for that symbol; returns `[]` if hour >= 20 UTC |
| POST   | `/zones`         | GUI      | Validates and appends a zone                                  |
| DELETE | `/zones/:symbol` | GUI      | Deletes **all** zones for a symbol (not per-ID)               |
| POST   | `/events`        | GUI      | Appends a trading event                                       |
| DELETE | `/events`        | GUI      | Clears all events                                             |

There is **no** `/reports` endpoint — `zoneRaider-reporter.mq5` POSTs there but it will 404.

### Zone Schema

```json
{
  "id": "uuid-v4",
  "symbol": "EURUSD",
  "direction": "buy" | "sell" | "above" | "below",
  "strength": "strong" | "regular",
  "watchedOnly": false,
  "kind": "point" | "zone",
  "price": 1.08500,          // only if kind=point
  "from": 1.08400,           // only if kind=zone
  "to": 1.08600,             // only if kind=zone
  "size": "small" | "medium" | "large",  // options zones only
  "time": "16:00",           // options zones only — HH:MM entry/expiry time
  "date": "2026-03-20",      // server-set: todayDate() at time of creation
  "createdAt": "ISO-8601"
}
```

**Field notes:**

- `direction` — `"buy"` / `"sell"` are S/R zones; `"above"` / `"below"` are options zones. Both share the same endpoint and storage.
- `watchedOnly` — always present on S/R zones (defaults `false`). `true` means the operator is watching the level but does **not** believe institutional limit orders are resting there. Always `false` on options zones (enforced client-side).
- `size` — `"small"` / `"medium"` / `"large"`. Present only on options zones. Controlled by a per-row S/M/L radio in the GUI. Omitted from S/R zones entirely.
- `time` — `"HH:MM"` string. Present only on options zones. Represents the intended entry or expiry time. Defaults to `"16:00"` in the GUI. Omitted from S/R zones.
- `date` — set server-side via `todayDate()`. Used by `GET /:symbol` to filter zones to today only. Also used client-side to mark zones as expired in the Zone Log.
- `kind` — options zones are always `"point"` (enforced client-side). S/R zones can be `"point"` or `"zone"`.

### Event Schema

```json
{
  "id": "uuid-v4",
  "time": "08:30",
  "suspendMinutes": 5,
  "createdAt": "ISO-8601"
}
```

`time` is a plain `"HH:MM"` string as entered by the operator. `suspendMinutes` defaults to `5` if not provided or not a valid integer. Events are intended to be used by the EA to suspend trading activity around high-impact news releases — the EA-side logic for this does not exist yet.

### Time Gate

`isAfterCutoff()` returns `true` when `new Date().getHours() >= 20`. At that point `GET /:symbol` returns `[]`. Hard-coded — no env variable.

---

## GUI (`public/index.html`)

Pure vanilla JS, single file, no build step, no frameworks, IBM Plex Mono throughout.

### Hardcoded Symbols

```js
const SYMBOLS = ["USDJPY", "EURUSD", "GBPUSD"];
```

### Page Structure (top to bottom)

1. **Header** — title + live clock
2. **Events block** — 3-column bulk event input, expandable with `+ Add Row`
3. **Symbol blocks** — one block per symbol, single-column layout, BUY/SELL rows with inline ABOVE/BELOW options
4. **Zone Log** — all stored zones, S/R and options differentiated visually

### Events Block

- Rendered by `renderEvents()` into `#eventsGrid` (CSS grid, 3 columns).
- Starts with 3 cells (1 row × 3 columns). `addEventRow()` adds 3 more cells, saving and restoring filled values across the re-render.
- Each cell: `TIME` (`type="time"`) + `SUSPEND` (`type="number"`, default 5, 36px wide) + `min` label.
- `+ Add Row` button is in `.events-footer` to the left of `+ Submit Events`.
- `submitEvents(btn)` collects only cells where `time` is non-empty, POSTs each to `/events` sequentially, clears all cells on success.
- `eventCount` tracks the current total number of cells (always a multiple of 3).
- CSS: `.event-cell:nth-child(3n)` removes the right border on every 3rd cell; `.event-cell:nth-last-child(-n+3)` removes the bottom border from the last row of cells.

### Symbol Blocks (`buildUI`)

- Layout: **single column** — no grid. Each `.block` stacks vertically.
- Each symbol block header: symbol name only (no size radio — size is per options row).
- Rows generated by `buildRow(symbol, dir)` for each direction in `["sell", "buy"]`.

### Row Layout — S/R + Options Inline

Each `.row` is a flex container with two equal halves separated by a 1px `.row-split` divider:

```
.row (flex, align-items: stretch)
  .row-sr (flex: 1)
    .row-badge  — direction label (SELL / BUY), coloured
    input[number] × 3  — level | from : to
    .strong-wrap — STR checkbox (gold)
    .watch-wrap  — W.ONLY checkbox (blue)
  .row-split (1px divider)
  .row-opt (flex: 1)
    .row-badge  — direction label (BELOW / ABOVE), same colour as SR side
    input[number] × 1  — level only (no zone range for options)
    input[time]         — entry/expiry time, default "16:00"
    .opt-size-group     — S / M / L radio (per row, not per symbol)
```

**Options side rules:**

- Only one price input — no `from`/`to` zone range.
- No STR or W.ONLY checkboxes — these are replaced by the S/M/L size radio.
- Options cannot be `watchedOnly` — always submitted as `watchedOnly: false`.
- `kind` is always `"point"` for options — enforced in `submitSymbol`.
- Size radio `name` includes the row index: `opt_${symbol}_${optDir}_${i}_sz` — each row is independent.

### Direction → Options Direction Mapping

```js
const OPT_DIR = { sell: "below", buy: "above" };
```

SELL rows → BELOW options (same red colour). BUY rows → ABOVE options (same green colour).

### Submit (`submitSymbol`)

Single submit button per symbol collects both S/R and options from all rows in one pass:

1. For each `dir` in `["sell", "buy"]`, for each row `i`:
   - Reads S/R inputs; if price or from+to is filled, pushes zone with `direction: dir`, `strength`, `watchedOnly`, `kind`.
   - Reads options price; if filled, reads `time` and size radio, pushes zone with `direction: OPT_DIR[dir]`, `strength: "regular"`, `watchedOnly: false`, `kind: "point"`, `size`, `time`.
2. After successful POST of all zones, clears S/R inputs/checkboxes and resets options price to `""`, time to `"16:00"`, size radio to `"medium"`.

### Number Input Scoping

Number inputs are styled via `.row-sr input[type="number"]` and `.row-opt input[type="number"]` (width 68px), **not** a global rule. This avoids conflicting with the events block's narrow 36px suspend inputs (scoped via `.event-cell input[type="number"]`).

### Zone Log (`loadZones`)

Fetches `GET /zones/all`, sorts newest-first by `date` then `createdAt`. Renders differently for S/R vs options:

**S/R zone item:**

```
symbol | direction | STRONG/REGULAR | [W.ONLY?] | price-or-range | date/time | [EXPIRED?]
```

**Options zone item** (`.zone-item.is-opt`, left border accent):

```
symbol | direction | OPT | [S/M/L] | [HH:MM] | price | date/time | [EXPIRED?]
```

- `z-opt-tag` — grey `OPT` badge, background-filled.
- `z-size` — single uppercased letter (`S`/`M`/`L`), muted bordered tag.
- `z-etime` — the options `time` field in muted monospace.
- `z-watched` badge only shown on S/R zones when `watchedOnly === true`.
- Expired zones: `z.date !== today` → `.expired` class (opacity 0.38, desaturated).

### CSS Variables

```css
--watched: #1455b3; /* blue — W.ONLY checkbox and badge */
```

---

## MT5 Expert Advisors

All EAs share the same polling architecture:

- `OnInit` → set up indicator handles, start `EventSetTimer`.
- `OnTimer` → check day/weekend/EOD, poll server on interval.
- `OnTick` → real-time work (trailing, fill detection, bar detection).
- Manual JSON parser — no library. Uses `StringFind` / `StringSubstr` to walk JSON character by character.
- Magic numbers differ per EA so MT5 can distinguish their orders.

### Common Zone Struct (all EAs)

```mq5
struct Zone {
  string id;
  string direction;  // "buy" | "sell"  (EAs do not yet use "above"/"below")
  string strength;   // "strong" | "regular"
  string kind;       // "point" | "zone"
  double price;
  double priceFrom;
  double priceTo;
  double zoneLow;    // computed: min(from,to) or price
  double zoneHigh;   // computed: max(from,to) or price
};
```

Current EAs do not parse `watchedOnly`, `size`, `time`, or the `"above"` / `"below"` directions. These fields are silently ignored because `JsonGetString` returns `""` for unknown keys, and the existing direction checks (`== "buy"` / `== "sell"`) will simply skip options zones.

### Budget & Position Sizing (all EAs)

Budget is allocated proportionally by weight:

- **Strong** zones → weight `1.0` (equal share).
- **Regular** zones → interleaved buy/sell by proximity to mid-price; closest pair weight `0.9`, next `0.8`, …, floor `0.1`.
- If total positions > `InpMaxPositions`, the tail (lowest-priority) is dropped.
- If min-lot risk × remaining count > `InpMaxDailyRisk`, tail is dropped until budget fits.

Lot sizing: `lots = floor((budget / riskPerLot) / lotStep) * lotStep`, clamped to `[lotMin, lotMax]`.

---

## EA: `zoneRaider.mq5` — v1 (Reference Only)

**Status:** Reference. Do not use as a base for new work.

- Places limit orders **once per day** after NY open (default 13:30 UTC).
- ATR-based SL/TP from `PERIOD_CURRENT`, 24-bar ATR.
- Entry: limit at zone boundary ± `InpEntryBuffer` pips.
- No trailing stop. `OnTick` is empty.
- EOD: cancels all pending + closes all positions, resets state.
- Magic: `20260301`.

---

## EA: `zoneRaider-aggr.mq5` — v2A (Closest to Working — USE AS BASE)

**Status:** Working system. Fixed pip SL/TP with a simple trailing stop.

### Key Parameters

| Input             | Default | Description                             |
| ----------------- | ------- | --------------------------------------- |
| `InpSLPips`       | 15      | Stop loss (normal mode)                 |
| `InpSLLowVolPips` | 10      | Stop loss (low-vol mode)                |
| `InpLowVolMode`   | false   | Toggle low-vol SL                       |
| `InpTPPips`       | 20      | Take profit                             |
| `InpMaxDailyRisk` | 500.0   | Daily risk budget ($)                   |
| `InpMaxPositions` | 6       | Max simultaneous positions              |
| `InpPollMinutes`  | 10      | Poll interval                           |
| `InpNYOpenHour`   | 13      | NY open hour (UTC)                      |
| `InpNYOpenMinute` | 30      | NY open minute (UTC)                    |
| `InpEODHour`      | 21      | EOD close hour (UTC)                    |
| `InpEntryBuffer`  | 0       | Pips past zone boundary for limit entry |

### Execution Flow

1. Timer fires every 30 seconds.
2. Day reset on `day_of_year` change.
3. EOD at `InpEODHour`: `CloseAndReset()` → cancels pending, closes positions, clears state.
4. If `g_ordersPlaced`, does nothing until next day.
5. After NY open, polls once. If zones loaded → places all limit orders → sets `g_ordersPlaced = true`.
6. Before NY open, polls on `InpPollMinutes` interval (pre-loading zones).

### Trailing Stop (Current — Suboptimal)

`TrailStop(idx)` on every tick:

- Buy: `newSL = BID - slDistance`
- Sell: `newSL = ASK + slDistance`
- Only updates if the new SL improves on the current.

**Problem:** Pure fixed-pip trail, not swing-based. Aggressively trails on volatile moves and can stop out positions that would have recovered.

### Position Tracking

```mq5
struct TrackEntry {
  ulong    ticket;
  string   direction;
  double   entryPrice;
  double   slDistance;   // used for trailing calculation
  datetime openTime;
  bool     isOpen;
  string   closedBy;     // "SL" | "TP" | "4h" | "EOD" | "manual" | "unknown"
};
```

### 4-Hour Force Close

Any tracked position open for >= 4 hours is closed via market order. `closedBy = "4h"`.

### Magic: `20260301`

---

## EA: `zoneRaider-reporter.mq5` — v3 (Broken — Reference for Ideas)

**Status:** Not working end-to-end. The `/reports` endpoint does not exist on the server. Use only as a reference for the patterns listed below.

### Good Ideas to Carry Forward

- **Zone state machine** per zone: `ZW_WATCHING → ZW_IN_ZONE → ZW_DONE`
- **M5 candle-based entry signals** — waits for a confirmed close inside/near zone before entering at market. Buy = green M5 candle; Sell = red M5 candle.
- **Stale zone detection** — on each poll, marks zones where price has already passed through as `ZW_DONE`.
- **Fired-ID persistence** — `g_firedIds[]` survives re-polls; a zone cannot fire twice in one day even if the zone list is rebuilt from the server.
- **Swing-based trailing** (`SwingTrail`) — on each new M5 bar, finds the most recent confirmed swing low (buys) or swing high (sells) within `InpSwingLookback` bars and trails SL there. Significantly better than the fixed-pip trail in aggr.
- **Rich position tracking** — 5-minute price snapshots, max profit/loss in pips and ATR multiples, ATR at open time.
- **Weekend cap** on tracking window (`CapAtWeekend`).

### What Is Broken

- POSTs reports to `/reports` which does not exist — HTTP fails silently.
- Market entry (not limit orders) — potential slippage issues.

### Magic: `20260303`

---

## Data Flow Summary

```
Operator
  │ opens browser at localhost:3000
  │ enters levels (zones) and events in GUI
  └─> POST /zones   ──> zones.json
  └─> POST /events  ──> events.json

MT5 EA (on timer)
  └─> GET /:symbol  ──> zones.json (filtered, gated after 20:00)
        │ parses JSON manually
        │ computes entry/SL/TP
        └─> places limit orders via OrderSend()
              │ fills detected in OnTick()
              └─> trails SL, force-closes at 4h or EOD
```

Events data is stored server-side but not yet consumed by any EA.

---

## Known Issues & Limitations

### Server

1. **No per-zone deletion** — `DELETE /zones/:symbol` wipes all zones for a symbol. Zones are intentionally not individually deletable by design.
2. **No `/reports` endpoint** — reporter EA fails silently.
3. **Hard-coded 20:00 cutoff** — not configurable without editing source.
4. **Synchronous file I/O** — fine for current volume; would block the event loop under heavy load.
5. **Events not consumed by any EA** — stored correctly, but no EA polls `/events` yet.

### GUI

6. **Hard-coded symbol list** — adding/removing a symbol requires editing `SYMBOLS` in `index.html`.
7. **No zone type beyond `watchedOnly`** — future zone types (e.g. institutional order blocks vs watched S/R) will require schema and UI changes.
8. **No auto-refresh of zone log** — only updates on page load or after a submit.

### EAs

9. **EAs ignore `watchedOnly`, `size`, `"above"`, `"below"`** — the new schema fields are stored but no EA acts on them yet. Options zones (`above`/`below`) will be silently skipped by current EAs since they only match `"buy"` / `"sell"` directions.
10. **Single poll-and-place** (aggr) — if zones update mid-session, the EA won't pick them up (`g_ordersPlaced` is already set).
11. **Fixed-pip trailing** (aggr) — not swing-based; can stop out on spike moves.
12. **No re-entry logic** — cancelled limit orders are not re-placed.
13. **4-hour hard close** — inflexible for strong trend trades.
14. **Manual JSON parser** — fragile; new nested fields or type changes could silently break parsing.

---

## Approved Suggestions & Status

| #   | What                                                                                           | Status         |
| --- | ---------------------------------------------------------------------------------------------- | -------------- |
| S3  | Zone type field (`watchedOnly`), options direction (`above`/`below`), size, time               | ✅ Implemented |
| S3+ | Options inputs inline on same row as S/R; per-row S/M/L radio; events as 3-col expandable grid | ✅ Implemented |
| S6  | Shared JSON parser include (`JsonParser.mqh`)                                                  | Pending        |

### S6 — Shared JSON Parser (`JsonParser.mqh`)

Create a reusable MQL5 include file with a proper token-based or recursive-descent JSON parser. This reduces the risk of silent parse failures when the server response schema grows. Both `JsonGetString` and `JsonGetDouble` exist identically in all three EA files — the include would centralise them and be the foundation for parsing new fields like `watchedOnly` and `size`.

---

## Implementation Notes for Future EAs

- **Whitelist server URL** in MT5: Tools → Options → Expert Advisors → Allow WebRequest for `http://127.0.0.1:3000`.
- **Magic numbers** — avoid `20260301` and `20260303` (in use). Use `20260401` onward for new EAs.
- **Symbol suffix handling** — always provide `InpSymbolName` fallback to `_Symbol`. Some brokers append suffixes (e.g. `EURUSDm`).
- **Pip calculation** — `pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10`. Correct for 5-decimal FX and XAUUSD (point = 0.01).
- **Order filling** — `ORDER_FILLING_RETURN` for limit orders; `ORDER_FILLING_IOC` for market orders.
- **Broker compatibility** — use `TRADE_ACTION_SLTP` to modify SL only. Always check `OrderSend` return and log `res.retcode` on failure.
- **New fields to parse** — `watchedOnly`: use `JsonGetString(obj, "watchedOnly")` and compare to `"true"`. `size`: `JsonGetString(obj, "size")`. `time`: `JsonGetString(obj, "time")` — returns `"HH:MM"` string for options zones. `date`: `JsonGetString(obj, "date")` — returns `"YYYY-MM-DD"` string.
- **Directions to handle** — future EAs that support options zones must match `"above"` and `"below"` in addition to `"buy"` and `"sell"`. The `InpAllowLong` / `InpAllowShort` guards should be extended accordingly.
- **Server process** — always kill stale processes before starting: `kill $(lsof -ti:3000) 2>/dev/null`. A stale old-code server on port 3000 will silently intercept requests and return zones without newer fields like `date` or `time`, making changes appear broken.
