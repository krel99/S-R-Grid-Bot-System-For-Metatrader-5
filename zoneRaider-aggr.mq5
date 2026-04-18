//+------------------------------------------------------------------+
//| ZoneTrader_v2A.mq5                                               |
//| Aggressive: limit at zone boundary, fixed SL/TP, trailing stop   |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "2.00"

//--- Inputs
input string InpServerURL      = "http://127.0.0.1:3000"; // Server URL
input string InpSymbolName     = "";                       // Symbol for URL (blank = chart symbol)
input bool   InpAllowLong      = true;                     // Allow buy entries
input bool   InpAllowShort     = true;                     // Allow sell entries
input int    InpSLPips         = 15;                       // Stop loss — normal (pips)
input int    InpSLLowVolPips   = 10;                       // Stop loss — low volatility (pips)
input bool   InpLowVolMode     = false;                    // Use low volatility SL
input int    InpTPPips         = 20;                       // Take profit (pips)
input double InpMaxDailyRisk   = 100.0;                    // Total daily risk budget ($)
input int    InpMaxPositions   = 6;                        // Max simultaneous positions
input int    InpPollMinutes    = 10;                       // Poll interval (minutes)
input int    InpNYOpenHour     = 13;                       // NY open hour (UTC)
input int    InpNYOpenMinute   = 30;                       // NY open minute (UTC)
input int    InpEODHour        = 21;                       // EOD hour — closes all positions and pending orders (UTC)
input bool   InpSkipWeekends   = true;                     // Skip weekends
input int    InpEntryBuffer    = 0;                        // Entry buffer (pips, 0 = exact zone boundary)

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
   double   entryPrice;   // zone boundary: top for buy, bottom for sell
   double   zoneLow;
   double   zoneHigh;
  };

//--- Tracking struct (trailing, 4h close)
struct TrackEntry
  {
   ulong    ticket;
   string   direction;
   double   entryPrice;
   double   slDistance;   // pip distance — used for trailing
   datetime openTime;
   bool     isOpen;
   string   closedBy;
  };

//--- Globals
Zone       g_zones[];
int        g_zoneCount    = 0;
bool       g_zonesLoaded  = false;
bool       g_ordersPlaced = false;
datetime   g_lastPoll     = 0;
double     g_dailyRiskUsed = 0.0;
long       g_magic        = 20260301;
TrackEntry g_tracking[];
int        g_trackCount   = 0;
bool       g_eodDone      = false;
int        g_lastDay      = -1;

//+------------------------------------------------------------------+
//| Active SL in pips                                                 |
//+------------------------------------------------------------------+
int ActiveSLPips() { return InpLowVolMode ? InpSLLowVolPips : InpSLPips; }

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(30);
   Print("ZoneTrader 2A: Initialized on ", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| Timer — session management and polling                            |
//+------------------------------------------------------------------+
void OnTimer()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);

   if(InpSkipWeekends && (dt.day_of_week == 0 || dt.day_of_week == 6))
      return;

   if(dt.day_of_year != g_lastDay)
     {
      g_lastDay       = dt.day_of_year;
      g_eodDone       = false;
      g_zonesLoaded   = false;
      g_ordersPlaced  = false;
      g_dailyRiskUsed = 0.0;
      g_lastPoll      = 0;
      g_zoneCount     = 0;
      ArrayResize(g_zones, 0);
      Print("ZoneTrader 2A: New day — session reset");
     }

   if(dt.hour == InpEODHour)
     {
      if(!g_eodDone) { CloseAndReset(); g_eodDone = true; }
      return;
     }

   if(g_ordersPlaced) return;

   if(IsAfterNYOpen(dt) && !g_zonesLoaded)
     {
      if(TimeCurrent() - g_lastPoll >= InpPollMinutes * 60)
        {
         PollServer();
         if(!g_zonesLoaded) { Print("ZoneTrader 2A: No zones after NY open — done"); g_ordersPlaced = true; }
        }
      return;
     }

   if(TimeCurrent() - g_lastPoll < InpPollMinutes * 60) return;

   PollServer();
  }

//+------------------------------------------------------------------+
//| OnTick — trailing, fill detection, 4h close                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))               continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      if(FindTrackIdx(ticket) < 0) AddTrackEntry(ticket);
     }

   for(int i = 0; i < g_trackCount; i++)
     {
      if(!g_tracking[i].isOpen) continue;

      bool posExists = PositionSelectByTicket(g_tracking[i].ticket);

      if(!posExists)
        {
         g_tracking[i].isOpen   = false;
         g_tracking[i].closedBy = DetectCloseReason(g_tracking[i].ticket);
         Print("ZoneTrader 2A: #", g_tracking[i].ticket, " closed — ", g_tracking[i].closedBy);
         continue;
        }

      TrailStop(i);

      if(TimeCurrent() - g_tracking[i].openTime >= 4 * 3600)
        {
         g_tracking[i].closedBy = "4h";
         CloseByTicket(g_tracking[i].ticket);
         g_tracking[i].isOpen = false;
         Print("ZoneTrader 2A: 4h close #", g_tracking[i].ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Trail stop                                                        |
//+------------------------------------------------------------------+
void TrailStop(const int idx)
  {
   if(!PositionSelectByTicket(g_tracking[idx].ticket)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double newSL;
   bool   improve = false;

   if(g_tracking[idx].direction == "buy")
     {
      newSL   = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - g_tracking[idx].slDistance, _Digits);
      improve = newSL > currentSL;
     }
   else
     {
      newSL   = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + g_tracking[idx].slDistance, _Digits);
      improve = newSL < currentSL;
     }

   if(!improve) return;

   MqlTradeRequest req = {}; MqlTradeResult res = {};
   req.action   = TRADE_ACTION_SLTP;
   req.symbol   = _Symbol;
   req.position = g_tracking[idx].ticket;
   req.sl       = newSL;
   req.tp       = currentTP;
   if(!OrderSend(req, res))
      Print("ZoneTrader 2A: Trail SL failed #", g_tracking[idx].ticket, " code=", res.retcode);
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
   req.type_filling = ORDER_FILLING_RETURN;
   if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
     { req.type = ORDER_TYPE_SELL; req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID); }
   else
     { req.type = ORDER_TYPE_BUY;  req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK); }
   if(!OrderSend(req, res))
      Print("ZoneTrader 2A: CloseByTicket failed #", ticket, " code=", res.retcode);
  }

//+------------------------------------------------------------------+
//| EOD — cancel pending, close positions, reset                     |
//+------------------------------------------------------------------+
void CloseAndReset()
  {
   for(int i = g_trackCount - 1; i >= 0; i--)
      if(g_tracking[i].isOpen && g_tracking[i].closedBy == "")
         g_tracking[i].closedBy = "EOD";

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))                     continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC) != g_magic)   continue;
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_REMOVE; req.order = ticket;
      OrderSend(req, res);
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))              continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      CloseByTicket(ticket);
      Print("ZoneTrader 2A: EOD closed #", ticket);
     }

   g_zoneCount     = 0;
   g_zonesLoaded   = false;
   g_ordersPlaced  = false;
   g_dailyRiskUsed = 0.0;
   g_lastPoll      = 0;
   ArrayResize(g_zones, 0);
   Print("ZoneTrader 2A: EOD complete");
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

   Print("ZoneTrader 2A: Polling ", url);
   int res = WebRequest("GET", url, headers, 5000, post, result, responseHeaders);
   if(res != 200)
     {
      Print("ZoneTrader 2A: Poll failed HTTP=", res, " (whitelist URL)");
      return;
     }

   ParseZones(CharArrayToString(result));
   if(g_zonesLoaded && g_zoneCount > 0) PlaceAllOrders();
  }

//+------------------------------------------------------------------+
//| Parse zones                                                       |
//+------------------------------------------------------------------+
void ParseZones(const string json)
  {
   g_zoneCount = 0;
   ArrayResize(g_zones, 0);
   if(StringFind(json, "{") < 0) { Print("ZoneTrader 2A: Empty zone list"); return; }

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
      SortZonesByPrice();
      g_zonesLoaded = true;
      Print("ZoneTrader 2A: Loaded ", g_zoneCount, " zone(s)");
     }
  }

//+------------------------------------------------------------------+
//| Parse single zone object                                          |
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

   double buf = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10 * InpEntryBuffer;

   if(z.kind == "point")
     {
      if(z.price == 0.0) return false;
      z.zoneLow  = z.price;
      z.zoneHigh = z.price;
      z.entryPrice = (z.direction == "buy")
                      ? NormalizeDouble(z.price + buf, _Digits)
                      : NormalizeDouble(z.price - buf, _Digits);
     }
   else
     {
      if(z.priceFrom == 0.0 || z.priceTo == 0.0) return false;
      z.zoneLow  = MathMin(z.priceFrom, z.priceTo);
      z.zoneHigh = MathMax(z.priceFrom, z.priceTo);
      z.entryPrice = (z.direction == "buy")
                      ? NormalizeDouble(z.zoneHigh + buf, _Digits)
                      : NormalizeDouble(z.zoneLow  - buf, _Digits);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Sort zones by entry price ascending                              |
//+------------------------------------------------------------------+
void SortZonesByPrice()
  {
   for(int i = 0; i < g_zoneCount - 1; i++)
      for(int j = 0; j < g_zoneCount - 1 - i; j++)
         if(g_zones[j].entryPrice > g_zones[j+1].entryPrice)
           { Zone t = g_zones[j]; g_zones[j] = g_zones[j+1]; g_zones[j+1] = t; }
  }

//+------------------------------------------------------------------+
//| Place all limit orders with weighted budget allocation            |
//+------------------------------------------------------------------+
void PlaceAllOrders()
  {
   double pip    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double slDist = ActiveSLPips() * pip;

   double minRiskPerPos = CalcMinRiskPerPosition(slDist);
   if(minRiskPerPos <= 0.0) { Print("ZoneTrader 2A: Cannot calc min risk"); return; }

   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) +
                 SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;

   //--- Separate into strong / regular-buy / regular-sell
   int strongIdx[], buyIdx[], sellIdx[];
   int sCount = 0, bCount = 0, selCount = 0;

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_zones[i].direction == "buy"  && !InpAllowLong)  continue;
      if(g_zones[i].direction == "sell" && !InpAllowShort) continue;
      if(g_zones[i].strength == "strong")
        { ArrayResize(strongIdx, sCount   + 1); strongIdx[sCount++]    = i; }
      else if(g_zones[i].direction == "buy")
        { ArrayResize(buyIdx,    bCount   + 1); buyIdx[bCount++]       = i; }
      else
        { ArrayResize(sellIdx,   selCount + 1); sellIdx[selCount++]    = i; }
     }

   //--- Sort regular groups by distance ascending
   for(int i = 0; i < bCount - 1; i++)
      for(int j = 0; j < bCount - 1 - i; j++)
         if(MathAbs(g_zones[buyIdx[j]].entryPrice   - mid) >
            MathAbs(g_zones[buyIdx[j+1]].entryPrice - mid))
           { int t = buyIdx[j]; buyIdx[j] = buyIdx[j+1]; buyIdx[j+1] = t; }

   for(int i = 0; i < selCount - 1; i++)
      for(int j = 0; j < selCount - 1 - i; j++)
         if(MathAbs(g_zones[sellIdx[j]].entryPrice   - mid) >
            MathAbs(g_zones[sellIdx[j+1]].entryPrice - mid))
           { int t = sellIdx[j]; sellIdx[j] = sellIdx[j+1]; sellIdx[j+1] = t; }

   //--- Build ordered list with weights: strong=1.0, regular decreasing by 0.1 per rank
   int    ordered[]; double weights[]; int oCount = 0;

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
        { ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
          ordered[oCount] = buyIdx[rank]; weights[oCount] = w; oCount++; }
      if(rank < selCount)
        { ArrayResize(ordered, oCount+1); ArrayResize(weights, oCount+1);
          ordered[oCount] = sellIdx[rank]; weights[oCount] = w; oCount++; }
     }

   if(oCount == 0) { Print("ZoneTrader 2A: No qualifying zones"); g_ordersPlaced = true; return; }
   if(oCount > InpMaxPositions) oCount = InpMaxPositions;

   while(oCount > 0 && minRiskPerPos * oCount > InpMaxDailyRisk)
     { Print("ZoneTrader 2A: Dropping lowest-priority zone (budget)"); oCount--; }

   if(oCount == 0) { Print("ZoneTrader 2A: Budget too small"); g_ordersPlaced = true; return; }

   double weightSum = 0.0;
   for(int q = 0; q < oCount; q++) weightSum += weights[q];

   Print("ZoneTrader 2A: SL=", ActiveSLPips(), "p  TP=", InpTPPips,
         "p  Zones=", oCount, "  Budget=$", InpMaxDailyRisk);

   for(int q = 0; q < oCount; q++)
     {
      double share = (weights[q] / weightSum) * InpMaxDailyRisk;
      PlaceLimitOrder(ordered[q], slDist, share);
     }

   g_ordersPlaced = true;
   Print("ZoneTrader 2A: Placement done. Risk committed: $", g_dailyRiskUsed);
  }

//+------------------------------------------------------------------+
//| Place a single limit order                                        |
//+------------------------------------------------------------------+
void PlaceLimitOrder(const int idx, const double slDist, const double budget)
  {
   Zone   z   = g_zones[idx];
   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
   double entry = NormalizeDouble(z.entryPrice, _Digits);

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
      Print("ZoneTrader 2A: OrderSend failed zone ", idx, " retcode=", res.retcode);
   else
     {
      double risk = CalcRiskForLots(lots, slDist);
      g_dailyRiskUsed += risk;
      Print("ZoneTrader 2A: [", z.strength, "] ", z.direction, " LIMIT #", res.order,
            "  entry=", entry, "  sl=", sl, "  tp=", tp,
            "  lots=", lots, "  risk=$", risk);
     }
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

void AddTrackEntry(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   ArrayResize(g_tracking, g_trackCount + 1);
   int i = g_trackCount;
   g_tracking[i].ticket     = ticket;
   g_tracking[i].direction  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
   g_tracking[i].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   g_tracking[i].slDistance = MathAbs(g_tracking[i].entryPrice - PositionGetDouble(POSITION_SL));
   g_tracking[i].openTime   = (datetime)PositionGetInteger(POSITION_TIME);
   g_tracking[i].isOpen     = true;
   g_tracking[i].closedBy   = "";
   g_trackCount++;
   Print("ZoneTrader 2A: Tracking #", ticket,
         " dir=", g_tracking[i].direction,
         " open=", TimeToString(g_tracking[i].openTime, TIME_DATE|TIME_SECONDS));
  }

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
//| Risk / lot calculations                                           |
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
//| Session helpers                                                   |
//+------------------------------------------------------------------+
bool IsAfterNYOpen(const MqlDateTime &dt)
  {
   return (dt.hour > InpNYOpenHour ||
          (dt.hour == InpNYOpenHour && dt.min >= InpNYOpenMinute));
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
