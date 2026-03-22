//+------------------------------------------------------------------+
//| optionsRaider-v4.mq5                                             |
//| V4 — Strike-Touch Prerequisite Filter                            |
//|                                                                  |
//| Difference from base optionsRaider:                              |
//|  • Engulfing entry is only armed AFTER price has touched the     |
//|    strike level (within InpTouchPips) at least once.            |
//|    This confirms institutional defence is active before any      |
//|    capital is committed.                                         |
//|  • Only one zone is ever active at a time (PickZone selector).  |
//|    Priority: open position > activated zone > closest to price.  |
//|    An SL hit closes the zone (no further trades). Price trading  |
//|    through the strike before the window does not remove it.      |
//|  • No server reporting — statistics are sent by the base EA      |
//|    only.                                                         |
//|                                                                  |
//| Magic: 20260402                                                  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"

//--- Inputs
input string InpServerURL             = "http://127.0.0.1:3000"; // Zone server URL
input string InpSymbolName            = "";    // Symbol override (blank = chart symbol)
input int    InpLocalTZOffsetHours    = 1;     // Expiry-time UTC offset (CET=1, CEST=2)
input int    InpATRPeriod             = 14;    // ATR period (M5 bars)
input double InpSLATRMult             = 2.0;   // SL distance: N × ATR from strike
input int    InpMaxSLPips             = 10;    // SL hard cap (pips)
input double InpProximityATRs         = 1.0;   // Entry band: N × ATR from strike
input int    InpTouchPips             = 5;     // Pips from strike to qualify as a touch
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
   bool     levelTouched;      // price came within InpTouchPips of strike
   bool     tradeFired;        // entry order sent
   bool     closed;            // zone lifecycle complete for this session
   ulong    ticket;            // position ticket (0 until trade placed)
  };

//--- Globals
OptionsZone g_zones[];
int         g_zoneCount    = 0;
long        g_magic        = 20260402;
int         g_atrHandle    = INVALID_HANDLE;
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

double GetATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) < 1) return 0.0;
   return buf[0];
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
      PrintFormat("[optRaider-v4] PollZones HTTP=%d err=%d url=%s (whitelist URL in MT5 settings)",
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
      z.id           = zid;
      z.direction    = zdir;
      z.price        = zpx;
      z.expiryTime   = ztm;
      z.date         = zdt;
      z.activated    = false;
      z.levelTouched = false;
      z.tradeFired   = false;
      z.closed       = false;
      z.ticket       = 0;

      for(int i = 0; i < prevN; i++)
        {
         if(prev[i].id == zid)
           {
            z.activated    = prev[i].activated;
            z.levelTouched = prev[i].levelTouched;
            z.tradeFired   = prev[i].tradeFired;
            z.closed       = prev[i].closed;
            z.ticket       = prev[i].ticket;
            break;
           }
        }

      ArrayResize(g_zones, g_zoneCount + 1);
      g_zones[g_zoneCount++] = z;
     }

   PrintFormat("[optRaider-v4] %d option zone(s) loaded for %s", g_zoneCount, g_symbol);
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
      PrintFormat("[optRaider-v4] ClosePos FAILED #%I64u retcode=%u why=%s", ticket, res.retcode, why);
   else
      PrintFormat("[optRaider-v4] Closed #%I64u why=%s", ticket, why);
  }

bool OpenLong(OptionsZone &z)
  {
   double atr = GetATR();
   if(atr <= 0.0) { Print("[optRaider-v4] OpenLong: ATR=0, skipping"); return false; }

   double ask    = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double pip    = PipSize();
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
   req.tp           = 0.0;
   req.magic        = g_magic;
   req.comment      = "OPT-V4:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider-v4] OpenLong FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider-v4] Long #%I64u ask=%.5f sl=%.5f lots=%.2f zone=%s",
               z.ticket, ask, sl, lots, z.id);
   return true;
  }

bool OpenShort(OptionsZone &z)
  {
   double atr = GetATR();
   if(atr <= 0.0) { Print("[optRaider-v4] OpenShort: ATR=0, skipping"); return false; }

   double bid    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double pip    = PipSize();
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
   req.comment      = "OPT-V4:" + z.id;
   req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
     {
      PrintFormat("[optRaider-v4] OpenShort FAILED retcode=%u zone=%s", res.retcode, z.id);
      return false;
     }

   z.ticket     = res.order;
   z.tradeFired = true;
   PrintFormat("[optRaider-v4] Short #%I64u bid=%.5f sl=%.5f lots=%.2f zone=%s",
               z.ticket, bid, sl, lots, z.id);
   return true;
  }

//+------------------------------------------------------------------+
//| Single-zone selector                                             |
//|                                                                  |
//| Priority:                                                        |
//|  1. Zone holding an open position — managed to completion        |
//|  2. Already-activated zone — holds slot until expiry or SL.     |
//|     Price trading through the strike does not remove it.        |
//|     SL hit sets closed=true, removing it on the next tick.      |
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
      PrintFormat("[optRaider-v4] Zone %s (%s @ %.5f exp %s) ACTIVATED — %d min left",
                  z.id, z.direction, z.price, z.expiryTime, mLeft);
     }

   // ── 5. Detect external close ─────────────────────────────────────
   if(z.tradeFired)
     {
      if(!IsPosOpen(z.ticket))
        {
         PrintFormat("[optRaider-v4] #%I64u closed externally (SL/manual) zone=%s",
                     z.ticket, z.id);
         z.closed = true;
        }
      return;
     }

   // ── 6. Touch detection ───────────────────────────────────────────
   // Arm the level once price comes within InpTouchPips of the strike.
   // Without this touch, no entry is attempted even if engulfing forms.
   if(!z.levelTouched)
     {
      double touchDist = InpTouchPips * pip;
      if(MathAbs(bid - z.price) <= touchDist || MathAbs(ask - z.price) <= touchDist)
        {
         z.levelTouched = true;
         PrintFormat("[optRaider-v4] Level %.5f touched — engulfing now armed (zone %s)",
                     z.price, z.id);
        }
      else
         return;   // level not yet touched, skip entry check
     }

   // ── 7. Entry: proximity + engulfing (only if level was touched) ──
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
      PrintFormat("[optRaider-v4] Touched + bullish engulfing near %.5f — long (zone %s %d min left)",
                  z.price, z.id, mLeft);
      OpenLong(z);
     }
   else if(z.direction == "below" && BearishEngulfingForming())
     {
      PrintFormat("[optRaider-v4] Touched + bearish engulfing near %.5f — short (zone %s %d min left)",
                  z.price, z.id, mLeft);
      OpenShort(z);
     }
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

   PrintFormat("[optRaider-v4] Bar update — zone %s dir=%s touched=%s fired=%s minsLeft=%d",
               g_zones[idx].id,
               g_zones[idx].direction,
               g_zones[idx].levelTouched ? "YES" : "NO",
               g_zones[idx].tradeFired   ? "YES" : "NO",
               mLeft);
  }

//+------------------------------------------------------------------+
//| EA lifecycle                                                      |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_symbol = (InpSymbolName != "") ? InpSymbolName : _Symbol;

   if(Period() != PERIOD_M5)
      PrintFormat("[optRaider-v4] WARNING — designed for M5 chart (current period=%d min)", Period());

   g_atrHandle = iATR(g_symbol, PERIOD_M5, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     { Print("[optRaider-v4] iATR init failed"); return INIT_FAILED; }

   g_lastBarCount = Bars(g_symbol, PERIOD_M5);
   EventSetTimer(30);
   PollZones();

   PrintFormat("[optRaider-v4] Ready — symbol=%s magic=%d TZ_offset=%dh lot=%.2f touch=%d pip",
               g_symbol, g_magic, InpLocalTZOffsetHours,
               (InpLotSize > 0.0) ? InpLotSize : SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN),
               InpTouchPips);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE)
     { IndicatorRelease(g_atrHandle); g_atrHandle = INVALID_HANDLE; }
   Print("[optRaider-v4] Deinitialized");
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
