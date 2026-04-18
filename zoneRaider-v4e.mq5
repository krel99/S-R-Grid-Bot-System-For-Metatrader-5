//+------------------------------------------------------------------+
//| ZoneRaider_v4e.mq5                                              |
//| Limit entry · M5 swing trail · first-bar rejection exit         |
//| Built on zoneRaider-aggr order management (fully tested base)   |
//|                                                                  |
//| After a limit fills, wait for the first complete M5 bar that    |
//| opened after the fill. If it closes against the position        |
//| direction (red for buy, green for sell), close at market —      |
//| the zone has rejected and the position is exited early.         |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "4.40"

//--- Inputs
input string InpServerURL        = "http://37.46.211.146:3000"; // Server URL
input string InpSymbolName       = "";                          // Symbol for URL (blank = chart symbol)
input bool   InpAllowLong        = true;                        // Allow buy entries
input bool   InpAllowShort       = true;                        // Allow sell entries
input int    InpSLPips           = 15;                          // Stop loss (pips)
input int    InpTPPips           = 20;                          // Take profit (pips)
input double InpMaxDailyRisk     = 100.0;                       // Total daily risk budget ($)
input int    InpPollMinutes      = 10;                          // Poll interval (minutes)
input int    InpNYOpenHour       = 13;                          // NY open hour (UTC)
input int    InpNYOpenMinute     = 30;                          // NY open minute (UTC)
input int    InpEODHour          = 21;                          // EOD hour — closes all (UTC)
input bool   InpSkipWeekends     = true;                        // Skip Sat/Sun
input int    InpEntryBuffer      = 0;                           // Pips past zone boundary for limit entry
input bool   InpSkipWatchedOnly  = true;                        // Skip watchedOnly zones
input int    InpSwingLookback    = 10;                          // M5 bars to search for swing point
input int    InpMinProfitToTrail = 10;                          // Pips in profit before trail activates
input int    InpSwingBuffer      = 2;                           // Buffer pips beyond swing point

//--- Zone struct
struct Zone
  {
   string   id;
   string   direction;
   string   strength;
   string   kind;
   bool     watchedOnly;
   double   price;
   double   priceFrom;
   double   priceTo;
   double   entryPrice;
   double   zoneLow;
   double   zoneHigh;
  };

//--- First-bar rejection tracking — one entry per open position
struct FirstBarCheck
  {
   ulong    ticket;
   string   direction;
   datetime fillBarOpen;  // M5 bar open time at the moment of fill
   bool     done;         // true once the check has fired (pass or reject)
  };

//--- Globals
Zone          g_zones[];
int           g_zoneCount     = 0;
bool          g_zonesLoaded   = false;
bool          g_ordersPlaced  = false;
datetime      g_lastPoll      = 0;
double        g_dailyRiskUsed = 0.0;
long          g_magic         = 20260405;
bool          g_eodDone       = false;
int           g_lastDay       = -1;
datetime      g_lastM5Bar     = 0;
FirstBarCheck g_fbChecks[];
int           g_fbCount       = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(30);
   Print("ZoneRaider v4e: Initialized on ", _Symbol, "  magic=", g_magic);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
//| Timer                                                            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);

   if(InpSkipWeekends && (dt.day_of_week == 0 || dt.day_of_week == 6)) return;

   if(dt.day_of_year != g_lastDay)
     {
      g_lastDay       = dt.day_of_year;
      g_eodDone       = false;
      g_zonesLoaded   = false;
      g_ordersPlaced  = false;
      g_dailyRiskUsed = 0.0;
      g_lastPoll      = 0;
      g_zoneCount     = 0;
      g_lastM5Bar     = 0;
      g_fbCount       = 0;
      ArrayResize(g_zones, 0);
      ArrayResize(g_fbChecks, 0);
      Print("ZoneRaider v4e: New day — session reset");
     }

   if(dt.hour == InpEODHour)
     {
      if(!g_eodDone) { CloseAndReset(); g_eodDone = true; }
      return;
     }

   if(g_ordersPlaced) return;

   if(TimeCurrent() - g_lastPoll < InpPollMinutes * 60) return;
   PollServer(dt);
  }

//+------------------------------------------------------------------+
//| OnTick — fill detection, first-bar rejection, swing trail, 4h   |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime m5Open = iTime(_Symbol, PERIOD_M5, 0);
   bool     newBar = (m5Open != g_lastM5Bar);
   if(newBar) g_lastM5Bar = m5Open;

   //--- Register newly filled positions into first-bar tracking
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      if(FindFBCheck(ticket) < 0) AddFBCheck(ticket);
     }

   //--- First-bar rejection check — runs on every new M5 bar
   if(newBar)
     {
      for(int i = 0; i < g_fbCount; i++)
        {
         if(g_fbChecks[i].done) continue;
         if(!PositionSelectByTicket(g_fbChecks[i].ticket)) { g_fbChecks[i].done = true; continue; }

         //--- Wait until the bar that OPENED after the fill has fully CLOSED
         //    i.e. bar[1] must have opened after fillBarOpen
         datetime bar1Open = iTime(_Symbol, PERIOD_M5, 1);
         if(bar1Open <= g_fbChecks[i].fillBarOpen) continue;  // first post-fill bar not closed yet

         double barOpen  = iOpen(_Symbol,  PERIOD_M5, 1);
         double barClose = iClose(_Symbol, PERIOD_M5, 1);
         bool rejected   = (g_fbChecks[i].direction == "buy")
                            ? barClose < barOpen   // red candle — zone rejected long
                            : barClose > barOpen;  // green candle — zone rejected short

         g_fbChecks[i].done = true;

         if(rejected)
           {
            Print("ZoneRaider v4e: First-bar rejection #", g_fbChecks[i].ticket,
                  "  closing at market");
            CloseByTicket(g_fbChecks[i].ticket);
           }
        }
     }

   //--- Swing trail + 4h close for all open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;

      if(newBar) SwingTrail(ticket);

      if(TimeCurrent() - (datetime)PositionGetInteger(POSITION_TIME) >= 4 * 3600)
        {
         Print("ZoneRaider v4e: 4h close #", ticket);
         CloseByTicket(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| First-bar check helpers                                          |
//+------------------------------------------------------------------+
int FindFBCheck(ulong ticket)
  {
   for(int i = 0; i < g_fbCount; i++)
      if(g_fbChecks[i].ticket == ticket) return i;
   return -1;
  }

void AddFBCheck(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   ArrayResize(g_fbChecks, g_fbCount + 1);
   g_fbChecks[g_fbCount].ticket      = ticket;
   g_fbChecks[g_fbCount].direction   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                                        ? "buy" : "sell";
   g_fbChecks[g_fbCount].fillBarOpen = iTime(_Symbol, PERIOD_M5, 0);  // current (open) bar
   g_fbChecks[g_fbCount].done        = false;
   g_fbCount++;
  }

//+------------------------------------------------------------------+
//| M5 swing trailing stop                                          |
//+------------------------------------------------------------------+
void SwingTrail(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;

   string dir   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL = PositionGetDouble(POSITION_SL);
   double curTP = PositionGetDouble(POSITION_TP);
   double pip   = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double buf   = InpSwingBuffer * pip;

   double profit = (dir == "buy") ? bid - entry : entry - ask;
   if(profit < InpMinProfitToTrail * pip) return;

   double newSL = 0.0;
   bool   ok    = false;

   if(dir == "buy")
     {
      for(int b = 2; b <= InpSwingLookback + 1; b++)
        {
         double lo = iLow(_Symbol, PERIOD_M5, b);
         if(lo < iLow(_Symbol, PERIOD_M5, b + 1) && lo < iLow(_Symbol, PERIOD_M5, b - 1))
           { newSL = NormalizeDouble(lo - buf, _Digits); break; }
        }
      ok = (newSL > 0.0 && newSL > curSL && newSL < bid);
     }
   else
     {
      for(int b = 2; b <= InpSwingLookback + 1; b++)
        {
         double hi = iHigh(_Symbol, PERIOD_M5, b);
         if(hi > iHigh(_Symbol, PERIOD_M5, b + 1) && hi > iHigh(_Symbol, PERIOD_M5, b - 1))
           { newSL = NormalizeDouble(hi + buf, _Digits); break; }
        }
      ok = (newSL > 0.0 && newSL < curSL && newSL > ask);
     }

   if(!ok) return;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action = TRADE_ACTION_SLTP; req.symbol = _Symbol; req.position = ticket;
   req.sl = newSL; req.tp = curTP;
   if(!OrderSend(req, res))
      Print("ZoneRaider v4e: SwingTrail failed #", ticket, " code=", res.retcode);
   else
      Print("ZoneRaider v4e: Trail #", ticket,
            "  SL ", DoubleToString(curSL, _Digits), " -> ", DoubleToString(newSL, _Digits));
  }

//+------------------------------------------------------------------+
//| Poll server — load zones; place after NY open                   |
//+------------------------------------------------------------------+
void PollServer(const MqlDateTime &dt)
  {
   g_lastPoll = TimeCurrent();
   string sym     = (InpSymbolName != "") ? InpSymbolName : _Symbol;
   string url     = InpServerURL + "/" + sym;
   string headers = "Content-Type: application/json\r\n";
   char   post[], result[];
   string responseHeaders;

   Print("ZoneRaider v4e: Polling ", url);
   int res = WebRequest("GET", url, headers, 5000, post, result, responseHeaders);
   if(res != 200)
     {
      Print("ZoneRaider v4e: Poll failed HTTP=", res);
      return;
     }

   ParseZones(CharArrayToString(result));

   if(!IsAfterNYOpen(dt)) return;

   if(g_zonesLoaded && g_zoneCount > 0)
      PlaceAllOrders();
   else
     {
      Print("ZoneRaider v4e: No zones after NY open — done for today");
      g_ordersPlaced = true;
     }
  }

//+------------------------------------------------------------------+
void ParseZones(const string json)
  {
   g_zoneCount = 0;
   ArrayResize(g_zones, 0);
   if(StringFind(json, "{") < 0) { Print("ZoneRaider v4e: Empty zone list"); return; }

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
         g_zones[g_zoneCount++] = z;
        }
      pos = objEnd;
     }

   if(g_zoneCount > 0)
     {
      g_zonesLoaded = true;
      Print("ZoneRaider v4e: Loaded ", g_zoneCount, " zone(s)");
     }
   else
      Print("ZoneRaider v4e: No actionable S/R zones in response");
  }

//+------------------------------------------------------------------+
bool ParseZoneObject(const string obj, Zone &z)
  {
   z.direction = JsonGetString(obj, "direction");
   z.strength  = JsonGetString(obj, "strength");
   z.kind      = JsonGetString(obj, "kind");

   if(z.direction == "" || z.strength == "" || z.kind == "") return false;
   if(z.direction != "buy" && z.direction != "sell")         return false;

   z.id          = JsonGetString(obj, "id");
   z.watchedOnly = JsonGetBool(obj, "watchedOnly");
   z.price       = JsonGetDouble(obj, "price");
   z.priceFrom   = JsonGetDouble(obj, "from");
   z.priceTo     = JsonGetDouble(obj, "to");

   double buf = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0 * InpEntryBuffer;

   if(z.kind == "point")
     {
      if(z.price == 0.0) return false;
      z.zoneLow  = z.price; z.zoneHigh = z.price;
      z.entryPrice = (z.direction == "buy") ? NormalizeDouble(z.price + buf, _Digits)
                                             : NormalizeDouble(z.price - buf, _Digits);
     }
   else
     {
      if(z.priceFrom == 0.0 || z.priceTo == 0.0) return false;
      z.zoneLow  = MathMin(z.priceFrom, z.priceTo);
      z.zoneHigh = MathMax(z.priceFrom, z.priceTo);
      z.entryPrice = (z.direction == "buy") ? NormalizeDouble(z.zoneHigh + buf, _Digits)
                                             : NormalizeDouble(z.zoneLow  - buf, _Digits);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Place all limit orders                                          |
//| g_ordersPlaced = true is always set before returning           |
//+------------------------------------------------------------------+
void PlaceAllOrders()
  {
   double pip    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double slDist = InpSLPips * pip;

   double minRisk = CalcMinRiskPerPosition(slDist);
   if(minRisk <= 0.0)
     { Print("ZoneRaider v4e: Cannot calculate min risk"); g_ordersPlaced = true; return; }

   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;

   int strongIdx[], buyIdx[], sellIdx[];
   int sCount = 0, bCount = 0, selCount = 0;

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(InpSkipWatchedOnly && g_zones[i].watchedOnly)     continue;
      if(g_zones[i].direction == "buy"  && !InpAllowLong)  continue;
      if(g_zones[i].direction == "sell" && !InpAllowShort) continue;

      if(g_zones[i].strength == "strong")
        { ArrayResize(strongIdx, sCount + 1); strongIdx[sCount++] = i; }
      else if(g_zones[i].direction == "buy")
        { ArrayResize(buyIdx,    bCount + 1); buyIdx[bCount++]    = i; }
      else
        { ArrayResize(sellIdx, selCount + 1); sellIdx[selCount++] = i; }
     }

   for(int i = 0; i < bCount - 1; i++)
      for(int j = 0; j < bCount - 1 - i; j++)
         if(MathAbs(g_zones[buyIdx[j]].entryPrice - mid) > MathAbs(g_zones[buyIdx[j+1]].entryPrice - mid))
           { int t = buyIdx[j]; buyIdx[j] = buyIdx[j+1]; buyIdx[j+1] = t; }

   for(int i = 0; i < selCount - 1; i++)
      for(int j = 0; j < selCount - 1 - i; j++)
         if(MathAbs(g_zones[sellIdx[j]].entryPrice - mid) > MathAbs(g_zones[sellIdx[j+1]].entryPrice - mid))
           { int t = sellIdx[j]; sellIdx[j] = sellIdx[j+1]; sellIdx[j+1] = t; }

   int ordered[]; double weights[]; int oCount = 0;

   for(int i = 0; i < sCount; i++)
     { ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
       ordered[oCount] = strongIdx[i]; weights[oCount] = 1.0; oCount++; }

   int maxRank = (bCount > selCount) ? bCount : selCount;
   for(int rank = 0; rank < maxRank; rank++)
     {
      double w = MathMax(0.1, 1.0 - 0.1 * (rank + 1));
      if(rank < bCount)
        { ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
          ordered[oCount] = buyIdx[rank]; weights[oCount] = w; oCount++; }
      if(rank < selCount)
        { ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
          ordered[oCount] = sellIdx[rank]; weights[oCount] = w; oCount++; }
     }

   if(oCount == 0)
     { Print("ZoneRaider v4e: No qualifying zones"); g_ordersPlaced = true; return; }

   while(oCount > 0 && minRisk * oCount > InpMaxDailyRisk)
     { Print("ZoneRaider v4e: Dropping lowest-priority zone (budget)"); oCount--; }

   if(oCount == 0)
     { Print("ZoneRaider v4e: Budget too small"); g_ordersPlaced = true; return; }

   double weightSum = 0.0;
   for(int q = 0; q < oCount; q++) weightSum += weights[q];

   Print("ZoneRaider v4e: SL=", InpSLPips, "p  TP=", InpTPPips,
         "p  Zones=", oCount, "  Budget=$", InpMaxDailyRisk);

   for(int q = 0; q < oCount; q++)
     {
      double share = (weights[q] / weightSum) * InpMaxDailyRisk;
      PlaceLimitOrder(ordered[q], slDist, share);
     }

   g_ordersPlaced = true;
   Print("ZoneRaider v4e: Placement done. Risk committed: $", NormalizeDouble(g_dailyRiskUsed, 2));
  }

//+------------------------------------------------------------------+
void PlaceLimitOrder(const int idx, const double slDist, const double budget)
  {
   Zone   z     = g_zones[idx];
   double pip   = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double entry = NormalizeDouble(z.entryPrice, _Digits);

   double sl = (z.direction == "buy") ? NormalizeDouble(entry - slDist, _Digits)
                                       : NormalizeDouble(entry + slDist, _Digits);
   double tp = (z.direction == "buy") ? NormalizeDouble(entry + InpTPPips * pip, _Digits)
                                       : NormalizeDouble(entry - InpTPPips * pip, _Digits);

   double lots = CalcLots(slDist, budget);

   MqlDateTime expDt;
   TimeToStruct(TimeGMT(), expDt);
   expDt.hour = InpEODHour; expDt.min = 0; expDt.sec = 0;
   datetime expiry = StructToTime(expDt);

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = _Symbol;
   req.volume       = lots;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.expiration   = expiry;
   req.type_time    = ORDER_TIME_SPECIFIED;
   req.magic        = g_magic;
   req.comment      = z.id;
   req.type_filling = ORDER_FILLING_RETURN;
   req.type         = (z.direction == "buy") ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;

   if(!OrderSend(req, res))
      Print("ZoneRaider v4e: OrderSend failed zone=", idx, " retcode=", res.retcode);
   else
     {
      g_dailyRiskUsed += CalcRiskForLots(lots, slDist);
      Print("ZoneRaider v4e: [", z.strength, "] ", z.direction, " LIMIT #", res.order,
            "  entry=", DoubleToString(entry, _Digits),
            "  sl=", DoubleToString(sl, _Digits),
            "  tp=", DoubleToString(tp, _Digits),
            "  lots=", DoubleToString(lots, 2));
     }
  }

//+------------------------------------------------------------------+
void CloseAndReset()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))                    continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != g_magic)  continue;
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_REMOVE; req.order = ticket;
      OrderSend(req, res);
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      CloseByTicket(ticket);
      Print("ZoneRaider v4e: EOD closed #", ticket);
     }
   g_zoneCount = 0; g_zonesLoaded = false; g_ordersPlaced = false;
   g_dailyRiskUsed = 0.0; g_lastPoll = 0;
   g_fbCount = 0;
   ArrayResize(g_zones, 0);
   ArrayResize(g_fbChecks, 0);
   Print("ZoneRaider v4e: EOD complete");
  }

//+------------------------------------------------------------------+
void CloseByTicket(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.magic        = g_magic;
   req.type_filling = ORDER_FILLING_RETURN;
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
     { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID); }
   else
     { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
   if(!OrderSend(req, res))
      Print("ZoneRaider v4e: CloseByTicket failed #", ticket, " code=", res.retcode);
  }

//+------------------------------------------------------------------+
//| Risk / lot calculations                                         |
//+------------------------------------------------------------------+
double CalcMinRiskPerPosition(const double slDist)
  {
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(tickSize == 0.0 || tickVal == 0.0) return 0.0;
   return (slDist / tickSize) * tickVal * lotMin;
  }

double CalcRiskForLots(const double lots, const double slDist)
  {
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0.0 || tickVal == 0.0) return 0.0;
   return (slDist / tickSize) * tickVal * lots;
  }

double CalcLots(const double slDist, const double budget)
  {
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0.0 || tickVal == 0.0) return lotMin;
   double riskPerLot = (slDist / tickSize) * tickVal;
   if(riskPerLot <= 0.0) return lotMin;
   double lots = MathFloor((budget / riskPerLot) / lotStep) * lotStep;
   return NormalizeDouble(MathMax(lotMin, MathMin(lotMax, lots)), 2);
  }

//+------------------------------------------------------------------+
bool IsAfterNYOpen(const MqlDateTime &dt)
  {
   return (dt.hour > InpNYOpenHour || (dt.hour == InpNYOpenHour && dt.min >= InpNYOpenMinute));
  }

string JsonGetString(const string obj, const string key)
  {
   int kPos  = StringFind(obj, "\"" + key + "\""); if(kPos  < 0) return "";
   int colon = StringFind(obj, ":", kPos);          if(colon < 0) return "";
   int q1    = StringFind(obj, "\"", colon + 1);   if(q1    < 0) return "";
   int q2    = StringFind(obj, "\"", q1 + 1);      if(q2    < 0) return "";
   return StringSubstr(obj, q1 + 1, q2 - q1 - 1);
  }

double JsonGetDouble(const string obj, const string key)
  {
   int kPos  = StringFind(obj, "\"" + key + "\""); if(kPos  < 0) return 0.0;
   int colon = StringFind(obj, ":", kPos);          if(colon < 0) return 0.0;
   int vStart = colon + 1, len = StringLen(obj);
   while(vStart < len && StringGetCharacter(obj, vStart) == ' ') vStart++;
   int vEnd = vStart;
   while(vEnd < len)
     {
      ushort ch = StringGetCharacter(obj, vEnd);
      if(ch == ',' || ch == '}' || ch == ' ' || ch == '\n' || ch == '\r') break;
      vEnd++;
     }
   return StringToDouble(StringSubstr(obj, vStart, vEnd - vStart));
  }

bool JsonGetBool(const string obj, const string key)
  {
   int kPos  = StringFind(obj, "\"" + key + "\""); if(kPos  < 0) return false;
   int colon = StringFind(obj, ":", kPos);          if(colon < 0) return false;
   int vStart = colon + 1, len = StringLen(obj);
   while(vStart < len && StringGetCharacter(obj, vStart) == ' ') vStart++;
   return (StringGetCharacter(obj, vStart) == 't');
  }
//+------------------------------------------------------------------+
