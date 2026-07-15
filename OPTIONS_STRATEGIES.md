# optionsRaider — Strategy Variants

Options zones are entered via the GUI with direction `above` (long) or `below` (short) and an expiry time (default `16:00` local time). The EA fetches them from `GET /options/:symbol`.

**Rule common to all versions:**

- Only **one zone** is ever active at a time, selected by the `PickZone` priority system.
- Priority: (1) zone with an open position → (2) already-activated zone → (3) closest-to-price zone entering the window.
- An activated zone holds its slot until it expires or its stop loss is hit. Price trading through the strike level does **not** remove a zone from its slot — it remains active for the full window. An SL hit sets the zone to `closed` immediately, ending all activity on that level for the session. No replacement trade is opened.
- A long and a short can **never** be open simultaneously.
- All positions are closed `InpCloseMinsBeforeExpiry` (default 3) minutes before expiry. No take-profit.
- SL is placed `min(2×ATR, InpMaxSLPips)` beyond the **strike level** (not entry price).
- Only `optionsRaider.mq5` (base) sends reports to the server.

---

## File Reference

| File                   | Magic    | Entry filter                  | Sizing         | Reports |
| ---------------------- | -------- | ----------------------------- | -------------- | ------- |
| `optionsRaider.mq5`    | 20260401 | Engulfing forming near strike | Fixed lot      | ✅ Yes  |
| `optionsRaider-v4.mq5` | 20260402 | Strike touch + engulfing      | Fixed lot      | No      |
| `optionsRaider-v6.mq5` | 20260403 | Engulfing forming near strike | ATR-normalised | No      |
| `optionsRaider-v7.mq5` | 20260404 | Proximity to opposite strike  | Fixed lot      | No      |

---

## Base — `optionsRaider.mq5`

**Entry:** Within the 150-minute activation window, if price is within `InpProximityATRs × ATR` of the strike and a bullish (above) or bearish (below) engulfing pattern is forming on the M5 chart — confirmed in real time without waiting for the bar to close.

**Reporting:** POSTs a JSON report to `POST /options-reports` on every new M5 bar while a zone is active. Payload includes:

- `optimalEntryPrice` — lowest ask (long) or highest bid (short) seen across the full monitoring window.
- `optimalMinsLeft` — how many minutes before expiry that optimal entry price occurred.
- `maxPotentialPips` — pips from `optimalEntryPrice` to current price (perfect-entry simulation).
- `currentPnlPips` — actual PnL of the open position.
- `status` — `monitoring` | `open` | `closed`.

**When to use:** Default choice. Provides the signal quality of an engulfing filter plus full data logging for strategy analysis.

---

## V4 — `optionsRaider-v4.mq5` · Strike-Touch Prerequisite Filter

**Additional input:** `InpTouchPips` (default 5) — pips from strike to qualify as a touch.

**Entry:** Same engulfing logic as base, but the engulfing signal is **only armed after price has touched the strike level** (come within `InpTouchPips`) at least once during the monitoring window. Until that touch occurs, no entry is attempted regardless of candle patterns elsewhere.

**Rationale:** An engulfing candle near an untested level can be coincidental. A level that price has already probed and bounced from confirms that institutional resting orders are physically present at that price. The touch arms the trigger; the engulfing pulls it.

**`levelTouched`** flag persists across polls so a server re-poll mid-session does not reset the touch state.

**When to use:** When the operator wants higher signal quality at the cost of occasionally missing entries on levels that are approached for the first time only once. Best on days where the option level is clearly visible in the order book and price has been oscillating around it before the trade window.

---

## V6 — `optionsRaider-v6.mq5` · Session ATR Normalisation

**Additional inputs:**

| Input                | Default | Description                                                 |
| -------------------- | ------- | ----------------------------------------------------------- |
| `InpBaselineATRBars` | 20      | M5 bars used to compute session baseline ATR                |
| `InpHighVolThresh`   | 1.4     | `currentATR / baseline` ratio that triggers high-vol regime |
| `InpLowVolThresh`    | 0.7     | Ratio that triggers low-vol regime                          |
| `InpHighVolLotMult`  | 0.6     | Lot multiplier in high-vol regime                           |
| `InpLowVolLotMult`   | 1.4     | Lot multiplier in low-vol regime                            |
| `InpHighVolSLPips`   | 15      | SL cap in high-vol regime                                   |
| `InpLowVolSLPips`    | 7       | SL cap in low-vol regime                                    |

**Entry:** Identical engulfing logic to base. What changes is _how much_ is risked and how wide the SL is.

**Regimes:**

- **Low-vol** (`ratio < 0.7`): Market is quiet. The option magnetic effect is stronger and moves are cleaner. Lot size is increased (`×1.4`), SL cap is tightened to 7 pips.
- **Normal** (`0.7–1.4`): Base lot size, `InpMaxSLPips` cap unchanged.
- **High-vol** (`ratio > 1.4`): Likely a news day. Random spikes can blow through a tight SL before the option pin takes hold. Lot size is reduced (`×0.6`), SL cap is widened to 15 pips to survive the noise.

**Baseline** is computed from the last 20 completed M5 bars at `OnInit` and refreshes each UTC calendar day. A forced re-poll is triggered on each day reset to flush stale zones.

The active regime and ratio are logged on every M5 bar for manual review.

**When to use:** When the operator trades across varied market conditions and wants the EA to self-calibrate rather than using fixed parameters for every day. Particularly useful during weeks that include both quiet Asian sessions and high-impact US data releases.

---

## V7 — `optionsRaider-v7.mq5` · Immediate Market Entry at Activation

**Entry:** No pattern filter. Once a zone enters the activation window, the EA opens a market position **immediately** provided that the current price is closer to this option's strike than to the nearest strike in the **opposite direction** (i.e. closest `above` zone vs. closest `below` zone). If no opposite-direction zone exists for the symbol on that day, the position is opened unconditionally.

The proximity check runs every 30 seconds throughout the window. The trade fires on the first tick where the condition is satisfied.

**Rationale:** The Czech analysis states the option level acts as a price magnet. If price is already near the strike 150 minutes before expiry, it is by definition gravitating toward it — no candle confirmation adds meaningful probability. The opposite-direction comparison ensures we are not entering into the teeth of a competing institutional level that is closer.

**Example:** EURUSD has an `above` zone at 1.0950 and a `below` zone at 1.1020. Current price is 1.0965. Distance to `above` = 15 pip, distance to `below` = 55 pip. Condition satisfied → open long immediately.

**When to use:** When the operator has high conviction in the option level (large size entered in the GUI) and wants the earliest possible entry to maximise time in the position. Accepts a lower entry confirmation bar in exchange for more time for the move to develop. Higher win rate expected on strong option days; higher SL frequency expected on weak ones compared to base.

---

## Timezone Note

All versions use `InpLocalTZOffsetHours` (default `1`) to convert the operator-entered expiry time (CZ local) to UTC for comparison with `TimeGMT()`. Set to `2` during CEST (summer). The default `16:00` GUI entry corresponds to `15:00 UTC` in CET and `14:00 UTC` in CEST — both equal to `10:00 New York ET`, matching the standard FX option cut.
