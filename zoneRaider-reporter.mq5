//+------------------------------------------------------------------+
//| ZoneRaiderV3.mq5                                                 |
//| 5m candle entry on zone touch, swing trail, 5m snapshots        |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "3.00"

//--- Zone watch states
#define ZW_WATCHING  0   // waiting for price to enter zone
#define ZW_IN_ZONE   1   // price inside zone, looking for signal candle
#define ZW_DONE      2   // order placed or zone expired

//--- Inputs
input string InpServerURL      = "http://127.0.0.1:3000"; // Server URL
input string InpSymbolName     = "";                       // Symbol for URL (blank = chart symbol)
input bool   InpAllowLong      = true;                     // Allow buy entries
input bool   InpAllowShort     = true;                     // Allow sell entries
input int    InpATRPeriod      = 96;                       // ATR period (96 = 8h on M5)
input double InpATRMultiplier  = 1.5;                      // ATR multiplier for initial SL
input double InpMaxDailyRisk   = 500.0;                    // Total daily risk budget ($)
input int    InpMaxPositions   = 6;                        // Max simultaneous positions
input int    InpPollMinutes    = 10;                       // Poll interval (minutes)
input int    InpEODHour        = 21;                       // EOD hour — closes all (UTC)
input bool   InpSkipWeekends   = true;                     // Skip weekends
input int    InpSwingLookback  = 10;                       // Bars to look back for swing trail
input int    InpZoneExpireBars = 12;                       // Give up on zone after N M5 bars in zone (1h)

//--- Zone struct
struct Zone
  {
   string   id;
   string   direction;
   string   strength;
   string   kind;
   double   price;
   double   priceFrom;
   double   priceTo;
   double   zoneLow;
   double   zoneHigh;
  };

//--- Per-zone watch state
struct ZoneWatch
  {
   int      state;
   datetime touchTime;
   int      barsInZone;
   datetime lastBarChecked;
  };

//--- Position tracking (72 x 5m snapshots = 6h)
#define SNAP_COUNT 72
struct TrackEntry
  {
   ulong    ticket;
   // Zone snapshot
   string   zoneId;
   string   direction;
   string   zoneStrength;
   string   zoneKind;
   double   zonePrice;
   double   zoneFrom;
   double   zoneTo;
   double   zoneLow;
   double   zoneHigh;
   // Order details
   double   entryPrice;
   double   initialSL;
   double   initialTP;
   double   slDistance;
   double   atrAtOpen;
   // Timing
   datetime openTime;
   datetime closeTime;
   string   closedBy;
   bool     isOpen;
   // P&L tracking
   double   maxProfitPips;
   double   maxProfitATR;
   datetime maxProfitTime;
   double   maxLossPips;
   double   maxLossATR;
   datetime maxLossTime;
   // 5m snapshots
   double   snapPrice[SNAP_COUNT];
   datetime snapTime[SNAP_COUNT];
   int      snapCount;
   datetime nextSnapTime;
   // Report
   datetime trackingEndsAt;
   bool     reportSent;
  };

//--- Globals
Zone       g_zones[];
ZoneWatch  g_watch[];
int        g_zoneCount    = 0;
bool       g_zonesLoaded  = false;
datetime   g_lastPoll     = 0;
string     g_firedIds[];        // zone IDs that fired today — survives polls, reset on new day
int        g_firedCount   = 0;
int        g_atrHandle    = INVALID_HANDLE;
double     g_dailyRiskUsed = 0.0;
int        g_posCount     = 0;
long       g_magic        = 20260303;
TrackEntry g_tracking[];
int        g_trackCount   = 0;
bool       g_eodDone      = false;
int        g_lastDay      = -1;
datetime   g_lastM5Bar    = 0;

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_atrHandle = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("ZoneRaiderV3: Failed to create ATR handle");
      return INIT_FAILED;
     }
   EventSetTimer(30);
   Print("ZoneRaiderV3: Initialized on ", _Symbol, " (M5 ATR", InpATRPeriod, ")");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
  }

//+------------------------------------------------------------------+
//| Timer — session management, polling, weekend-aware report flush  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);

   if(InpSkipWeekends && (dt.day_of_week == 0 || dt.day_of_week == 6))
      return;

   //--- New day reset
   if(dt.day_of_year != g_lastDay)
     {
      g_lastDay       = dt.day_of_year;
      g_eodDone       = false;
      g_zonesLoaded   = false;
      g_lastPoll      = 0;
      g_lastM5Bar     = 0;
      g_dailyRiskUsed = 0.0;
      g_posCount      = 0;
      g_zoneCount     = 0;
      g_firedCount    = 0;
      ArrayResize(g_zones, 0);
      ArrayResize(g_watch, 0);
      ArrayResize(g_firedIds, 0);
      Print("ZoneRaiderV3: New day — session reset");
     }

   //--- EOD — close all, clear zones, keep tracking for reports
   if(dt.hour == InpEODHour)
     {
      if(!g_eodDone) { CloseAndReset(); g_eodDone = true; }
      // Fall through to flush reports even at EOD
     }

   //--- Flush pending reports (fires even with no ticks / after EOD)
   for(int i = 0; i < g_trackCount; i++)
     {
      if(g_tracking[i].reportSent) continue;
      if(TimeCurrent() >= g_tracking[i].trackingEndsAt)
        {
         SendReport(i);
         g_tracking[i].reportSent = true;
        }
     }

   if(g_eodDone) return;

   //--- Poll
   if(TimeCurrent() - g_lastPoll >= InpPollMinutes * 60)
      PollServer();
  }

//+------------------------------------------------------------------+
//| OnTick — M5 bar detection, entry signals, trail, 4h close        |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime m5Open = iTime(_Symbol, PERIOD_M5, 0);
   bool newM5Bar   = (m5Open != g_lastM5Bar);
   if(newM5Bar) g_lastM5Bar = m5Open;

   //--- Check zone entry signals on new M5 bar
   if(newM5Bar && g_zonesLoaded)
      CheckZoneSignals();

   //--- Detect fills
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      if(FindTrackIdx(ticket) < 0) AddTrackEntry(ticket);
     }

   //--- Update all tracking entries
   for(int i = 0; i < g_trackCount; i++)
     {
      if(g_tracking[i].reportSent) continue;

      bool posExists = PositionSelectByTicket(g_tracking[i].ticket);

      //--- Detect close
      if(g_tracking[i].isOpen && !posExists)
        {
         g_tracking[i].isOpen    = false;
         g_tracking[i].closeTime = TimeCurrent();
         if(g_tracking[i].closedBy == "")
            g_tracking[i].closedBy = DetectCloseReason(g_tracking[i].ticket);
         Print("ZoneRaiderV3: #", g_tracking[i].ticket,
               " closed — ", g_tracking[i].closedBy);
        }

      double currentPrice = (g_tracking[i].direction == "buy")
                             ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                             : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      //--- While open: swing trail, 4h close
      if(g_tracking[i].isOpen && posExists)
        {
         if(newM5Bar) SwingTrail(i);

         if(TimeCurrent() - g_tracking[i].openTime >= 4 * 3600)
           {
            g_tracking[i].closedBy  = "4h";
            g_tracking[i].closeTime = TimeCurrent();
            CloseByTicket(g_tracking[i].ticket);
            g_tracking[i].isOpen = false;
            Print("ZoneRaiderV3: 4h close #", g_tracking[i].ticket);
           }
        }

      //--- P&L tracking
      double pip    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
      double diff   = (g_tracking[i].direction == "buy")
                       ? currentPrice - g_tracking[i].entryPrice
                       : g_tracking[i].entryPrice - currentPrice;
      double profitPips = (pip > 0) ? diff / pip : 0.0;
      double profitATR  = (g_tracking[i].atrAtOpen > 0)
                           ? diff / g_tracking[i].atrAtOpen : 0.0;

      if(profitPips > g_tracking[i].maxProfitPips)
        {
         g_tracking[i].maxProfitPips = profitPips;
         g_tracking[i].maxProfitATR  = profitATR;
         g_tracking[i].maxProfitTime = TimeCurrent();
        }
      if(profitPips < g_tracking[i].maxLossPips)
        {
         g_tracking[i].maxLossPips = profitPips;
         g_tracking[i].maxLossATR  = profitATR;
         g_tracking[i].maxLossTime = TimeCurrent();
        }

      //--- 5m snapshots
      if(g_tracking[i].snapCount < SNAP_COUNT &&
         TimeCurrent() >= g_tracking[i].nextSnapTime)
        {
         int s = g_tracking[i].snapCount;
         g_tracking[i].snapPrice[s] = currentPrice;
         g_tracking[i].snapTime[s]  = TimeCurrent();
         g_tracking[i].snapCount++;
         g_tracking[i].nextSnapTime = g_tracking[i].openTime +
                                      (g_tracking[i].snapCount + 1) * 300;
        }
     }
  }

//+------------------------------------------------------------------+
//| Check all zones for M5 entry signal                              |
//+------------------------------------------------------------------+
void CheckZoneSignals()
  {
   if(g_posCount >= InpMaxPositions) return;

   double pip   = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // M5 bar[1] = just closed  bar[2] = previous
   double o1 = iOpen (_Symbol, PERIOD_M5, 1);
   double c1 = iClose(_Symbol, PERIOD_M5, 1);
   double h1 = iHigh (_Symbol, PERIOD_M5, 1);
   double l1 = iLow  (_Symbol, PERIOD_M5, 1);
   if(o1 == 0 || c1 == 0) return;

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_watch[i].state == ZW_DONE)      continue;
      if(g_zones[i].direction == "buy"  && !InpAllowLong)  continue;
      if(g_zones[i].direction == "sell" && !InpAllowShort) continue;

      //--- State: WATCHING → check if price entered zone
      if(g_watch[i].state == ZW_WATCHING)
        {
         bool entered = false;
         if(g_zones[i].direction == "buy")
            entered = (bid <= g_zones[i].zoneHigh && bid >= g_zones[i].zoneLow - 5*pip);
         else
            entered = (ask >= g_zones[i].zoneLow  && ask <= g_zones[i].zoneHigh + 5*pip);

         if(entered)
           {
            g_watch[i].state         = ZW_IN_ZONE;
            g_watch[i].touchTime     = TimeCurrent();
            g_watch[i].barsInZone    = 0;
            g_watch[i].lastBarChecked = iTime(_Symbol, PERIOD_M5, 1);
            Print("ZoneRaiderV3: Zone ", i, " [", g_zones[i].direction, " ",
                  g_zones[i].strength, "] entered at ",
                  TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
           }
         continue;
        }

      //--- State: IN_ZONE → look for signal candle
      if(g_watch[i].state == ZW_IN_ZONE)
        {
         // Only process each bar once
         datetime thisBar = iTime(_Symbol, PERIOD_M5, 1);
         if(thisBar == g_watch[i].lastBarChecked) continue;
         g_watch[i].lastBarChecked = thisBar;
         g_watch[i].barsInZone++;

         // Give up after InpZoneExpireBars bars
         if(g_watch[i].barsInZone > InpZoneExpireBars)
           {
            g_watch[i].state = ZW_DONE;
            Print("ZoneRaiderV3: Zone ", i, " expired (", InpZoneExpireBars,
                  " bars, no signal)");
            continue;
           }

         // Check if price left the zone — reset to watching
         bool stillInZone = false;
         if(g_zones[i].direction == "buy")
            stillInZone = (bid >= g_zones[i].zoneLow - 10*pip &&
                           bid <= g_zones[i].zoneHigh + 10*pip);
         else
            stillInZone = (ask <= g_zones[i].zoneHigh + 10*pip &&
                           ask >= g_zones[i].zoneLow - 10*pip);

         if(!stillInZone)
           {
            g_watch[i].state = ZW_WATCHING;
            Print("ZoneRaiderV3: Zone ", i, " — price left zone, resetting");
            continue;
           }

         // Signal: buy = green candle (close > open), sell = red candle (close < open)
         bool signal = false;
         if(g_zones[i].direction == "buy"  && c1 > o1) signal = true;
         if(g_zones[i].direction == "sell" && c1 < o1) signal = true;

         if(signal)
           {
            EnterMarket(i);
            // Record ID so it survives poll rebuilds
            ArrayResize(g_firedIds, g_firedCount + 1);
            g_firedIds[g_firedCount++] = g_zones[i].id;
            g_watch[i].state = ZW_DONE;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Enter at market for zone[idx]                                    |
//+------------------------------------------------------------------+
void EnterMarket(const int idx)
  {
   if(g_posCount >= InpMaxPositions) return;

   Zone   z   = g_zones[idx];
   double atr = GetATR();
   if(atr <= 0.0) { Print("ZoneRaiderV3: Invalid ATR zone ", idx); return; }

   double pip   = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double entry, sl, tp;
   double slDist = atr * InpATRMultiplier;

   if(z.direction == "buy")
     {
      entry = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits);
      sl    = NormalizeDouble(entry - slDist, _Digits);
      // TP: 1.5x SL distance
      tp    = NormalizeDouble(entry + slDist * 1.5, _Digits);
     }
   else
     {
      entry = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits);
      sl    = NormalizeDouble(entry + slDist, _Digits);
      tp    = NormalizeDouble(entry - slDist * 1.5, _Digits);
     }

   double budget = (InpMaxDailyRisk - g_dailyRiskUsed) /
                   MathMax(1, InpMaxPositions - g_posCount);
   double lots   = CalcLots(slDist, budget);

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lots;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 10;
   req.magic        = g_magic;
   req.comment      = z.id;
   req.type_filling = ORDER_FILLING_IOC;
   req.type         = (z.direction == "buy") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   if(!OrderSend(req, res))
     {
      Print("ZoneRaiderV3: Market order failed zone ", idx,
            " retcode=", res.retcode, " ", res.comment);
     }
   else
     {
      double risk      = CalcRiskForLots(lots, slDist);
      g_dailyRiskUsed += risk;
      g_posCount++;
      Print("ZoneRaiderV3: [", z.strength, "] ", z.direction,
            " MARKET #", res.order,
            "  entry=", entry, "  sl=", sl, "  tp=", tp,
            "  atr=", DoubleToString(atr, _Digits),
            "  lots=", lots, "  risk=$", risk);
     }
  }

//+------------------------------------------------------------------+
//| Swing-based trail on M5                                          |
//+------------------------------------------------------------------+
void SwingTrail(const int idx)
  {
   if(!PositionSelectByTicket(g_tracking[idx].ticket)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   int    lb        = InpSwingLookback;

   double newSL     = 0.0;
   bool   improve   = false;

   if(g_tracking[idx].direction == "buy")
     {
      // Find most recent confirmed swing low (bar[i].low < bar[i-1] and bar[i+1])
      // Start from bar[2] so bar[1] confirms
      double swingLow = 0.0;
      for(int b = 2; b <= lb + 1; b++)
        {
         double lo   = iLow(_Symbol, PERIOD_M5, b);
         double loPrev = iLow(_Symbol, PERIOD_M5, b + 1);
         double loNext = iLow(_Symbol, PERIOD_M5, b - 1);
         if(lo < loPrev && lo < loNext)
           { swingLow = lo; break; } // most recent swing low
        }
      if(swingLow > 0.0)
        {
         newSL   = NormalizeDouble(swingLow, _Digits);
         improve = newSL > currentSL;
        }
     }
   else
     {
      // Find most recent confirmed swing high
      double swingHigh = 0.0;
      for(int b = 2; b <= lb + 1; b++)
        {
         double hi     = iHigh(_Symbol, PERIOD_M5, b);
         double hiPrev = iHigh(_Symbol, PERIOD_M5, b + 1);
         double hiNext = iHigh(_Symbol, PERIOD_M5, b - 1);
         if(hi > hiPrev && hi > hiNext)
           { swingHigh = hi; break; }
        }
      if(swingHigh > 0.0)
        {
         newSL   = NormalizeDouble(swingHigh, _Digits);
         improve = newSL < currentSL;
        }
     }

   if(!improve || newSL <= 0.0) return;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = g_tracking[idx].ticket;
   req.sl       = newSL;
   req.tp       = currentTP;
   if(!OrderSend(req, res))
      Print("ZoneRaiderV3: SwingTrail failed #", g_tracking[idx].ticket,
            " code=", res.retcode);
  }

//+------------------------------------------------------------------+
//| Close by ticket                                                   |
//+------------------------------------------------------------------+
void CloseByTicket(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.magic        = g_magic;
   req.deviation    = 10;
   req.type_filling = ORDER_FILLING_IOC;
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
     { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID); }
   else
     { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
   if(!OrderSend(req, res))
      Print("ZoneRaiderV3: CloseByTicket failed #", ticket, " code=", res.retcode);
  }

//+------------------------------------------------------------------+
//| EOD — close all, reset session state (tracking persists)         |
//+------------------------------------------------------------------+
void CloseAndReset()
  {
   for(int i = 0; i < g_trackCount; i++)
      if(g_tracking[i].isOpen && g_tracking[i].closedBy == "")
         g_tracking[i].closedBy = "EOD";

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      CloseByTicket(ticket);
      Print("ZoneRaiderV3: EOD closed #", ticket);
     }

   g_zoneCount     = 0;
   g_zonesLoaded   = false;
   g_dailyRiskUsed = 0.0;
   g_posCount      = 0;
   g_lastPoll      = 0;
   ArrayResize(g_zones, 0);
   ArrayResize(g_watch, 0);
   Print("ZoneRaiderV3: EOD complete");
  }

//+------------------------------------------------------------------+
//| Poll server                                                       |
//+------------------------------------------------------------------+
void PollServer()
  {
   g_lastPoll = TimeCurrent();
   string sym     = (InpSymbolName != "") ? InpSymbolName : _Symbol;
   string url     = InpServerURL + "/" + sym;
   string headers = "Content-Type: application/json\r\n";
   char   post[], result[];
   string responseHeaders;

   Print("ZoneRaiderV3: Polling ", url);
   int res = WebRequest("GET", url, headers, 5000, post, result, responseHeaders);
   if(res != 200)
     { Print("ZoneRaiderV3: Poll failed HTTP=", res, " (whitelist URL)"); return; }

   ParseZones(CharArrayToString(result));
  }

//+------------------------------------------------------------------+
//| Parse zones                                                       |
//+------------------------------------------------------------------+
void ParseZones(const string json)
  {
   g_zoneCount = 0;
   ArrayResize(g_zones, 0);
   ArrayResize(g_watch, 0);
   if(StringFind(json, "{") < 0) { Print("ZoneRaiderV3: Empty zone list"); return; }

   int pos = 0, len = StringLen(json);
   while(pos < len)
     {
      int objStart = StringFind(json, "{", pos);
      if(objStart < 0) break;
      int depth = 1, objEnd = objStart + 1;
      while(objEnd < len && depth > 0)
        {
         ushort ch = StringGetCharacter(json, objEnd);
         if(ch == '{') depth++;
         if(ch == '}') depth--;
         objEnd++;
        }
      Zone z;
      if(ParseZoneObject(StringSubstr(json, objStart, objEnd - objStart), z))
        {
         ArrayResize(g_zones, g_zoneCount + 1);
         ArrayResize(g_watch, g_zoneCount + 1);
         g_zones[g_zoneCount]                  = z;
         g_watch[g_zoneCount].state            = ZW_WATCHING;
         g_watch[g_zoneCount].barsInZone       = 0;
         g_watch[g_zoneCount].touchTime        = 0;
         g_watch[g_zoneCount].lastBarChecked   = 0;
         g_zoneCount++;
        }
      pos = objEnd;
     }

   // Discard zones where price has already passed through (server has no live price)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_watch[i].state == ZW_DONE) continue;
      bool stale = false;
      if(g_zones[i].direction == "buy"  && bid < g_zones[i].zoneLow)  stale = true;
      if(g_zones[i].direction == "sell" && ask > g_zones[i].zoneHigh) stale = true;
      if(stale)
        {
         g_watch[i].state = ZW_DONE;
         Print("ZoneRaiderV3: Zone ", i, " [", g_zones[i].direction, " ",
               g_zones[i].strength, "] stale — price already through, skipping");
        }
     }

   // Mark any zone that already fired today so it can't trigger again
   for(int i = 0; i < g_zoneCount; i++)
      for(int f = 0; f < g_firedCount; f++)
         if(g_zones[i].id == g_firedIds[f])
           { g_watch[i].state = ZW_DONE; break; }

   if(g_zoneCount > 0)
     {
      g_zonesLoaded = true;
      Print("ZoneRaiderV3: Loaded ", g_zoneCount, " zone(s) — watching M5 signals");
     }
  }

//+------------------------------------------------------------------+
//| Parse single zone object                                         |
//+------------------------------------------------------------------+
bool ParseZoneObject(const string obj, Zone &z)
  {
   z.id        = JsonGetString(obj, "id");
   z.direction = JsonGetString(obj, "direction");
   z.strength  = JsonGetString(obj, "strength");
   z.kind      = JsonGetString(obj, "kind");
   z.price     = JsonGetDouble(obj, "price");
   z.priceFrom = JsonGetDouble(obj, "from");
   z.priceTo   = JsonGetDouble(obj, "to");

   if(z.direction == "" || z.strength == "" || z.kind == "") return false;

   if(z.kind == "point")
     {
      if(z.price == 0.0) return false;
      z.zoneLow  = z.price;
      z.zoneHigh = z.price;
     }
   else
     {
      if(z.priceFrom == 0.0 || z.priceTo == 0.0) return false;
      z.zoneLow  = MathMin(z.priceFrom, z.priceTo);
      z.zoneHigh = MathMax(z.priceFrom, z.priceTo);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Tracking helpers                                                  |
//+------------------------------------------------------------------+
int FindTrackIdx(ulong ticket)
  {
   for(int i = 0; i < g_trackCount; i++)
      if(g_tracking[i].ticket == ticket) return i;
   return -1;
  }

int FindZoneById(const string id)
  {
   for(int i = 0; i < g_zoneCount; i++)
      if(g_zones[i].id == id) return i;
   return -1;
  }

void AddTrackEntry(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;

   string zoneId = PositionGetString(POSITION_COMMENT);

   ArrayResize(g_tracking, g_trackCount + 1);
   int i = g_trackCount;

   // Zero-initialise entire struct first to prevent garbage in zone fields
   ZeroMemory(g_tracking[i]);

   g_tracking[i].ticket     = ticket;
   g_tracking[i].zoneId     = zoneId;
   g_tracking[i].direction  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                                ? "buy" : "sell";
   g_tracking[i].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   g_tracking[i].initialSL  = PositionGetDouble(POSITION_SL);
   g_tracking[i].initialTP  = PositionGetDouble(POSITION_TP);
   g_tracking[i].slDistance = MathAbs(g_tracking[i].entryPrice - g_tracking[i].initialSL);
   g_tracking[i].atrAtOpen  = GetATR();
   g_tracking[i].openTime   = (datetime)PositionGetInteger(POSITION_TIME);
   g_tracking[i].closeTime  = 0;
   g_tracking[i].closedBy   = "";
   g_tracking[i].isOpen     = true;

   g_tracking[i].maxProfitPips = 0.0;
   g_tracking[i].maxProfitATR  = 0.0;
   g_tracking[i].maxProfitTime = g_tracking[i].openTime;
   g_tracking[i].maxLossPips   = 0.0;
   g_tracking[i].maxLossATR    = 0.0;
   g_tracking[i].maxLossTime   = g_tracking[i].openTime;
   g_tracking[i].snapCount     = 0;
   g_tracking[i].nextSnapTime  = g_tracking[i].openTime + 300; // first snap at 5m

   // Tracking window: 6h, capped at Friday EOD if weekend is within range
   datetime rawEnd    = g_tracking[i].openTime + 6 * 3600;
   g_tracking[i].trackingEndsAt = CapAtWeekend(rawEnd);

   g_tracking[i].reportSent = false;

   // Snapshot zone data — zero-initialised above so missing fields stay 0.0
   int zIdx = FindZoneById(zoneId);
   if(zIdx >= 0)
     {
      g_tracking[i].zoneStrength = g_zones[zIdx].strength;
      g_tracking[i].zoneKind     = g_zones[zIdx].kind;
      g_tracking[i].zonePrice    = g_zones[zIdx].price;
      g_tracking[i].zoneFrom     = g_zones[zIdx].priceFrom;
      g_tracking[i].zoneTo       = g_zones[zIdx].priceTo;
      g_tracking[i].zoneLow      = g_zones[zIdx].zoneLow;
      g_tracking[i].zoneHigh     = g_zones[zIdx].zoneHigh;
     }

   g_trackCount++;
   Print("ZoneRaiderV3: Tracking #", ticket, " zone=", zoneId,
         " open=", TimeToString(g_tracking[i].openTime, TIME_DATE|TIME_SECONDS),
         " trackUntil=", TimeToString(g_tracking[i].trackingEndsAt, TIME_DATE|TIME_SECONDS));
  }

//+------------------------------------------------------------------+
//| Cap tracking end time at Friday EOD if weekend falls within      |
//+------------------------------------------------------------------+
datetime CapAtWeekend(const datetime rawEnd)
  {
   MqlDateTime endDt;
   TimeToStruct(rawEnd, endDt);

   // If tracking end falls on Saturday(6) or Sunday(0), walk back to Friday EOD
   if(endDt.day_of_week == 6 || endDt.day_of_week == 0)
     {
      // Find current time's Friday EOD
      MqlDateTime nowDt;
      TimeToStruct(TimeCurrent(), nowDt);
      // Walk back to Friday
      int daysBack = (nowDt.day_of_week == 6) ? 0 :
                     (nowDt.day_of_week == 0) ? 1 : 0;
      datetime friEOD = TimeCurrent()
                        - daysBack * 86400
                        - nowDt.hour   * 3600
                        - nowDt.min    * 60
                        - nowDt.sec
                        + InpEODHour   * 3600;
      Print("ZoneRaiderV3: Weekend cap — tracking ends at Friday EOD ",
            TimeToString(friEOD, TIME_DATE|TIME_MINUTES));
      return friEOD;
     }

   // Also cap if end time is Saturday-Saturday edge case
   MqlDateTime dt; TimeToStruct(rawEnd, dt);
   if(dt.day_of_week == 6)
      return rawEnd - dt.hour * 3600 - dt.min * 60 - dt.sec;

   return rawEnd;
  }

//+------------------------------------------------------------------+
//| Detect close reason from deal history                            |
//+------------------------------------------------------------------+
string DetectCloseReason(ulong positionId)
  {
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != positionId) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)          continue;
      long reason = HistoryDealGetInteger(deal, DEAL_REASON);
      if(reason == DEAL_REASON_SL) return "SL";
      if(reason == DEAL_REASON_TP) return "TP";
      return "manual";
     }
   return "unknown";
  }

//+------------------------------------------------------------------+
//| Build report JSON                                                 |
//+------------------------------------------------------------------+
string BuildReportJSON(const int idx)
  {
   TrackEntry e = g_tracking[idx];
   string j = "{";

   j += "\"ticket\":"         + IntegerToString(e.ticket)                               + ",";
   j += "\"zoneId\":\""       + e.zoneId                                                + "\",";
   j += "\"symbol\":\""       + _Symbol                                                 + "\",";
   j += "\"direction\":\""    + e.direction                                             + "\",";
   j += "\"strength\":\""     + e.zoneStrength                                          + "\",";
   j += "\"kind\":\""         + e.zoneKind                                              + "\",";

   if(e.zoneKind == "point")
      j += "\"zonePrice\":"   + DoubleToString(e.zonePrice, _Digits)                   + ",";
   else
     {
      j += "\"zoneFrom\":"    + DoubleToString(e.zoneFrom,  _Digits)                   + ",";
      j += "\"zoneTo\":"      + DoubleToString(e.zoneTo,    _Digits)                   + ",";
     }
   j += "\"zoneLow\":"        + DoubleToString(e.zoneLow,  _Digits)                    + ",";
   j += "\"zoneHigh\":"       + DoubleToString(e.zoneHigh, _Digits)                    + ",";

   j += "\"entryPrice\":"     + DoubleToString(e.entryPrice,  _Digits)                 + ",";
   j += "\"initialSL\":"      + DoubleToString(e.initialSL,   _Digits)                 + ",";
   j += "\"initialTP\":"      + DoubleToString(e.initialTP,   _Digits)                 + ",";
   j += "\"slDistance\":"     + DoubleToString(e.slDistance,  _Digits)                 + ",";
   j += "\"atrAtOpen\":"      + DoubleToString(e.atrAtOpen,   _Digits)                 + ",";

   j += "\"openTime\":\""     + TimeToString(e.openTime,  TIME_DATE|TIME_SECONDS)      + "\",";
   j += "\"closeTime\":\""    + (e.closeTime > 0
                                  ? TimeToString(e.closeTime, TIME_DATE|TIME_SECONDS)
                                  : "")                                                 + "\",";
   j += "\"closedBy\":\""     + e.closedBy                                             + "\",";

   int dur = (int)((e.closeTime > 0 ? e.closeTime : TimeCurrent()) - e.openTime);
   j += "\"durationMinutes\":" + IntegerToString(dur / 60)                             + ",";

   j += "\"maxProfit\":{";
   j += "\"pips\":"             + DoubleToString(e.maxProfitPips, 1)                   + ",";
   j += "\"atr\":"              + DoubleToString(e.maxProfitATR,  3)                   + ",";
   j += "\"time\":\""           + TimeToString(e.maxProfitTime, TIME_DATE|TIME_SECONDS)+ "\",";
   j += "\"minutesAfterOpen\":" + IntegerToString((int)(e.maxProfitTime - e.openTime)/60);
   j += "},";

   j += "\"maxLoss\":{";
   j += "\"pips\":"             + DoubleToString(e.maxLossPips, 1)                     + ",";
   j += "\"atr\":"              + DoubleToString(e.maxLossATR,  3)                     + ",";
   j += "\"time\":\""           + TimeToString(e.maxLossTime, TIME_DATE|TIME_SECONDS)  + "\",";
   j += "\"minutesAfterOpen\":" + IntegerToString((int)(e.maxLossTime - e.openTime)/60);
   j += "},";

   // 5m snapshots
   j += "\"snapshots5m\":[";
   for(int s = 0; s < e.snapCount; s++)
     {
      if(s > 0) j += ",";
      j += "{";
      j += "\"snap\":"          + IntegerToString(s + 1)                               + ",";
      j += "\"price\":"         + DoubleToString(e.snapPrice[s], _Digits)              + ",";
      j += "\"time\":\""        + TimeToString(e.snapTime[s], TIME_DATE|TIME_SECONDS)  + "\",";
      j += "\"minsAfterOpen\":" + IntegerToString((int)(e.snapTime[s] - e.openTime)/60);
      j += "}";
     }
   j += "],";

   j += "\"reportTime\":\"" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\"";
   j += "}";
   return j;
  }

//+------------------------------------------------------------------+
//| POST report to server                                            |
//+------------------------------------------------------------------+
void SendReport(const int idx)
  {
   string json    = BuildReportJSON(idx);
   string url     = InpServerURL + "/reports";
   string headers = "Content-Type: application/json\r\n";
   char   post[], result[];
   string responseHeaders;

   StringToCharArray(json, post, 0, StringLen(json));
   int res = WebRequest("POST", url, headers, 5000, post, result, responseHeaders);
   if(res == 200 || res == 201)
      Print("ZoneRaiderV3: Report sent #", g_tracking[idx].ticket);
   else
      Print("ZoneRaiderV3: Report failed #", g_tracking[idx].ticket, " HTTP=", res);
  }

//+------------------------------------------------------------------+
//| Risk / lot calculations                                           |
//+------------------------------------------------------------------+
double CalcRiskForLots(const double lots, const double slDist)
  {
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0.0 || tickVal == 0.0) return 0.0;
   return (slDist / tickSize) * tickVal * lots;
  }

double CalcLots(const double slDist, const double budget)
  {
   double lotMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMax   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0.0 || tickVal == 0.0) return lotMin;
   double riskPerLot = (slDist / tickSize) * tickVal;
   if(riskPerLot <= 0.0) return lotMin;
   double lots = MathFloor((budget / riskPerLot) / lotStep) * lotStep;
   return NormalizeDouble(MathMax(lotMin, MathMin(lotMax, lots)), 2);
  }

double GetATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0) return 0.0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| JSON helpers                                                      |
//+------------------------------------------------------------------+
string JsonGetString(const string obj, const string key)
  {
   int kPos = StringFind(obj, "\"" + key + "\""); if(kPos < 0) return "";
   int colon = StringFind(obj, ":", kPos);         if(colon < 0) return "";
   int q1 = StringFind(obj, "\"", colon + 1);      if(q1 < 0) return "";
   int q2 = StringFind(obj, "\"", q1 + 1);         if(q2 < 0) return "";
   return StringSubstr(obj, q1 + 1, q2 - q1 - 1);
  }

double JsonGetDouble(const string obj, const string key)
  {
   int kPos = StringFind(obj, "\"" + key + "\""); if(kPos < 0) return 0.0;
   int colon = StringFind(obj, ":", kPos);         if(colon < 0) return 0.0;
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
