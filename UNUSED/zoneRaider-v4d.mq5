//+------------------------------------------------------------------+
//| ZoneRaider_v4d.mq5                                              |
//| Limit entry · zone-aware SL · watchedOnly=true zones skipped   |
//| Built on zoneRaider-aggr order management (fully tested base)  |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "4.30"

//--- Inputs
input string InpServerURL        = "http://37.46.211.146:3000"; // Server URL
input string InpSymbolName       = "";                          // Symbol for URL (blank = chart symbol)
input bool   InpAllowLong        = true;                        // Allow buy entries
input bool   InpAllowShort       = true;                        // Allow sell entries
input int    InpSLPips           = 15;                          // SL for kind=point zones (pips)
input int    InpZoneSLBuffer     = 3;                           // Extra buffer pips beyond zone edge (kind=zone SL)
input int    InpMinZoneSLPips    = 8;                           // Minimum SL distance in pips (floor for zone-aware)
input int    InpTPPips           = 20;                          // Take profit (pips)
input double InpMaxDailyRisk     = 100.0;                       // Total daily risk budget ($)
input int    InpPollMinutes      = 10;                          // Poll interval (minutes)
input int    InpNYOpenHour       = 13;                          // NY open hour (UTC)
input int    InpNYOpenMinute     = 30;                          // NY open minute (UTC)
input int    InpEODHour          = 21;                          // EOD hour — closes all (UTC)
input bool   InpSkipWeekends     = true;                        // Skip Sat/Sun
input int    InpEntryBuffer      = 0;                           // Pips past zone boundary for limit entry
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

//--- Globals
Zone     g_zones[];
int      g_zoneCount     = 0;
bool     g_zonesLoaded   = false;
bool     g_ordersPlaced  = false;
datetime g_lastPoll      = 0;
double   g_dailyRiskUsed = 0.0;
long     g_magic         = 20260404;
bool     g_eodDone       = false;
int      g_lastDay       = -1;
datetime g_lastM5Bar     = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(30);
   Print("ZoneRaider v4d: Initialized on ", _Symbol, "  magic=", g_magic,
         "  ZoneSLBuf=", InpZoneSLBuffer, "p  MinSL=", InpMinZoneSLPips, "p");
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
      ArrayResize(g_zones, 0);
      Print("ZoneRaider v4d: New day — session reset");
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
//| OnTick — M5 swing trail + 4h force close                       |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime m5Open = iTime(_Symbol, PERIOD_M5, 0);
   bool     newBar = (m5Open != g_lastM5Bar);
   if(newBar) g_lastM5Bar = m5Open;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;

      if(newBar) SwingTrail(ticket);

      if(TimeCurrent() - (datetime)PositionGetInteger(POSITION_TIME) >= 4 * 3600)
        {
         Print("ZoneRaider v4d: 4h close #", ticket);
         CloseByTicket(ticket);
        }
     }
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
      Print("ZoneRaider v4d: SwingTrail failed #", ticket, " code=", res.retcode);
   else
      Print("ZoneRaider v4d: Trail #", ticket,
            "  SL ", DoubleToString(curSL, _Digits), " -> ", DoubleToString(newSL, _Digits));
  }

//+------------------------------------------------------------------+
//| Zone-aware SL distance                                          |
//| kind=zone: SL sits beyond the far edge of the zone             |
//| kind=point: fixed InpSLPips                                    |
//+------------------------------------------------------------------+
double ComputeSlDist(const Zone &z)
  {
   double pip     = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double minDist = InpMinZoneSLPips * pip;

   if(z.kind == "zone")
     {
      double slBuf   = InpZoneSLBuffer * pip;
      double farEdge = (z.direction == "buy")
                        ? z.zoneLow  - slBuf
                        : z.zoneHigh + slBuf;
      return MathMax(MathAbs(z.entryPrice - farEdge), minDist);
     }

   return MathMax(InpSLPips * pip, minDist);
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

   Print("ZoneRaider v4d: Polling ", url);
   int res = WebRequest("GET", url, headers, 5000, post, result, responseHeaders);
   if(res != 200)
     {
      Print("ZoneRaider v4d: Poll failed HTTP=", res);
      return;
     }

   ParseZones(CharArrayToString(result));

   if(!IsAfterNYOpen(dt)) return;

   if(g_zonesLoaded && g_zoneCount > 0)
      PlaceAllOrders();
   else
     {
      Print("ZoneRaider v4d: No confirmed zones after NY open — done for today");
      g_ordersPlaced = true;
     }
  }

//+------------------------------------------------------------------+
void ParseZones(const string json)
  {
   g_zoneCount = 0;
   ArrayResize(g_zones, 0);
   if(StringFind(json, "{") < 0) { Print("ZoneRaider v4d: Empty zone list"); return; }

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
      Print("ZoneRaider v4d: Loaded ", g_zoneCount, " confirmed zone(s)");
     }
   else
      Print("ZoneRaider v4d: No confirmed (non-watched) zones in response");
  }

//+------------------------------------------------------------------+
//| watchedOnly=true zones are rejected here — confirmed levels only |
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
   if(z.watchedOnly) return false;   // v4d: confirmed levels only

   z.price     = JsonGetDouble(obj, "price");
   z.priceFrom = JsonGetDouble(obj, "from");
   z.priceTo   = JsonGetDouble(obj, "to");

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
   double pip      = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double proxySL  = InpSLPips * pip;   // used only for min-risk budget check

   double minRisk = CalcMinRiskPerPosition(proxySL);
   if(minRisk <= 0.0)
     { Print("ZoneRaider v4d: Cannot calculate min risk"); g_ordersPlaced = true; return; }

   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;

   int strongIdx[], buyIdx[], sellIdx[];
   int sCount = 0, bCount = 0, selCount = 0;

   for(int i = 0; i < g_zoneCount; i++)
     {
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
     { Print("ZoneRaider v4d: No qualifying zones"); g_ordersPlaced = true; return; }

   while(oCount > 0 && minRisk * oCount > InpMaxDailyRisk)
     { Print("ZoneRaider v4d: Dropping lowest-priority zone (budget)"); oCount--; }

   if(oCount == 0)
     { Print("ZoneRaider v4d: Budget too small"); g_ordersPlaced = true; return; }

   double weightSum = 0.0;
   for(int q = 0; q < oCount; q++) weightSum += weights[q];

   Print("ZoneRaider v4d: ZoneAwareSL  TP=", InpTPPips,
         "p  Zones=", oCount, "  Budget=$", InpMaxDailyRisk);

   for(int q = 0; q < oCount; q++)
     {
      double share = (weights[q] / weightSum) * InpMaxDailyRisk;
      PlaceLimitOrder(ordered[q], share);
     }

   g_ordersPlaced = true;
   Print("ZoneRaider v4d: Placement done. Risk committed: $", NormalizeDouble(g_dailyRiskUsed, 2));
  }

//+------------------------------------------------------------------+
//| Place one limit order — SL computed per-zone                   |
//+------------------------------------------------------------------+
void PlaceLimitOrder(const int idx, const double budget)
  {
   Zone   z      = g_zones[idx];
   double pip    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   double entry  = NormalizeDouble(z.entryPrice, _Digits);
   double slDist = ComputeSlDist(z);

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
      Print("ZoneRaider v4d: OrderSend failed zone=", idx, " retcode=", res.retcode);
   else
     {
      g_dailyRiskUsed += CalcRiskForLots(lots, slDist);
      string slNote = (z.kind == "zone") ? "zone-aware" : "fixed";
      Print("ZoneRaider v4d: [", z.strength, "] ", z.direction, " LIMIT #", res.order,
            "  entry=", DoubleToString(entry, _Digits),
            "  sl=", DoubleToString(sl, _Digits),
            " (", slNote, " ", DoubleToString(slDist / pip, 1), "p)",
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
      Print("ZoneRaider v4d: EOD closed #", ticket);
     }
   g_zoneCount = 0; g_zonesLoaded = false; g_ordersPlaced = false;
   g_dailyRiskUsed = 0.0; g_lastPoll = 0;
   ArrayResize(g_zones, 0);
   Print("ZoneRaider v4d: EOD complete");
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
      Print("ZoneRaider v4d: CloseByTicket failed #", ticket, " code=", res.retcode);
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
