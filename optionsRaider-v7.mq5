//+------------------------------------------------------------------+
//| optionsRaider-v7.mq5                                             |
//| V7 — Gravitational Pull (Closest-Strike + Proximity)            |
//|                                                                  |
//| Difference from base optionsRaider:                              |
//|  • Two conditions must both be true before an entry fires:       |
//|    1. Price is within InpProximityATRs × ATR of this strike.     |
//|       "above": ask in [strike − N×ATR, strike + 1×ATR]          |
//|       "below": bid in [strike − 1×ATR, strike + N×ATR]          |
//|    2. This strike is the closest active zone to current price    |
//|       vs any zone in the opposite direction (gravitational pull). |
//|       If no opposite zone exists, condition 2 is waived.         |
//|  • Most selective variant — only trades the dominant near strike. |
//|  • Only one zone is ever active at a time (PickZone selector).  |
//|    Priority: open position > activated zone > closest to price.  |
//|    SL hit ends the zone. Price trading through does not.         |
//|  • No server reporting.                                          |
//|                                                                  |
//| Magic: 20260404                                                  |
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
input double InpProximityATRs         = 3.0;   // Max distance from strike to enter (N × ATR)
input int    InpActivationMins        = 150;   // Start watching N minutes before expiry
input int    InpCloseMinsBeforeExpiry = 3;     // Close position N minutes before expiry
input double InpLotSize               = 0.0;   // Lot size (0.0 = broker minimum)
input int    InpPollMinutes           = 10;    // Zone poll interval (minutes)

//--- Zone state machine
struct OptionsZone
  {
   string   id;
   string   direction;    // "above" → long  |  "below" → short
   double   price;        // option strike
   string   expiryTime;   // "HH:MM" in operator local time
   string   date;         // "YYYY-MM-DD"
   bool     activated;    // entered InpActivationMins window
   bool     tradeFired;   // entry order sent
   bool     closed;       // zone lifecycle complete for this session
   ulong    ticket;       // position ticket (0 until trade placed)
  };

//--- Globals
OptionsZone g_zones[];
int         g_zoneCount    = 0;
long        g_magic        = 20260404;

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

// ATR computed directly from OHLC — no indicator handle required.
// Uses a simple mean of True Range over InpATRPeriod completed M5 bars,
// eliminating the "cannot load indicator Average True Range" (error 4302)
// that occurs in broker builds where the indicator file is unavailable.
double GetATR()
  {
   int    period = InpATRPeriod;
   double hi[], lo[], cl[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   ArraySetAsSeries(cl, true);
   int need = period + 1; // period TRs each need the previous bar's close
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
      PrintFormat("[optRaider-v7] PollZones HTTP=%d err=%d url=%s (whitelist URL in MT5 settings)",
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

      // Restore runtime state across polls
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

   PrintFormat("[optRaider-v7] %d option zone(s) loaded for %s", g_zoneCount, g_symbol);
  }

//+------------------------------------------------------------------+
//| Proximity check — returns true when current price is closer to   |
//| this zone's strike than to the nearest opposite-direction strike. |
//| If no opposite zone exists, returns true unconditionally.        |
//+------------------------------------------------------------------+
bool IsCloserThanOpposite(const OptionsZone &z)
  {
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   double distToThis = MathAbs(mid - z.price);

   string oppDir     = (z.direction == "above") ? "below" : "above";
   double nearestOpp = DBL_MAX;

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_zones[i].closed)           continue;
      if(g_zones[i].direction != oppDir) continue;
      double d = MathAbs(mid - g_zones[i].price);
      if(d < nearestOpp) nearestOpp = d;
     }

   // No opposite zone on the list — open unconditionally
   if(nearestOpp == DBL_MAX) return true;

   return distToThis <= nearestOpp;
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
      PrintFormat("[optRaider-v7] ClosePos FAILED #%I64u retcode=%u why=%s", ticket, res.retcode, why);
   else
      PrintFormat("[optRaider-v7] Closed #%I64u why=%s", ticket, why);
  }

bool OpenLong(OptionsZone &z)
  {
   double atr = GetATR();
   double ask    = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double pip    = PipSize();
   // SL: min(2×ATR, MaxSLPips); falls back to MaxSLPips cap when ATR unavailable
   double slDist = (atr > 0.0) ? MathMin(atr * InpSLATRMult, InpMaxSLPips * pip)
                               : InpMaxSLPips * pip;
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
   req.tp           = 0.0;
   req.magic        = g_magic;
   req.comment      = "OPT-V7:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider-v7] OpenLong FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider-v7] Long #%I64u ask=%.5f sl=%.5f lots=%.2f zone=%s",
               z.ticket, ask, sl, lots, z.id);
   return true;
  }

bool OpenShort(OptionsZone &z)
  {
   double atr = GetATR();
   double bid    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double pip    = PipSize();
   // SL: min(2×ATR, MaxSLPips); falls back to MaxSLPips cap when ATR unavailable
   double slDist = (atr > 0.0) ? MathMin(atr * InpSLATRMult, InpMaxSLPips * pip)
                               : InpMaxSLPips * pip;
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
   req.comment      = "OPT-V7:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider-v7] OpenShort FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider-v7] Short #%I64u bid=%.5f sl=%.5f lots=%.2f zone=%s",
               z.ticket, bid, sl, lots, z.id);
   return true;
  }

//+------------------------------------------------------------------+
//| Single-zone selector                                             |
//|                                                                  |
//| Priority:                                                        |
//|  1. Zone holding an open position — managed to completion        |
//|  2. Already-activated zone — holds slot until expiry or SL.     |
//|     Price trading through the strike does NOT remove the zone.  |
//|     SL hit sets closed=true, which removes it from this check.  |
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
//| Zone evaluation — called every 30 s from OnTimer                 |
//+------------------------------------------------------------------+
void EvaluateZone(OptionsZone &z)
  {
   if(z.closed) return;

   int    mLeft = MinsLeft(z);
   double atr   = GetATR();

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
      PrintFormat("[optRaider-v7] Zone %s (%s @ %.5f exp %s) ACTIVATED — %d min left",
                  z.id, z.direction, z.price, z.expiryTime, mLeft);
     }

   // ── 5. Detect external close ─────────────────────────────────────
   if(z.tradeFired)
     {
      if(!IsPosOpen(z.ticket))
        {
         PrintFormat("[optRaider-v7] #%I64u closed externally (SL/manual) zone=%s",
                     z.ticket, z.id);
         z.closed = true;
        }
      return;
     }

   // ── 6. Entry: gravitational pull — closest strike + proximity ────
   // Two conditions must both be true:
   // 1. Price is within InpProximityATRs × ATR of this strike.
   //    "above" (long):  ask in [strike − N×ATR, strike + 1×ATR]
   //    "below" (short): bid in [strike − 1×ATR, strike + N×ATR]
   // 2. This strike is closer to current price than any opposite-direction
   //    zone (gravitational dominance). Waived if no opposite zone exists.
   // Together these guarantee we only trade the dominant, near strike
   // and never open simultaneous long + short positions.
   if(atr <= 0.0) return;
   double bid  = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double band = atr * InpProximityATRs;
   bool   near;
   if(z.direction == "above")
      near = (ask >= z.price - band) && (ask <= z.price + atr);
   else
      near = (bid <= z.price + band) && (bid >= z.price - atr);

   if(!near)
     {
      PrintFormat("[optRaider-v7] Zone %s — price not within %.1f ATR of strike %.5f, waiting",
                  z.id, InpProximityATRs, z.price);
      return;
     }

   if(!IsCloserThanOpposite(z))
     {
      PrintFormat("[optRaider-v7] Zone %s — price closer to opposite strike, waiting", z.id);
      return;
     }

   PrintFormat("[optRaider-v7] Gravity + proximity confirmed — entering %s toward %.5f (zone %s %d min left)",
               (z.direction == "above") ? "long" : "short", z.price, z.id, mLeft);
   if(z.direction == "above") OpenLong(z);
   else                       OpenShort(z);
  }

//+------------------------------------------------------------------+
//| New M5 bar — log only, no server reporting in this version       |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   int idx = PickZone();
   if(idx < 0) return;

   int mLeft = MinsLeft(g_zones[idx]);
   if(!g_zones[idx].activated || mLeft < -10 || mLeft > InpActivationMins) return;

   PrintFormat("[optRaider-v7] Bar update — zone %s dir=%s fired=%s minsLeft=%d",
               g_zones[idx].id,
               g_zones[idx].direction,
               g_zones[idx].tradeFired ? "YES" : "NO",
               mLeft);
  }

//+------------------------------------------------------------------+
//| EA lifecycle                                                      |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = (InpSymbolName != "") ? InpSymbolName : _Symbol;

   if(Period() != PERIOD_M5)
      PrintFormat("[optRaider-v7] WARNING — designed for M5 chart (current period=%d min)", Period());



   g_lastBarCount = Bars(g_symbol, PERIOD_M5);
   EventSetTimer(30);
   PollZones();

   PrintFormat("[optRaider-v7] Ready — symbol=%s magic=%d TZ_offset=%dh lot=%.2f",
               g_symbol, g_magic, InpLocalTZOffsetHours,
               (InpLotSize > 0.0) ? InpLotSize : SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();

   Print("[optRaider-v7] Deinitialized");
  }

//+------------------------------------------------------------------+
//| OnTimer — re-poll and evaluate the single active zone            |
//+------------------------------------------------------------------+
void OnTimer()
  {
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
