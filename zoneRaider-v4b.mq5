//+------------------------------------------------------------------+
//| ZoneRaider_v4b.mq5                                              |
//| Wider SL=25p/TP=35p — survives zone probe spikes before bounce  |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "4.10"

//--- Inputs
input string InpServerURL         = "http://37.46.211.146:3000"; // Server URL
input string InpSymbolName        = "";                       // Symbol for URL (blank = chart symbol)
input bool   InpAllowLong         = true;                     // Allow buy entries
input bool   InpAllowShort        = true;                     // Allow sell entries
input int    InpSLPips            = 25;                       // Initial stop loss (pips) — wider to survive zone probes
input int    InpTPPips            = 35;                       // Take profit (pips)
input double InpMaxDailyRisk      = 120.0;                    // Total daily risk budget ($)
input int    InpPollMinutes       = 20;                       // Poll interval (minutes)
input int    InpNYOpenHour        = 13;                       // NY open hour (UTC) — warning deadline only
input int    InpNYOpenMinute      = 30;                       // NY open minute (UTC)
input int    InpEODHour           = 21;                       // EOD close hour (UTC)
input bool   InpSkipWeekends      = true;                     // Skip Sat/Sun
input int    InpEntryBuffer       = 0;                        // Pips past zone boundary for limit entry
input int    InpSwingLookback     = 10;                       // M5 bars to search for swing point
input int    InpMinProfitToTrail  = 15;                       // Pips in profit before trail activates
input int    InpSwingBuffer       = 3;                        // Buffer pips beyond swing point

//+------------------------------------------------------------------+
//| Zone — one S/R level from server                                |
//+------------------------------------------------------------------+
struct Zone
  {
   string   id;
   string   direction;   // "buy" | "sell"
   string   strength;    // "strong" | "regular"
   string   kind;        // "point" | "zone"
   bool     watchedOnly;
   double   price;
   double   priceFrom;
   double   priceTo;
   double   zoneLow;
   double   zoneHigh;
   double   entryPrice;  // computed limit price
  };

//--- Globals
Zone       g_zones[];
int        g_zoneCount     = 0;
bool       g_zonesLoaded   = false;
bool       g_ordersPlaced  = false;
datetime   g_lastPoll      = 0;
string     g_placedIds[];
int        g_placedCount   = 0;
double     g_dailyRiskUsed = 0.0;
long       g_magic         = 20260402;
bool       g_eodDone       = false;
int        g_lastDay       = -1;
datetime   g_lastM5Bar     = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(30);
   Print("ZoneRaider v4b: Initialized on ", _Symbol, "  magic=", g_magic,
         "  SL=", InpSLPips, "p  TP=", InpTPPips, "p");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| Timer — session management and polling                          |
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
      g_ordersPlaced  = false;
      g_lastPoll      = 0;
      g_lastM5Bar     = 0;
      g_dailyRiskUsed = 0.0;
      g_zoneCount     = 0;
      g_placedCount   = 0;
      ArrayResize(g_zones, 0);
      ArrayResize(g_placedIds, 0);
      Print("ZoneRaider v4b: New day — session reset");
     }

   //--- EOD
   if(dt.hour >= InpEODHour)
     {
      if(!g_eodDone) { CloseAndReset(); g_eodDone = true; }
      return;
     }

   //--- Orders already placed — nothing left to do until next day
   if(g_ordersPlaced) return;

   //--- Poll on interval; place orders immediately when zones are received
   if(!g_zonesLoaded)
     {
      if(TimeCurrent() - g_lastPoll < InpPollMinutes * 60) return;
      if(IsAfterNYOpen(dt))
         Print("ZoneRaider v4b: WARNING — past NY open, zones not yet loaded");
      PollServer();
     }

   //--- Place immediately once zones are available
   if(g_zonesLoaded && g_zoneCount > 0)
     {
      PlaceAllOrders();
      g_ordersPlaced = true;
     }
  }

//+------------------------------------------------------------------+
//| OnTick — swing trail and 4h force close                        |
//| No tracking struct: reads live position data directly           |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime m5Open = iTime(_Symbol, PERIOD_M5, 0);
   bool newM5Bar   = (m5Open != g_lastM5Bar);
   if(newM5Bar) g_lastM5Bar = m5Open;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;

      //--- Swing trail fires only on new M5 bar
      if(newM5Bar) SwingTrail(ticket);

      //--- 4h force close
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - openTime >= 4 * 3600)
        {
         Print("ZoneRaider v4b: 4h close #", ticket);
         CloseByTicket(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Swing-based trailing stop                                       |
//|                                                                 |
//| Guards:                                                         |
//|   1. Must be InpMinProfitToTrail pips in profit first          |
//|   2. New SL must be at confirmed swing point ± buffer           |
//|   3. New SL must strictly improve current SL                   |
//|   4. New SL must not overshoot current bid/ask                 |
//+------------------------------------------------------------------+
void SwingTrail(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;

   string dir      = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
   double entry    = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double pip      = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double buf      = InpSwingBuffer * pip;
   int    lb       = InpSwingLookback;

   //--- Profit guard: do not trail until we are comfortably in profit
   double profit = (dir == "buy") ? bid - entry : entry - ask;
   if(profit < InpMinProfitToTrail * pip) return;

   double newSL  = 0.0;
   bool   improve = false;

   if(dir == "buy")
     {
      //--- Find most recent confirmed swing low (bar[b] is lower than neighbours)
      //--- Start at b=2 so bar[1] (already closed) acts as right-side confirmation
      double swingLow = 0.0;
      for(int b = 2; b <= lb + 1; b++)
        {
         double lo     = iLow(_Symbol, PERIOD_M5, b);
         double loPrev = iLow(_Symbol, PERIOD_M5, b + 1);
         double loNext = iLow(_Symbol, PERIOD_M5, b - 1);
         if(lo < loPrev && lo < loNext) { swingLow = lo; break; }
        }
      if(swingLow > 0.0)
        {
         newSL   = NormalizeDouble(swingLow - buf, _Digits);
         improve = (newSL > currentSL) && (newSL < bid);
        }
     }
   else
     {
      //--- Find most recent confirmed swing high
      double swingHigh = 0.0;
      for(int b = 2; b <= lb + 1; b++)
        {
         double hi     = iHigh(_Symbol, PERIOD_M5, b);
         double hiPrev = iHigh(_Symbol, PERIOD_M5, b + 1);
         double hiNext = iHigh(_Symbol, PERIOD_M5, b - 1);
         if(hi > hiPrev && hi > hiNext) { swingHigh = hi; break; }
        }
      if(swingHigh > 0.0)
        {
         newSL   = NormalizeDouble(swingHigh + buf, _Digits);
         improve = (newSL < currentSL) && (newSL > ask);
        }
     }

   if(!improve || newSL <= 0.0) return;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = ticket;
   req.sl       = newSL;
   req.tp       = currentTP;
   if(!OrderSend(req, res))
      Print("ZoneRaider v4b: SwingTrail failed #", ticket, "  code=", res.retcode);
   else
      Print("ZoneRaider v4b: Trail #", ticket,
            "  SL ", DoubleToString(currentSL, _Digits),
            " -> ", DoubleToString(newSL, _Digits));
  }

//+------------------------------------------------------------------+
//| Poll server                                                     |
//+------------------------------------------------------------------+
void PollServer()
  {
   g_lastPoll = TimeCurrent();
   string sym     = (InpSymbolName != "") ? InpSymbolName : _Symbol;
   string url     = InpServerURL + "/" + sym;
   string headers = "Content-Type: application/json\r\n";
   char   post[], result[];
   string responseHeaders;

   Print("ZoneRaider v4: Polling ", url);
   int res = WebRequest("GET", url, headers, 5000, post, result, responseHeaders);
   if(res != 200)
     {
      Print("ZoneRaider v4b: Poll failed HTTP=", res,
            "  (whitelist ", url, " in Tools > Options > Expert Advisors)");
      return;
     }
   ParseZones(CharArrayToString(result));
  }

//+------------------------------------------------------------------+
//| Parse zone array from JSON                                      |
//+------------------------------------------------------------------+
void ParseZones(const string json)
  {
   g_zoneCount = 0;
   ArrayResize(g_zones, 0);

   if(StringFind(json, "{") < 0)
     {
      Print("ZoneRaider v4b: Empty zone list");
      return;
     }

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
      Print("ZoneRaider v4b: Loaded ", g_zoneCount, " zone(s)");
     }
   else
      Print("ZoneRaider v4b: No actionable S/R zones");
  }

//+------------------------------------------------------------------+
//| Parse single zone JSON object                                   |
//+------------------------------------------------------------------+
bool ParseZoneObject(const string obj, Zone &z)
  {
   z.direction  = JsonGetString(obj, "direction");
   z.strength   = JsonGetString(obj, "strength");
   z.kind       = JsonGetString(obj, "kind");

   if(z.direction == "" || z.strength == "" || z.kind == "") return false;
   // Skip options zones — handled by separate optionRaider EA
   if(z.direction != "buy" && z.direction != "sell")          return false;

   z.id          = JsonGetString(obj, "id");
   z.watchedOnly = JsonGetBool(obj, "watchedOnly");
   z.price       = JsonGetDouble(obj, "price");
   z.priceFrom   = JsonGetDouble(obj, "from");
   z.priceTo     = JsonGetDouble(obj, "to");

   double buf = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0 * InpEntryBuffer;

   if(z.kind == "point")
     {
      if(z.price == 0.0) return false;
      z.zoneLow    = z.price;
      z.zoneHigh   = z.price;
      z.entryPrice = (z.direction == "buy")
                      ? NormalizeDouble(z.price + buf, _Digits)
                      : NormalizeDouble(z.price - buf, _Digits);
     }
   else
     {
      if(z.priceFrom == 0.0 || z.priceTo == 0.0) return false;
      z.zoneLow    = MathMin(z.priceFrom, z.priceTo);
      z.zoneHigh   = MathMax(z.priceFrom, z.priceTo);
      z.entryPrice = (z.direction == "buy")
                      ? NormalizeDouble(z.zoneHigh + buf, _Digits)
                      : NormalizeDouble(z.zoneLow  - buf, _Digits);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| True if our magic already has a position or pending order at    |
//| this direction and price level (±1.5 pip tolerance).            |
//+------------------------------------------------------------------+
bool HasOpenAtLevel(const string direction, const double price)
  {
   double pip       = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double tolerance = pip * 1.5;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t))                    continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      string posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
      if(posDir != direction)                            continue;
      if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - price) <= tolerance) return true;
     }

   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(!OrderSelect(t))                          continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC) != g_magic)   continue;
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool isLong   = (ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY);
      string orderDir = isLong ? "buy" : "sell";
      if(orderDir != direction)                     continue;
      if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) <= tolerance) return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Place all limit orders with weighted budget allocation          |
//+------------------------------------------------------------------+
void PlaceAllOrders()
  {
   double pip    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double slDist = InpSLPips * pip;

   double minRisk = CalcMinRiskPerPosition(slDist);
   if(minRisk <= 0.0) { Print("ZoneRaider v4b: Cannot calculate min risk"); return; }

   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) +
                 SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;

   //--- Bucket into strong / regular-buy / regular-sell
   int strongIdx[], buyIdx[], sellIdx[];
   int sCount = 0, bCount = 0, selCount = 0;

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_zones[i].direction == "buy"  && !InpAllowLong)  continue;
      if(g_zones[i].direction == "sell" && !InpAllowShort) continue;

      if(g_zones[i].strength == "strong")
        { ArrayResize(strongIdx, sCount+1);  strongIdx[sCount++]  = i; }
      else if(g_zones[i].direction == "buy")
        { ArrayResize(buyIdx,    bCount+1);  buyIdx[bCount++]     = i; }
      else
        { ArrayResize(sellIdx,   selCount+1); sellIdx[selCount++] = i; }
     }

   //--- Sort regular zones by proximity to mid-price (closest first)
   for(int i = 0; i < bCount - 1; i++)
      for(int j = 0; j < bCount - 1 - i; j++)
         if(MathAbs(g_zones[buyIdx[j]].entryPrice - mid) >
            MathAbs(g_zones[buyIdx[j+1]].entryPrice - mid))
           { int t = buyIdx[j]; buyIdx[j] = buyIdx[j+1]; buyIdx[j+1] = t; }

   for(int i = 0; i < selCount - 1; i++)
      for(int j = 0; j < selCount - 1 - i; j++)
         if(MathAbs(g_zones[sellIdx[j]].entryPrice - mid) >
            MathAbs(g_zones[sellIdx[j+1]].entryPrice - mid))
           { int t = sellIdx[j]; sellIdx[j] = sellIdx[j+1]; sellIdx[j+1] = t; }

   //--- Build raw ordered list: strong first (w=1.0), then interleaved regular (w=0.9 …)
   int ordered[]; double weights[]; int oCount = 0;
   ArrayResize(ordered, 0); ArrayResize(weights, 0);

   for(int i = 0; i < sCount; i++)
     {
      ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
      ordered[oCount] = strongIdx[i]; weights[oCount] = 1.0; oCount++;
     }

   int maxRank = (bCount > selCount) ? bCount : selCount;
   for(int rank = 0; rank < maxRank; rank++)
     {
      double w = MathMax(0.1, 1.0 - 0.1 * (rank + 1));
      if(rank < bCount)
        {
         ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
         ordered[oCount] = buyIdx[rank]; weights[oCount] = w; oCount++;
        }
      if(rank < selCount)
        {
         ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
         ordered[oCount] = sellIdx[rank]; weights[oCount] = w; oCount++;
        }
     }

   if(oCount == 0) { Print("ZoneRaider v4b: No qualifying zones"); return; }

   //--- Deduplicate: one order per direction+price level; skip already-placed IDs
   //    and levels already covered by an open position or pending order.
   int    filtered[]; double filteredW[]; int fCount = 0;
   string batchLevels[]; int blCount = 0;

   for(int q = 0; q < oCount; q++)
     {
      Zone z = g_zones[ordered[q]];

      bool alreadyPlaced = false;
      for(int k = 0; k < g_placedCount; k++)
        { if(g_placedIds[k] == z.id) { alreadyPlaced = true; break; } }
      if(alreadyPlaced) { Print("ZoneRaider v4b: Zone already placed — skipped: ", z.id); continue; }

      long   priceKey  = (long)MathRound(z.entryPrice / pip);
      string levelKey  = z.direction + "|" + IntegerToString(priceKey);
      bool   duplicate = false;
      for(int k = 0; k < blCount; k++)
        { if(batchLevels[k] == levelKey) { duplicate = true; break; } }
      if(duplicate) { Print("ZoneRaider v4b: Duplicate price level skipped: ", levelKey); continue; }

      if(HasOpenAtLevel(z.direction, z.entryPrice))
        { Print("ZoneRaider v4b: Level already covered: ", z.direction, " @ ", DoubleToString(z.entryPrice, _Digits)); continue; }

      ArrayResize(filtered,     fCount+1); ArrayResize(filteredW,   fCount+1);
      ArrayResize(batchLevels, blCount+1);
      filtered[fCount] = ordered[q]; filteredW[fCount] = weights[q]; fCount++;
      batchLevels[blCount++] = levelKey;
     }

   if(fCount == 0) { Print("ZoneRaider v4b: No unique uncovered zones to place"); return; }

   //--- Drop lowest-priority tail if total risk exceeds daily budget
   while(fCount > 0 && minRisk * fCount > InpMaxDailyRisk)
     { Print("ZoneRaider v4b: Dropping lowest-priority zone (budget)"); fCount--; }
   if(fCount == 0) { Print("ZoneRaider v4b: Budget too small"); return; }

   double weightSum = 0.0;
   for(int q = 0; q < fCount; q++) weightSum += filteredW[q];

   Print("ZoneRaider v4b: Placing ", fCount, " order(s)  SL=", InpSLPips,
         "p  TP=", InpTPPips, "p  Budget=$", InpMaxDailyRisk);

   for(int q = 0; q < fCount; q++)
     {
      double share = (filteredW[q] / weightSum) * InpMaxDailyRisk;
      PlaceLimitOrder(filtered[q], slDist, share);
     }
  }

//+------------------------------------------------------------------+
//| Place one limit order                                           |
//+------------------------------------------------------------------+
void PlaceLimitOrder(const int idx, const double slDist, const double budget)
  {
   Zone   z    = g_zones[idx];
   double entry = NormalizeDouble(z.entryPrice, _Digits);

   //--- Final guard: never place if this level is already covered
   if(HasOpenAtLevel(z.direction, entry))
     {
      Print("ZoneRaider v4b: PlaceLimitOrder skip — already covered: ",
            z.direction, " @ ", DoubleToString(entry, _Digits));
      return;
     }

   double pip  = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

   double sl = (z.direction == "buy")
                ? NormalizeDouble(entry - slDist, _Digits)
                : NormalizeDouble(entry + slDist, _Digits);
   double tp = (z.direction == "buy")
                ? NormalizeDouble(entry + InpTPPips * pip, _Digits)
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
     {
      Print("ZoneRaider v4b: OrderSend failed zone=", idx,
            "  retcode=", res.retcode, "  ", res.comment);
      return;
     }

   double risk = CalcRiskForLots(lots, slDist);
   g_dailyRiskUsed += risk;

   ArrayResize(g_placedIds, g_placedCount + 1);
   g_placedIds[g_placedCount++] = z.id;

   Print("ZoneRaider v4b: [", z.strength, "] ", z.direction,
         " LIMIT #", res.order,
         "  entry=", DoubleToString(entry, _Digits),
         "  sl=",    DoubleToString(sl,    _Digits),
         "  tp=",    DoubleToString(tp,    _Digits),
         "  lots=",  DoubleToString(lots,  2),
         "  risk=$", NormalizeDouble(risk, 2));
  }

//+------------------------------------------------------------------+
//| EOD — cancel pending orders, close positions, reset state      |
//+------------------------------------------------------------------+
void CloseAndReset()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))                     continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC) != g_magic)   continue;
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;
      if(!OrderSend(req, res))
         Print("ZoneRaider v4b: Cancel order failed #", ticket, "  code=", res.retcode);
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      CloseByTicket(ticket);
      Print("ZoneRaider v4b: EOD closed #", ticket);
     }

   g_zoneCount     = 0;
   g_zonesLoaded   = false;
   g_ordersPlaced  = false;
   g_dailyRiskUsed = 0.0;
   g_lastPoll      = 0;
   g_placedCount   = 0;
   ArrayResize(g_zones, 0);
   ArrayResize(g_placedIds, 0);
   Print("ZoneRaider v4b: EOD complete");
  }

//+------------------------------------------------------------------+
//| Close a position by ticket                                      |
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
      Print("ZoneRaider v4: CloseByTicket failed #", ticket, "  code=", res.retcode);
  }



//+------------------------------------------------------------------+
//| Risk / lot calculations                                        |
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

//+------------------------------------------------------------------+
//| Session helper                                                  |
//+------------------------------------------------------------------+
bool IsAfterNYOpen(const MqlDateTime &dt)
  {
   return (dt.hour > InpNYOpenHour ||
          (dt.hour == InpNYOpenHour && dt.min >= InpNYOpenMinute));
  }

//+------------------------------------------------------------------+
//| JSON helpers                                                    |
//+------------------------------------------------------------------+
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

// Booleans are not quoted in JSON — check first non-space char after colon
bool JsonGetBool(const string obj, const string key)
  {
   int kPos  = StringFind(obj, "\"" + key + "\""); if(kPos  < 0) return false;
   int colon = StringFind(obj, ":", kPos);          if(colon < 0) return false;
   int vStart = colon + 1, objLen = StringLen(obj);
   while(vStart < objLen && StringGetCharacter(obj, vStart) == ' ') vStart++;
   return (StringGetCharacter(obj, vStart) == 't');
  }
//+------------------------------------------------------------------+
