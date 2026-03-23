//+------------------------------------------------------------------+
//| optionsRaider.mq5                                                |
//| Trades toward FX option expiration strikes on the M5 chart       |
//|                                                                  |
//| Strategy:                                                        |
//|  • Polls GET /options/:symbol for "above" / "below" zones        |
//|  • Activates InpActivationMins (150) minutes before expiry       |
//|  • "above" → long  when bid ≤ strike + 1×ATR + engulfing        |
//|  • "below" → short when ask ≥ strike − 1×ATR + engulfing        |
//|  • Engulfing confirmed in real-time (no bar-close required)      |
//|  • SL = min(2×ATR, InpMaxSLPips pips) below/above the strike    |
//|  • No TP — closed InpCloseMinsBeforeExpiry min before expiry     |
//|  • POSTs a statistics report to /options-reports on every M5 bar |
//|                                                                  |
//| Setup:                                                           |
//|  MT5 → Tools → Options → Expert Advisors → Allow WebRequest for  |
//|  http://127.0.0.1:3000                                           |
//|  Magic: 20260401  (do not reuse 20260301 or 20260303)            |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

//--- Inputs
input string InpServerURL             = "http://127.0.0.1:3000"; // Zone server URL
input string InpSymbolName            = "";    // Symbol override (blank = chart symbol)
input int    InpLocalTZOffsetHours    = 0;     // Expiry-time UTC offset (CET=1, CEST=2)
input int    InpATRPeriod             = 14;    // ATR period (M5 bars)
input double InpSLATRMult             = 2.0;   // SL distance: N × ATR from strike
input int    InpMaxSLPips             = 10;    // SL hard cap (pips)
input double InpProximityATRs         = 1.0;   // Entry band: N × ATR from strike
input int    InpActivationMins        = 150;   // Start watching N minutes before expiry
input int    InpCloseMinsBeforeExpiry = 3;     // Close position N minutes before expiry
input double InpLotSize               = 0.0;   // Lot size (0.0 = broker minimum)
input int    InpPollMinutes           = 10;    // Zone poll interval (minutes)

//--- Zone state machine
struct OptionsZone
  {
   string   id;
   string   direction;         // "above" → long  |  "below" → short
   double   price;             // option strike
   string   expiryTime;        // "HH:MM" in operator local time
   string   date;              // "YYYY-MM-DD"
   bool     activated;         // entered InpActivationMins window
   bool     tradeFired;        // entry order sent
   bool     closed;            // zone lifecycle complete for this session
   ulong    ticket;            // position ticket (0 until trade placed)
   // Optimal-entry tracking across the entire monitoring window:
   // Answers "when was price at its most favourable entry point?"
   // long  → lowest ask  seen (cheapest buy)
   // short → highest bid seen (most expensive sell)
   double   optimalEntry;      // best entry price observed
   int      optimalMinsLeft;   // mins before expiry when that occurred
  };

//--- Globals
OptionsZone g_zones[];
int         g_zoneCount    = 0;
long        g_magic        = 20260401;

string      g_symbol       = "";
datetime    g_lastPoll     = 0;
int         g_lastBarCount = 0;

//+------------------------------------------------------------------+
//| Utilities                                                         |
//+------------------------------------------------------------------+
double PipSize()
  {
   return SymbolInfoDouble(g_symbol, SYMBOL_POINT) * 10.0;
  }

// Compute ATR as the simple mean of True Range over the last InpATRPeriod
// completed M5 bars.  Uses raw OHLC so no indicator handle — and no
// "cannot load indicator Average True Range" dependency — is needed.
double GetATR()
  {
   int    period = InpATRPeriod;
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);
   // period TRs each need the previous bar's close → fetch period+1 bars
   int need = period + 1;
   if(CopyHigh (g_symbol, PERIOD_M5, 1, need, hi) < need) return 0.0;
   if(CopyLow  (g_symbol, PERIOD_M5, 1, need, lo) < need) return 0.0;
   if(CopyClose(g_symbol, PERIOD_M5, 1, need, cl) < need) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < period; i++)
     {
      double tr = MathMax(hi[i] - lo[i],
                 MathMax(MathAbs(hi[i] - cl[i + 1]),
                         MathAbs(lo[i] - cl[i + 1])));
      sum += tr;
     }
   return sum / period;
  }

double CalcLots()
  {
   if(InpLotSize > 0.0) return NormalizeDouble(InpLotSize, 2);
   return SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
  }

// "HH:MM" string → minutes from midnight
int HHMMtoMins(const string t)
  {
   if(StringLen(t) < 5) return 0;
   return (int)StringToInteger(StringSubstr(t, 0, 2)) * 60
        + (int)StringToInteger(StringSubstr(t, 3, 2));
  }

// Current UTC time in minutes from midnight
int NowUTCMins()
  {
   MqlDateTime d;
   TimeToStruct(TimeGMT(), d);
   return d.hour * 60 + d.min;
  }

// Minutes remaining until zone expires (positive = time left)
// Operator enters local time; subtract UTC offset to compare against GMT
int MinsLeft(const OptionsZone &z)
  {
   int expiryUTC = HHMMtoMins(z.expiryTime) - InpLocalTZOffsetHours * 60;
   return expiryUTC - NowUTCMins();
  }

string TodayUTC()
  {
   MqlDateTime d;
   TimeToStruct(TimeGMT(), d);
   return StringFormat("%04d-%02d-%02d", d.year, d.mon, d.day);
  }

//+------------------------------------------------------------------+
//| JSON helpers (same pattern as zoneRaider-aggr)                    |
//+------------------------------------------------------------------+
string JsonGetString(const string obj, const string key)
  {
   int kPos  = StringFind(obj, "\"" + key + "\""); if(kPos  < 0) return "";
   int colon = StringFind(obj, ":", kPos);          if(colon < 0) return "";
   int q1    = StringFind(obj, "\"", colon + 1);    if(q1    < 0) return "";
   int q2    = StringFind(obj, "\"", q1 + 1);       if(q2    < 0) return "";
   return StringSubstr(obj, q1 + 1, q2 - q1 - 1);
  }

double JsonGetDouble(const string obj, const string key)
  {
   int kPos  = StringFind(obj, "\"" + key + "\""); if(kPos  < 0) return 0.0;
   int colon = StringFind(obj, ":", kPos);          if(colon < 0) return 0.0;
   int vStart = colon + 1, objLen = StringLen(obj);
   while(vStart < objLen && StringGetCharacter(obj, vStart) == ' ') vStart++;
   int vEnd = vStart;
   while(vEnd < objLen)
     {
      ushort ch = StringGetCharacter(obj, vEnd);
      if(ch == ',' || ch == '}' || ch == ' ' || ch == '\n' || ch == '\r') break;
      vEnd++;
     }
   return StringToDouble(StringSubstr(obj, vStart, vEnd - vStart));
  }

//+------------------------------------------------------------------+
//| Server: poll GET /options/:symbol                                 |
//+------------------------------------------------------------------+
void PollZones()
  {
   g_lastPoll = TimeCurrent();
   string url = InpServerURL + "/options/" + g_symbol;
   char   post[], resp[];
   string respHdrs;
   ArrayResize(post, 0);

   int code = WebRequest("GET", url, "", 5000, post, resp, respHdrs);
   if(code != 200)
     {
      PrintFormat("[optRaider] PollZones HTTP=%d err=%d url=%s (whitelist URL in MT5 settings)",
                  code, GetLastError(), url);
      return;
     }

   string body = CharArrayToString(resp);
   if(StringLen(body) < 2) return;

   string today = TodayUTC();

   // Preserve runtime state across polls so in-progress zones survive re-polls
   int         prevN = g_zoneCount;
   OptionsZone prev[];
   ArrayResize(prev, prevN);
   for(int i = 0; i < prevN; i++) prev[i] = g_zones[i];

   ArrayResize(g_zones, 0);
   g_zoneCount = 0;

   int pos = 0, blen = StringLen(body);
   while(pos < blen)
     {
      // Find next JSON object
      int os = StringFind(body, "{", pos);
      if(os < 0) break;

      // Find its matching closing brace
      int depth = 0, oe = -1;
      for(int k = os; k < blen; k++)
        {
         ushort c = StringGetCharacter(body, k);
         if(c == '{') depth++;
         else if(c == '}') { if(--depth == 0) { oe = k; break; } }
        }
      if(oe < 0) break;
      pos = oe + 1;

      string obj  = StringSubstr(body, os, oe - os + 1);
      string zid  = JsonGetString(obj, "id");
      string zdir = JsonGetString(obj, "direction");
      string zdt  = JsonGetString(obj, "date");
      string ztm  = JsonGetString(obj, "time");
      double zpx  = JsonGetDouble(obj, "price");

      if(zid == "" || (zdir != "above" && zdir != "below")) continue;
      if(zdt != today || zpx <= 0.0)                        continue;
      if(ztm == "") ztm = "16:00";

      OptionsZone z;
      z.id              = zid;
      z.direction       = zdir;
      z.price           = zpx;
      z.expiryTime      = ztm;
      z.date            = zdt;
      z.activated       = false;
      z.tradeFired      = false;
      z.closed          = false;
      z.ticket          = 0;
      z.optimalEntry    = 0.0;
      z.optimalMinsLeft = -1;

      // Restore runtime state if we already know this zone
      for(int i = 0; i < prevN; i++)
        {
         if(prev[i].id == zid)
           {
            z.activated       = prev[i].activated;
            z.tradeFired      = prev[i].tradeFired;
            z.closed          = prev[i].closed;
            z.ticket          = prev[i].ticket;
            z.optimalEntry    = prev[i].optimalEntry;
            z.optimalMinsLeft = prev[i].optimalMinsLeft;
            break;
           }
        }

      ArrayResize(g_zones, g_zoneCount + 1);
      g_zones[g_zoneCount++] = z;
     }

   PrintFormat("[optRaider] %d option zone(s) loaded for %s", g_zoneCount, g_symbol);
  }

//+------------------------------------------------------------------+
//| Server: POST /options-reports                                     |
//|                                                                  |
//| Payload fields:                                                  |
//|  optimalEntryPrice  — lowest ask (long) or highest bid (short)   |
//|                       seen across the whole monitoring window    |
//|  optimalMinsLeft    — how many minutes before expiry that was    |
//|  maxPotentialPips   — pips from optimalEntry to current price    |
//|                       (what we'd have made with perfect entry)   |
//+------------------------------------------------------------------+
void SendReport(OptionsZone &z, const string status, const string reason = "")
  {
   int    mLeft = MinsLeft(z);
   double atr   = GetATR();
   double pip   = PipSize();
   double bid   = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double entPx = 0.0, pnl = 0.0, maxPot = 0.0;

   if(z.ticket != 0 && PositionSelectByTicket(z.ticket)
      && PositionGetInteger(POSITION_MAGIC) == g_magic)
     {
      entPx = PositionGetDouble(POSITION_PRICE_OPEN);
      if(pip > 0.0)
        {
         pnl = (z.direction == "above") ? (bid - entPx) / pip
                                        : (entPx - ask) / pip;
         // maxPot: what PnL would be if we had entered at the optimal price
         if(z.optimalEntry > 0.0)
            maxPot = (z.direction == "above") ? (bid - z.optimalEntry) / pip
                                              : (z.optimalEntry - ask) / pip;
        }
     }

   string payload = StringFormat(
      "{"
      "\"zoneId\":\"%s\","
      "\"symbol\":\"%s\","
      "\"direction\":\"%s\","
      "\"strikePrice\":%.5f,"
      "\"expiryTime\":\"%s\","
      "\"date\":\"%s\","
      "\"ticket\":%I64u,"
      "\"entryPrice\":%.5f,"
      "\"minsBeforeExpiry\":%d,"
      "\"optimalEntryPrice\":%.5f,"
      "\"optimalMinsLeft\":%d,"
      "\"currentPnlPips\":%.2f,"
      "\"maxPotentialPips\":%.2f,"
      "\"atrValue\":%.5f,"
      "\"status\":\"%s\","
      "\"closeReason\":\"%s\","
      "\"reportedAt\":\"%s\""
      "}",
      z.id, g_symbol, z.direction,
      z.price, z.expiryTime, z.date,
      z.ticket, entPx, mLeft,
      z.optimalEntry, z.optimalMinsLeft,
      pnl, maxPot, atr,
      status, reason,
      TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS)
   );

   char   post[], resp[];
   string respHdrs;
   StringToCharArray(payload, post, 0, StringLen(payload));

   int code = WebRequest("POST", InpServerURL + "/options-reports",
                         "Content-Type: application/json\r\n",
                         5000, post, resp, respHdrs);
   if(code != 200 && code != 201)
      PrintFormat("[optRaider] SendReport HTTP=%d err=%d", code, GetLastError());
  }

//+------------------------------------------------------------------+
//| Engulfing detection — real-time, no bar-close confirmation       |
//+------------------------------------------------------------------+

// Bullish engulfing forming:
//   bar[1] is bearish, bar[0] opened at/below bar[1].close,
//   and the current BID has already risen above bar[1].open.
bool BullishEngulfingForming()
  {
   double p1o = iOpen(g_symbol, PERIOD_M5, 1);
   double p1c = iClose(g_symbol, PERIOD_M5, 1);
   if(p1c >= p1o) return false;           // bar[1] must be bearish

   double p0o = iOpen(g_symbol, PERIOD_M5, 0);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double tol = PipSize() * 0.5;         // half-pip tolerance for equality checks
   return (p0o <= p1c + tol) && (bid >= p1o - tol);
  }

// Bearish engulfing forming:
//   bar[1] is bullish, bar[0] opened at/above bar[1].close,
//   and the current ASK has already fallen below bar[1].open.
bool BearishEngulfingForming()
  {
   double p1o = iOpen(g_symbol, PERIOD_M5, 1);
   double p1c = iClose(g_symbol, PERIOD_M5, 1);
   if(p1c <= p1o) return false;           // bar[1] must be bullish

   double p0o = iOpen(g_symbol, PERIOD_M5, 0);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double tol = PipSize() * 0.5;
   return (p0o >= p1c - tol) && (ask <= p1o + tol);
  }

//+------------------------------------------------------------------+
//| Position helpers                                                  |
//+------------------------------------------------------------------+
bool IsPosOpen(ulong ticket)
  {
   if(ticket == 0 || !PositionSelectByTicket(ticket)) return false;
   return PositionGetInteger(POSITION_MAGIC) == g_magic;
  }

void ClosePos(ulong ticket, const string why)
  {
   if(!IsPosOpen(ticket)) return;
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_symbol;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.magic        = g_magic;
   req.type_filling = ORDER_FILLING_RETURN;
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
     { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(g_symbol, SYMBOL_BID); }
   else
     { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(g_symbol, SYMBOL_ASK); }
   if(!OrderSend(req, res))
      PrintFormat("[optRaider] ClosePos FAILED #%I64u retcode=%u why=%s", ticket, res.retcode, why);
   else
      PrintFormat("[optRaider] Closed #%I64u why=%s", ticket, why);
  }

bool OpenLong(OptionsZone &z)
  {
   double atr = GetATR();
   if(atr <= 0.0) { Print("[optRaider] OpenLong: ATR=0, skipping"); return false; }

   double ask    = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double pip    = PipSize();
   // SL sits below the strike level by min(2×ATR, MaxSLPips)
   double slDist = MathMin(atr * InpSLATRMult, InpMaxSLPips * pip);
   double sl     = NormalizeDouble(z.price - slDist,
                                   (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
   double lots   = CalcLots();

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_symbol;
   req.volume       = lots;
   req.type         = ORDER_TYPE_BUY;
   req.price        = ask;
   req.sl           = sl;
   req.tp           = 0.0;   // no take profit — held until pre-expiry close
   req.magic        = g_magic;
   req.comment      = "OPT:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider] OpenLong FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider] Long #%I64u ask=%.5f sl=%.5f lots=%.2f zone=%s",
               z.ticket, ask, sl, lots, z.id);
   return true;
  }

bool OpenShort(OptionsZone &z)
  {
   double atr = GetATR();
   if(atr <= 0.0) { Print("[optRaider] OpenShort: ATR=0, skipping"); return false; }

   double bid    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double pip    = PipSize();
   // SL sits above the strike level by min(2×ATR, MaxSLPips)
   double slDist = MathMin(atr * InpSLATRMult, InpMaxSLPips * pip);
   double sl     = NormalizeDouble(z.price + slDist,
                                   (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
   double lots   = CalcLots();

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_symbol;
   req.volume       = lots;
   req.type         = ORDER_TYPE_SELL;
   req.price        = bid;
   req.sl           = sl;
   req.tp           = 0.0;
   req.magic        = g_magic;
   req.comment      = "OPT:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider] OpenShort FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider] Short #%I64u bid=%.5f sl=%.5f lots=%.2f zone=%s",
               z.ticket, bid, sl, lots, z.id);
   return true;
  }

//+------------------------------------------------------------------+
//| Single-zone selector                                             |
//|                                                                  |
//| Ensures only one zone is ever evaluated at a time, preventing    |
//| simultaneous long + short and uncapped multi-zone exposure.      |
//|                                                                  |
//| Priority:                                                        |
//|  1. Zone holding an open position — managed to completion        |
//|  2. Already-activated zone — holds its slot until it expires or  |
//|     its SL is hit (closed=true in both cases removes it here).   |
//|     Price trading through the strike does NOT close the zone.    |
//|  3. Closest un-activated zone now inside the activation window   |
//+------------------------------------------------------------------+
int PickZone()
  {
   double mid = (SymbolInfoDouble(g_symbol, SYMBOL_BID) +
                 SymbolInfoDouble(g_symbol, SYMBOL_ASK)) / 2.0;

   // Priority 1: any zone currently holding an open position
   for(int i = 0; i < g_zoneCount; i++)
     {
      if(!g_zones[i].closed && g_zones[i].tradeFired && IsPosOpen(g_zones[i].ticket))
         return i;
     }

   // Priority 2: zone already activated (holds slot even if trade ended via SL)
   for(int i = 0; i < g_zoneCount; i++)
     {
      if(!g_zones[i].closed && g_zones[i].activated)
         return i;
     }

   // Priority 3: closest zone now entering the activation window
   int    bestIdx  = -1;
   double bestDist = DBL_MAX;
   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_zones[i].closed) continue;
      int mLeft = MinsLeft(g_zones[i]);
      if(mLeft < 0 || mLeft > InpActivationMins) continue;
      double dist = MathAbs(mid - g_zones[i].price);
      if(dist < bestDist) { bestDist = dist; bestIdx = i; }
     }
   return bestIdx;
  }

//+------------------------------------------------------------------+
//| Zone evaluation — called every 30 s from OnTimer                 |
//+------------------------------------------------------------------+
void EvaluateZone(OptionsZone &z)
  {
   if(z.closed) return;

   int    mLeft = MinsLeft(z);
   double bid   = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double atr   = GetATR();
   double pip   = PipSize();

   // ── 1. Past expiry — 10-minute grace, then force-close and retire ──
   if(mLeft < -10)
     {
      if(z.tradeFired && IsPosOpen(z.ticket))
        { ClosePos(z.ticket, "expired"); SendReport(z, "closed", "expired"); }
      z.closed = true;
      return;
     }

   // ── 2. Pre-expiry close window ────────────────────────────────────
   if(mLeft >= 0 && mLeft <= InpCloseMinsBeforeExpiry)
     {
      if(z.tradeFired && IsPosOpen(z.ticket))
        { ClosePos(z.ticket, "pre_expiry"); SendReport(z, "closed", "pre_expiry"); }
      z.closed = true;
      return;
     }

   // ── 3. Not yet inside activation window ──────────────────────────
   if(mLeft > InpActivationMins) return;

   // ── 4. First tick inside activation window ────────────────────────
   if(!z.activated)
     {
      z.activated = true;
      PrintFormat("[optRaider] Zone %s (%s @ %.5f exp %s) ACTIVATED — %d min to expiry",
                  z.id, z.direction, z.price, z.expiryTime, mLeft);
     }

   // ── 5. Optimal entry tracking (before and after trade open) ──────
   // Records the best possible entry price seen so far in this window.
   // Reported every bar so analysis can answer: "at which minute before
   // expiry was the perfect entry available, and how many pips did it offer?"
   if(z.direction == "above")
     {
      if(z.optimalEntry <= 0.0 || ask < z.optimalEntry)
        { z.optimalEntry = ask; z.optimalMinsLeft = mLeft; }
     }
   else
     {
      if(z.optimalEntry <= 0.0 || bid > z.optimalEntry)
        { z.optimalEntry = bid; z.optimalMinsLeft = mLeft; }
     }

   // ── 6. Detect external close (SL hit or manual) ──────────────────
   if(z.tradeFired)
     {
      if(!IsPosOpen(z.ticket))
        {
         PrintFormat("[optRaider] #%I64u closed externally (SL/manual) zone=%s",
                     z.ticket, z.id);
         SendReport(z, "closed", "sl_or_manual");
         z.closed = true;
        }
      return;   // never re-enter the same expiry zone
     }

   // ── 7. Entry: proximity + engulfing ──────────────────────────────
   if(atr <= 0.0) return;
   double band = atr * InpProximityATRs;

   // "above" (long):  bid must be within [strike − 3 pip, strike + 1 ATR]
   // "below" (short): ask must be within [strike − 1 ATR, strike + 3 pip]
   // The 3-pip buffer below/above the strike allows entry when price is
   // just touching the level from the correct side.
   bool near;
   if(z.direction == "above")
      near = (bid >= z.price - pip * 3.0) && (bid <= z.price + band);
   else
      near = (ask <= z.price + pip * 3.0) && (ask >= z.price - band);

   if(!near) return;

   if(z.direction == "above" && BullishEngulfingForming())
     {
      PrintFormat("[optRaider] Bullish engulfing forming near %.5f — long (zone %s %d min left)",
                  z.price, z.id, mLeft);
      OpenLong(z);
     }
   else if(z.direction == "below" && BearishEngulfingForming())
     {
      PrintFormat("[optRaider] Bearish engulfing forming near %.5f — short (zone %s %d min left)",
                  z.price, z.id, mLeft);
      OpenShort(z);
     }
  }

//+------------------------------------------------------------------+
//| New M5 bar: refresh optimal tracking, send 5-minute report       |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   int idx = PickZone();
   if(idx < 0) return;

   int mLeft = MinsLeft(g_zones[idx]);
   if(mLeft < -10 || mLeft > InpActivationMins) return;
   if(!g_zones[idx].activated) return;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(g_zones[idx].direction == "above")
     {
      if(g_zones[idx].optimalEntry <= 0.0 || ask < g_zones[idx].optimalEntry)
        { g_zones[idx].optimalEntry = ask; g_zones[idx].optimalMinsLeft = mLeft; }
     }
   else
     {
      if(g_zones[idx].optimalEntry <= 0.0 || bid > g_zones[idx].optimalEntry)
        { g_zones[idx].optimalEntry = bid; g_zones[idx].optimalMinsLeft = mLeft; }
     }

   string status;
   if(!g_zones[idx].tradeFired)                    status = "monitoring";
   else if(IsPosOpen(g_zones[idx].ticket))         status = "open";
   else                                            status = "closed";

   SendReport(g_zones[idx], status);
  }

//+------------------------------------------------------------------+
//| EA lifecycle                                                      |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = (InpSymbolName != "") ? InpSymbolName : _Symbol;

   if(Period() != PERIOD_M5)
      PrintFormat("[optRaider] WARNING — designed for M5 chart (current period=%d min)", Period());



   g_lastBarCount = Bars(g_symbol, PERIOD_M5);
   EventSetTimer(30);
   PollZones();

   PrintFormat("[optRaider] Ready — symbol=%s magic=%d TZ_offset=%dh lot=%.2f",
               g_symbol, g_magic, InpLocalTZOffsetHours,
               (InpLotSize > 0.0) ? InpLotSize : SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();

   Print("[optRaider] Deinitialized");
  }

//+------------------------------------------------------------------+
//| OnTimer — re-poll and run evaluation every 30 s                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(TimeCurrent() - g_lastPoll >= (datetime)(InpPollMinutes * 60))
      PollZones();

   int idx = PickZone();
   if(idx >= 0) EvaluateZone(g_zones[idx]);
  }

//+------------------------------------------------------------------+
//| OnTick — detect a new M5 bar and trigger bar-level reporting     |
//+------------------------------------------------------------------+
void OnTick()
  {
   int bars = Bars(g_symbol, PERIOD_M5);
   if(bars != g_lastBarCount)
     {
      g_lastBarCount = bars;
      OnNewBar();
     }
  }
//+------------------------------------------------------------------+
