//+------------------------------------------------------------------+
//| optionsRaider-v6.mq5                                             |
//| V6 — Session ATR Normalisation (Volatility Adapter)              |
//|                                                                  |
//| Difference from base optionsRaider:                              |
//|  • At session start, a baselineATR is computed from the last     |
//|    InpBaselineATRBars completed M5 bars.                         |
//|  • Before every entry, ratio = currentATR / baselineATR.        |
//|  • High-volatility day (ratio > InpHighVolThresh):               |
//|      lots × InpHighVolLotMult, SL cap = InpHighVolSLPips         |
//|  • Low-volatility day  (ratio < InpLowVolThresh):                |
//|      lots × InpLowVolLotMult,  SL cap = InpLowVolSLPips         |
//|  • Normal day: base lot size, InpMaxSLPips cap unchanged.        |
//|  • Baseline refreshes every calendar day (UTC).                  |
//|  • Only one zone is ever active at a time (PickZone selector).   |
//|    Priority: open position > activated zone > closest to price.  |
//|    SL hit closes the zone — no further trades on that level.     |
//|  • No server reporting — statistics sent by base EA only.        |
//|                                                                  |
//| Magic: 20260403                                                  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

//--- Inputs
input string InpServerURL             = "http://127.0.0.1:3000"; // Zone server URL
input string InpSymbolName            = "";    // Symbol override (blank = chart symbol)
input int    InpLocalTZOffsetHours    = 0;     // Expiry-time UTC offset (CET=1, CEST=2)
input int    InpATRPeriod             = 14;    // ATR period (M5 bars)
input int    InpBaselineATRBars       = 20;    // Bars used to compute session baseline ATR
input double InpSLATRMult             = 2.0;   // SL distance: N × ATR from strike
input int    InpMaxSLPips             = 10;    // SL cap — normal volatility (pips)
input int    InpHighVolSLPips         = 15;    // SL cap — high volatility (pips)
input int    InpLowVolSLPips          = 7;     // SL cap — low volatility (pips)
input double InpHighVolThresh         = 1.4;   // currentATR/baseline ratio → high-vol regime
input double InpLowVolThresh          = 0.7;   // currentATR/baseline ratio → low-vol regime
input double InpHighVolLotMult        = 0.6;   // Lot multiplier in high-vol regime
input double InpLowVolLotMult         = 1.4;   // Lot multiplier in low-vol regime
input double InpProximityATRs         = 1.0;   // Entry band: N × ATR from strike
input int    InpActivationMins        = 150;   // Start watching N minutes before expiry
input int    InpCloseMinsBeforeExpiry = 3;     // Close position N minutes before expiry
input double InpLotSize               = 0.0;   // Base lot size (0.0 = broker minimum)
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
  };

//--- Globals
OptionsZone g_zones[];
int         g_zoneCount    = 0;
long        g_magic        = 20260403;

string      g_symbol       = "";
datetime    g_lastPoll     = 0;
int         g_lastBarCount = 0;
double      g_baselineATR  = 0.0;   // computed at session start / day reset
int         g_lastDay      = -1;    // tracks UTC day-of-year for daily reset

//+------------------------------------------------------------------+
//| Utilities                                                         |
//+------------------------------------------------------------------+
double PipSize()
  {
   return SymbolInfoDouble(g_symbol, SYMBOL_POINT) * 10.0;
  }

// Compute ATR as a simple mean True Range over the last InpATRPeriod completed
// M5 bars.  Uses raw OHLC — no indicator handle or external file required.
double GetATR()
  {
   int    period = InpATRPeriod;
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);
   int need = period + 1; // period TRs each require the previous bar's close
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

// Compute baseline ATR as the mean of per-bar ATRs over the last
// InpBaselineATRBars completed M5 bars.  Uses raw OHLC — no indicator handle.
// Called once per day at the first timer tick after midnight UTC.
void ComputeBaselineATR()
  {
   int barsNeeded = InpBaselineATRBars + InpATRPeriod + 1;
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);
   if(CopyHigh (g_symbol, PERIOD_M5, 1, barsNeeded, hi) < barsNeeded) { g_baselineATR = 0.0; return; }
   if(CopyLow  (g_symbol, PERIOD_M5, 1, barsNeeded, lo) < barsNeeded) { g_baselineATR = 0.0; return; }
   if(CopyClose(g_symbol, PERIOD_M5, 1, barsNeeded, cl) < barsNeeded) { g_baselineATR = 0.0; return; }
   double sum = 0.0;
   for(int b = 0; b < InpBaselineATRBars; b++)
     {
      double atrSum = 0.0;
      for(int i = b; i < b + InpATRPeriod; i++)
        {
         double tr = MathMax(hi[i] - lo[i],
                    MathMax(MathAbs(hi[i] - cl[i + 1]),
                            MathAbs(lo[i] - cl[i + 1])));
         atrSum += tr;
        }
      sum += atrSum / InpATRPeriod;
     }
   g_baselineATR = sum / InpBaselineATRBars;
   PrintFormat("[optRaider-v6] Baseline ATR computed: %.5f (%d bars)", g_baselineATR, InpBaselineATRBars);
  }

// Returns the effective volatility regime:
//  1 = normal, 2 = high-vol, 0 = low-vol
int VolRegime()
  {
   if(g_baselineATR <= 0.0) return 1;     // no baseline yet — treat as normal
   double ratio = GetATR() / g_baselineATR;
   if(ratio > InpHighVolThresh) return 2; // high volatility
   if(ratio < InpLowVolThresh)  return 0; // low volatility
   return 1;                              // normal
  }

// Regime-adjusted lot size
double CalcLots()
  {
   double base = (InpLotSize > 0.0)
                  ? InpLotSize
                  : SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);

   double lots = base;
   int regime  = VolRegime();
   if(regime == 2) lots = base * InpHighVolLotMult;
   if(regime == 0) lots = base * InpLowVolLotMult;

   double lotMin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / lotStep) * lotStep;
   return NormalizeDouble(MathMax(lotMin, MathMin(lotMax, lots)), 2);
  }

// Regime-adjusted SL cap
int ActiveSLPips()
  {
   int regime = VolRegime();
   if(regime == 2) return InpHighVolSLPips;
   if(regime == 0) return InpLowVolSLPips;
   return InpMaxSLPips;
  }

int HHMMtoMins(const string t)
  {
   if(StringLen(t) < 5) return 0;
   return (int)StringToInteger(StringSubstr(t, 0, 2)) * 60
        + (int)StringToInteger(StringSubstr(t, 3, 2));
  }

int NowUTCMins()
  {
   MqlDateTime d;
   TimeToStruct(TimeGMT(), d);
   return d.hour * 60 + d.min;
  }

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
//| JSON helpers                                                      |
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
      PrintFormat("[optRaider-v6] PollZones HTTP=%d err=%d url=%s (whitelist URL in MT5 settings)",
                  code, GetLastError(), url);
      return;
     }

   string body = CharArrayToString(resp);
   if(StringLen(body) < 2) return;

   string today = TodayUTC();

   int         prevN = g_zoneCount;
   OptionsZone prev[];
   ArrayResize(prev, prevN);
   for(int i = 0; i < prevN; i++) prev[i] = g_zones[i];

   ArrayResize(g_zones, 0);
   g_zoneCount = 0;

   int pos = 0, blen = StringLen(body);
   while(pos < blen)
     {
      int os = StringFind(body, "{", pos);
      if(os < 0) break;

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
      z.id         = zid;
      z.direction  = zdir;
      z.price      = zpx;
      z.expiryTime = ztm;
      z.date       = zdt;
      z.activated  = false;
      z.tradeFired = false;
      z.closed     = false;
      z.ticket     = 0;

      for(int i = 0; i < prevN; i++)
        {
         if(prev[i].id == zid)
           {
            z.activated  = prev[i].activated;
            z.tradeFired = prev[i].tradeFired;
            z.closed     = prev[i].closed;
            z.ticket     = prev[i].ticket;
            break;
           }
        }

      ArrayResize(g_zones, g_zoneCount + 1);
      g_zones[g_zoneCount++] = z;
     }

   PrintFormat("[optRaider-v6] %d option zone(s) loaded for %s", g_zoneCount, g_symbol);
  }

//+------------------------------------------------------------------+
//| Engulfing detection — real-time, no bar-close confirmation       |
//+------------------------------------------------------------------+
bool BullishEngulfingForming()
  {
   double p1o = iOpen(g_symbol, PERIOD_M5, 1);
   double p1c = iClose(g_symbol, PERIOD_M5, 1);
   if(p1c >= p1o) return false;

   double p0o = iOpen(g_symbol, PERIOD_M5, 0);
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double tol = PipSize() * 0.5;
   return (p0o <= p1c + tol) && (bid >= p1o - tol);
  }

bool BearishEngulfingForming()
  {
   double p1o = iOpen(g_symbol, PERIOD_M5, 1);
   double p1c = iClose(g_symbol, PERIOD_M5, 1);
   if(p1c <= p1o) return false;

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
      PrintFormat("[optRaider-v6] ClosePos FAILED #%I64u retcode=%u why=%s", ticket, res.retcode, why);
   else
      PrintFormat("[optRaider-v6] Closed #%I64u why=%s", ticket, why);
  }

bool OpenLong(OptionsZone &z)
  {
   double atr    = GetATR();
   if(atr <= 0.0) { Print("[optRaider-v6] OpenLong: ATR=0, skipping"); return false; }

   double ask    = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double pip    = PipSize();
   double slCap  = ActiveSLPips() * pip;
   double slDist = MathMin(atr * InpSLATRMult, slCap);
   double sl     = NormalizeDouble(z.price - slDist,
                                   (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
   double lots   = CalcLots();
   int    regime = VolRegime();

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_symbol;
   req.volume       = lots;
   req.type         = ORDER_TYPE_BUY;
   req.price        = ask;
   req.sl           = sl;
   req.tp           = 0.0;
   req.magic        = g_magic;
   req.comment      = "OPT-V6:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider-v6] OpenLong FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider-v6] Long #%I64u ask=%.5f sl=%.5f lots=%.2f regime=%d zone=%s",
               z.ticket, ask, sl, lots, regime, z.id);
   return true;
  }

bool OpenShort(OptionsZone &z)
  {
   double atr    = GetATR();
   if(atr <= 0.0) { Print("[optRaider-v6] OpenShort: ATR=0, skipping"); return false; }

   double bid    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double pip    = PipSize();
   double slCap  = ActiveSLPips() * pip;
   double slDist = MathMin(atr * InpSLATRMult, slCap);
   double sl     = NormalizeDouble(z.price + slDist,
                                   (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS));
   double lots   = CalcLots();
   int    regime = VolRegime();

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_symbol;
   req.volume       = lots;
   req.type         = ORDER_TYPE_SELL;
   req.price        = bid;
   req.sl           = sl;
   req.tp           = 0.0;
   req.magic        = g_magic;
   req.comment      = "OPT-V6:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider-v6] OpenShort FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider-v6] Short #%I64u bid=%.5f sl=%.5f lots=%.2f regime=%d zone=%s",
               z.ticket, bid, sl, lots, regime, z.id);
   return true;
  }

//+------------------------------------------------------------------+
//| Single-zone selector                                             |
//|                                                                  |
//| Priority:                                                        |
//|  1. Zone holding an open position — managed to completion        |
//|  2. Already-activated zone — holds slot until expiry or SL.     |
//|     Price trading through the strike does NOT remove the zone.  |
//|     SL hit sets closed=true and removes it immediately.         |
//|  3. Closest un-activated zone now entering the window            |
//+------------------------------------------------------------------+
int PickZone()
  {
   double mid = (SymbolInfoDouble(g_symbol, SYMBOL_BID) +
                 SymbolInfoDouble(g_symbol, SYMBOL_ASK)) / 2.0;

   // Priority 1: open position
   for(int i = 0; i < g_zoneCount; i++)
      if(!g_zones[i].closed && g_zones[i].tradeFired && IsPosOpen(g_zones[i].ticket))
         return i;

   // Priority 2: already activated
   for(int i = 0; i < g_zoneCount; i++)
      if(!g_zones[i].closed && g_zones[i].activated)
         return i;

   // Priority 3: closest zone entering the window
   int bestIdx = -1; double bestDist = DBL_MAX;
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
//| Zone evaluation                                                   |
//+------------------------------------------------------------------+
void EvaluateZone(OptionsZone &z)
  {
   if(z.closed) return;

   int    mLeft = MinsLeft(z);
   double bid   = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double atr   = GetATR();
   double pip   = PipSize();

   // ── 1. Past expiry grace ──────────────────────────────────────────
   if(mLeft < -10)
     {
      if(z.tradeFired && IsPosOpen(z.ticket)) ClosePos(z.ticket, "expired");
      z.closed = true;
      return;
     }

   // ── 2. Pre-expiry close window ────────────────────────────────────
   if(mLeft >= 0 && mLeft <= InpCloseMinsBeforeExpiry)
     {
      if(z.tradeFired && IsPosOpen(z.ticket)) ClosePos(z.ticket, "pre_expiry");
      z.closed = true;
      return;
     }

   // ── 3. Not yet in activation window ──────────────────────────────
   if(mLeft > InpActivationMins) return;

   // ── 4. First tick in activation window ───────────────────────────
   if(!z.activated)
     {
      z.activated = true;
      int regime  = VolRegime();
      double ratio = (g_baselineATR > 0.0) ? atr / g_baselineATR : 1.0;
      PrintFormat("[optRaider-v6] Zone %s (%s @ %.5f exp %s) ACTIVATED — %d min left "
                  "regime=%d ratio=%.2f lots=%.2f slCap=%dpip",
                  z.id, z.direction, z.price, z.expiryTime, mLeft,
                  regime, ratio, CalcLots(), ActiveSLPips());
     }

   // ── 5. Detect external close ─────────────────────────────────────
   if(z.tradeFired)
     {
      if(!IsPosOpen(z.ticket))
        {
         PrintFormat("[optRaider-v6] #%I64u closed externally (SL/manual) zone=%s",
                     z.ticket, z.id);
         z.closed = true;
        }
      return;
     }

   // ── 6. Entry: proximity + engulfing with regime-adjusted parameters ──
   if(atr <= 0.0) return;
   double band = atr * InpProximityATRs;

   bool near;
   if(z.direction == "above")
      near = (bid >= z.price - pip * 3.0) && (bid <= z.price + band);
   else
      near = (ask <= z.price + pip * 3.0) && (ask >= z.price - band);

   if(!near) return;

   if(z.direction == "above" && BullishEngulfingForming())
     {
      PrintFormat("[optRaider-v6] Bullish engulfing near %.5f — long (zone %s %d min left)",
                  z.price, z.id, mLeft);
      OpenLong(z);
     }
   else if(z.direction == "below" && BearishEngulfingForming())
     {
      PrintFormat("[optRaider-v6] Bearish engulfing near %.5f — short (zone %s %d min left)",
                  z.price, z.id, mLeft);
      OpenShort(z);
     }
  }

//+------------------------------------------------------------------+
//| New M5 bar — log regime state, no server reporting               |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   int idx = PickZone();
   if(idx < 0) return;

   int mLeft = MinsLeft(g_zones[idx]);
   if(!g_zones[idx].activated || mLeft < -10 || mLeft > InpActivationMins) return;

   double ratio  = (g_baselineATR > 0.0) ? GetATR() / g_baselineATR : 1.0;
   int    regime = VolRegime();

   PrintFormat("[optRaider-v6] Bar — zone %s dir=%s fired=%s minsLeft=%d regime=%d(%.2fx) lots=%.2f slCap=%dpip",
               g_zones[idx].id,
               g_zones[idx].direction,
               g_zones[idx].tradeFired ? "YES" : "NO",
               mLeft, regime, ratio, CalcLots(), ActiveSLPips());
  }

//+------------------------------------------------------------------+
//| Daily reset — refreshes baseline ATR each UTC calendar day       |
//+------------------------------------------------------------------+
void CheckDayReset()
  {
   MqlDateTime d;
   TimeToStruct(TimeGMT(), d);
   if(d.day_of_year == g_lastDay) return;

   g_lastDay = d.day_of_year;
   ComputeBaselineATR();

   // Zones are date-filtered server-side; a new day means fresh zones on next poll.
   // Force an immediate re-poll so stale yesterday zones are flushed.
   g_lastPoll = 0;
   PrintFormat("[optRaider-v6] Day reset — day=%d baseline ATR=%.5f", g_lastDay, g_baselineATR);
  }

//+------------------------------------------------------------------+
//| EA lifecycle                                                      |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = (InpSymbolName != "") ? InpSymbolName : _Symbol;

   if(Period() != PERIOD_M5)
      PrintFormat("[optRaider-v6] WARNING — designed for M5 chart (current period=%d min)", Period());



   MqlDateTime d;
   TimeToStruct(TimeGMT(), d);
   g_lastDay = d.day_of_year;

   g_lastBarCount = Bars(g_symbol, PERIOD_M5);
   EventSetTimer(30);

   // Need a small delay before ATR buffer is populated; poll after first timer tick
   PollZones();
   ComputeBaselineATR();

   PrintFormat("[optRaider-v6] Ready — symbol=%s magic=%d TZ_offset=%dh baseLot=%.2f baselineATR=%.5f",
               g_symbol, g_magic, InpLocalTZOffsetHours,
               (InpLotSize > 0.0) ? InpLotSize : SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN),
               g_baselineATR);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();

   Print("[optRaider-v6] Deinitialized");
  }

//+------------------------------------------------------------------+
//| OnTimer — daily reset check, re-poll, evaluate active zone       |
//+------------------------------------------------------------------+
void OnTimer()
  {
   CheckDayReset();

   if(TimeCurrent() - g_lastPoll >= (datetime)(InpPollMinutes * 60))
      PollZones();

   int idx = PickZone();
   if(idx >= 0) EvaluateZone(g_zones[idx]);
  }

//+------------------------------------------------------------------+
//| OnTick — detect new M5 bar                                       |
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
