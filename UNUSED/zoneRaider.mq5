//+------------------------------------------------------------------+
//| ZoneTrader.mq5                                                   |
//| Places limit orders on zones from local server                   |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"
#property strict

//--- Inputs
input string   InpServerURL      = "http://127.0.0.1:3000"; // Server URL
input string   InpSymbolName    = "";                          // Symbol name for URL (blank = use chart symbol)
input bool     InpAllowLong      = true;                     // Allow buy entries
input bool     InpAllowShort     = true;                     // Allow sell entries
input int      InpATRPeriod      = 24;                       // ATR period
input double   InpMaxDailyRisk   = 100.0;                    // Total daily risk budget ($)
input int      InpMaxPositions   = 6;                        // Max simultaneous positions
input int      InpPollMinutes    = 10;                       // Poll interval (minutes)
input int      InpNYOpenHour     = 13;                       // NY open hour (UTC)
input int      InpNYOpenMinute   = 30;                       // NY open minute (UTC)
input int      InpEODHour        = 21;                       // Hour to close all and reset (UTC)
input bool     InpSkipWeekends   = true;                       // Skip polling on weekends
input int      InpEntryBuffer    = 1;                          // Entry buffer (pips above buy / below sell)

//--- Zone structure
struct Zone
  {
   string   id;
   string   direction;   // "buy" | "sell"
   string   strength;    // "strong" | "regular"
   string   kind;        // "point" | "zone"
   double   price;       // kind=point
   double   priceFrom;   // kind=zone
   double   priceTo;     // kind=zone
   double   entryPrice;  // computed: where the limit order sits
   double   zoneLow;     // computed
   double   zoneHigh;    // computed
  };

//--- Globals
Zone     g_zones[];
int      g_zoneCount     = 0;
bool     g_zonesLoaded   = false;
bool     g_ordersPlaced  = false;
datetime g_lastPoll      = 0;
int      g_atrHandle     = INVALID_HANDLE;
double   g_dailyRiskUsed = 0.0;
long     g_magic         = 20260301;

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_atrHandle = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("ZoneTrader: Failed to create ATR handle");
      return INIT_FAILED;
     }

   EventSetTimer(60);
   g_dailyRiskUsed = 0.0;
   Print("ZoneTrader: Initialized on ", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
  }

//+------------------------------------------------------------------+
//| Timer                                                             |
//+------------------------------------------------------------------+
void OnTimer()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);

   //--- Skip on weekends if configured (day_of_week: 0=Sun, 6=Sat)
   if(InpSkipWeekends && (dt.day_of_week == 0 || dt.day_of_week == 6))
      return;

   //--- EOD: close everything and reset for next session
   if(dt.hour >= InpEODHour)
     {
      CloseAndReset();
      return;
     }

   //--- Orders already placed — nothing more to do until EOD
   if(g_ordersPlaced)
      return;

   //--- NY open reached without zones — abort today
   if(IsAfterNYOpen(dt) && !g_zonesLoaded)
     {
      Print("ZoneTrader: NY open reached with no zones — done for today");
      g_zonesLoaded  = true;
      g_ordersPlaced = true;
      return;
     }

   //--- Respect poll interval
   if(TimeCurrent() - g_lastPoll < InpPollMinutes * 60)
      return;

   PollServer();
  }

//+------------------------------------------------------------------+
//| OnTick — pending orders managed natively by MT5                  |
//+------------------------------------------------------------------+
void OnTick() { }

//+------------------------------------------------------------------+
//| Poll server                                                       |
//+------------------------------------------------------------------+
void PollServer()
  {
   g_lastPoll = TimeCurrent();

   string sym = (InpSymbolName != "") ? InpSymbolName : _Symbol;
   string url     = InpServerURL + "/" + sym;
   string headers = "Content-Type: application/json\r\n";
   char   post[], result[];
   string responseHeaders;

   Print("ZoneTrader: Polling ", url);

   int res = WebRequest("GET", url, headers, 5000, post, result, responseHeaders);
   if(res != 200)
     {
      Print("ZoneTrader: Poll failed — HTTP ", res,
            " (whitelist URL in Tools > Options > Expert Advisors)");
      return;
     }

   string json = CharArrayToString(result);
   ParseZones(json);

   if(g_zonesLoaded && g_zoneCount > 0)
      PlaceAllOrders();
  }

//+------------------------------------------------------------------+
//| Parse JSON array into g_zones[]                                  |
//+------------------------------------------------------------------+
void ParseZones(const string json)
  {
   g_zoneCount = 0;
   ArrayResize(g_zones, 0);

   if(StringFind(json, "{") < 0)
     {
      Print("ZoneTrader: Empty zone list");
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

      string obj = StringSubstr(json, objStart, objEnd - objStart);
      Zone z;
      if(ParseZoneObject(obj, z))
        {
         ArrayResize(g_zones, g_zoneCount + 1);
         g_zones[g_zoneCount] = z;
         g_zoneCount++;
        }
      pos = objEnd;
     }

   if(g_zoneCount > 0)
     {
      SortZonesByPrice();
      g_zonesLoaded = true;
      Print("ZoneTrader: Loaded and sorted ", g_zoneCount, " zone(s)");
     }
  }

//+------------------------------------------------------------------+
//| Parse a single JSON object into Zone struct                       |
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

   double pip = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10 * InpEntryBuffer;

   if(z.kind == "point")
     {
      if(z.price == 0.0) return false;
      z.zoneLow    = z.price;
      z.zoneHigh   = z.price;
      // Buy limit N pips above the point, sell limit N pips below
      z.entryPrice = (z.direction == "buy")
                      ? NormalizeDouble(z.price + pip, _Digits)
                      : NormalizeDouble(z.price - pip, _Digits);
     }
   else
     {
      if(z.priceFrom == 0.0 || z.priceTo == 0.0) return false;
      z.zoneLow  = MathMin(z.priceFrom, z.priceTo);
      z.zoneHigh = MathMax(z.priceFrom, z.priceTo);
      // Buy limit N pips above zone ceiling, sell limit N pips below zone floor
      z.entryPrice = (z.direction == "buy")
                      ? NormalizeDouble(z.zoneHigh + pip, _Digits)
                      : NormalizeDouble(z.zoneLow  - pip, _Digits);
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Sort zones by entryPrice ascending                               |
//+------------------------------------------------------------------+
void SortZonesByPrice()
  {
   for(int i = 0; i < g_zoneCount - 1; i++)
      for(int j = 0; j < g_zoneCount - 1 - i; j++)
         if(g_zones[j].entryPrice > g_zones[j+1].entryPrice)
           {
            Zone tmp     = g_zones[j];
            g_zones[j]   = g_zones[j+1];
            g_zones[j+1] = tmp;
           }
  }

//+------------------------------------------------------------------+
//| Place all limit orders                                           |
//|                                                                  |
//| Weights:                                                         |
//|   Strong zones  = 1.0 (fixed)                                   |
//|   Regular zones = 1.0 - 0.1*rank (closest=0.9, next=0.8, ...)  |
//|   Rank is per-direction: closest buy rank 0, closest sell rank 0 |
//|                                                                  |
//| Priority if budget is tight:                                     |
//|   1. All strong zones                                            |
//|   2. Closest buy + closest sell                                  |
//|   3. Second closest buy + second closest sell                    |
//|   4. ... and so on, dropping furthest first                      |
//+------------------------------------------------------------------+
void PlaceAllOrders()
  {
   double atr = GetATR();
   if(atr <= 0.0)
     {
      Print("ZoneTrader: Invalid ATR — cannot place orders");
      return;
     }

   double minRiskPerPos = CalcMinRiskPerPosition(atr);
   if(minRiskPerPos <= 0.0)
     {
      Print("ZoneTrader: Cannot calculate minimum risk per position");
      return;
     }

   double mid = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) +
                 SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;

   //--- Separate strong and regular zones, each direction sorted by distance asc
   int strongIdx[], buyIdx[], sellIdx[];
   int sCount = 0, bCount = 0, selCount = 0;

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_zones[i].direction == "buy"  && !InpAllowLong)  continue;
      if(g_zones[i].direction == "sell" && !InpAllowShort) continue;

      if(g_zones[i].strength == "strong")
        {
         ArrayResize(strongIdx, sCount + 1);
         strongIdx[sCount++] = i;
        }
      else
        {
         if(g_zones[i].direction == "buy")
           { ArrayResize(buyIdx,  bCount   + 1); buyIdx[bCount++]    = i; }
         else
           { ArrayResize(sellIdx, selCount + 1); sellIdx[selCount++] = i; }
        }
     }

   //--- Sort each regular group by distance to mid ascending
   for(int i = 0; i < bCount - 1; i++)
      for(int j = 0; j < bCount - 1 - i; j++)
         if(MathAbs(g_zones[buyIdx[j]].entryPrice  - mid) >
            MathAbs(g_zones[buyIdx[j+1]].entryPrice - mid))
           { int t = buyIdx[j]; buyIdx[j] = buyIdx[j+1]; buyIdx[j+1] = t; }

   for(int i = 0; i < selCount - 1; i++)
      for(int j = 0; j < selCount - 1 - i; j++)
         if(MathAbs(g_zones[sellIdx[j]].entryPrice  - mid) >
            MathAbs(g_zones[sellIdx[j+1]].entryPrice - mid))
           { int t = sellIdx[j]; sellIdx[j] = sellIdx[j+1]; sellIdx[j+1] = t; }

   //--- Build priority-ordered list:
   //    All strongs first, then interleave buy/sell by rank (closest pair first)
   int    ordered[];
   double weights[];
   int    oCount = 0;

   // Strong zones — weight 1.0
   for(int i = 0; i < sCount; i++)
     {
      ArrayResize(ordered,  oCount + 1);
      ArrayResize(weights,  oCount + 1);
      ordered[oCount]  = strongIdx[i];
      weights[oCount]  = 1.0;
      oCount++;
     }

   // Interleave regular buy/sell by rank — weight 1.0 - 0.1*(rank+1)
   // rank 0 (closest) → 0.9, rank 1 → 0.8, ...  floor at 0.1
   int maxRank = (bCount > selCount) ? bCount : selCount;
   for(int rank = 0; rank < maxRank; rank++)
     {
      double w = MathMax(0.1, 1.0 - 0.1 * (rank + 1));
      if(rank < bCount)
        {
         ArrayResize(ordered, oCount + 1);
         ArrayResize(weights, oCount + 1);
         ordered[oCount] = buyIdx[rank];
         weights[oCount] = w;
         oCount++;
        }
      if(rank < selCount)
        {
         ArrayResize(ordered, oCount + 1);
         ArrayResize(weights, oCount + 1);
         ordered[oCount] = sellIdx[rank];
         weights[oCount] = w;
         oCount++;
        }
     }

   if(oCount == 0)
     {
      Print("ZoneTrader: No qualifying zones");
      g_ordersPlaced = true;
      return;
     }

   //--- Cap by MaxPositions (priority order already correct — just truncate tail)
   if(oCount > InpMaxPositions)
      oCount = InpMaxPositions;

   //--- Trim tail (furthest/lowest priority) until budget covers remaining at min lot
   while(oCount > 0 && minRiskPerPos * oCount > InpMaxDailyRisk)
     {
      Print("ZoneTrader: Budget tight — dropping lowest-priority zone (idx ",
            ordered[oCount - 1], ")");
      oCount--;
     }

   if(oCount == 0)
     {
      Print("ZoneTrader: Budget too small for even 1 position at minimum lot");
      g_ordersPlaced = true;
      return;
     }

   //--- Distribute budget proportionally by weight
   double weightSum = 0.0;
   for(int q = 0; q < oCount; q++) weightSum += weights[q];

   Print("ZoneTrader: ATR=", atr, "  Zones=", oCount,
         "  Budget=$", InpMaxDailyRisk);

   for(int q = 0; q < oCount; q++)
     {
      double share = (weights[q] / weightSum) * InpMaxDailyRisk;
      Print("ZoneTrader: Zone ", ordered[q], " [", g_zones[ordered[q]].strength,
            " ", g_zones[ordered[q]].direction, "] weight=", weights[q],
            " share=$", share);
      PlaceLimitOrder(ordered[q], atr, share);
     }

   g_ordersPlaced = true;
   Print("ZoneTrader: Done. Total risk committed: $", g_dailyRiskUsed);
  }

//+------------------------------------------------------------------+
//| Place a single limit order for zone[idx]                         |
//+------------------------------------------------------------------+
void PlaceLimitOrder(const int idx, const double atr, const double budgetPerZone)
  {
   Zone z = g_zones[idx];

   double entry  = NormalizeDouble(z.entryPrice, _Digits);
   double sl     = 0.0;
   double slDist = 0.0;

   if(z.direction == "buy")
     {
      // SL 1*ATR below the zone floor
      sl     = NormalizeDouble(z.zoneLow - atr, _Digits);
      slDist = entry - sl;
     }
   else
     {
      // SL 1*ATR above the zone ceiling
      sl     = NormalizeDouble(z.zoneHigh + atr, _Digits);
      slDist = sl - entry;
     }

   if(slDist <= 0.0)
     {
      Print("ZoneTrader: Invalid SL distance for zone ", idx, " — skipping");
      return;
     }

   double tp = FindTP(idx, atr, entry, slDist);
   if(tp <= 0.0)
     {
      Print("ZoneTrader: Could not determine TP for zone ", idx, " — skipping");
      return;
     }

   double lots = CalcLots(slDist, budgetPerZone);

   // Expiry at EOD hour today (UTC)
   MqlDateTime expDt;
   TimeToStruct(TimeGMT(), expDt);
   expDt.hour = InpEODHour;
   expDt.min  = 0;
   expDt.sec  = 0;
   datetime expiry = StructToTime(expDt);

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = _Symbol;
   req.volume       = lots;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.expiration   = expiry;
   req.type_time    = ORDER_TIME_SPECIFIED;
   req.magic        = g_magic;
   req.comment      = "ZT_" + z.strength + "_" + z.direction;
   req.type_filling = ORDER_FILLING_RETURN;
   req.type         = (z.direction == "buy") ? ORDER_TYPE_BUY_LIMIT
                                              : ORDER_TYPE_SELL_LIMIT;

   if(!OrderSend(req, res))
     {
      Print("ZoneTrader: OrderSend failed zone ", idx,
            " retcode=", res.retcode, " ", res.comment);
     }
   else
     {
      double riskForThis = CalcRiskForLots(lots, slDist);
      g_dailyRiskUsed += riskForThis;
      Print("ZoneTrader: [", z.strength, "] ", z.direction, " LIMIT #", res.order,
            "  entry=", entry, "  sl=", sl, "  tp=", tp,
            "  lots=", lots, "  risk=$", riskForThis);
     }
  }

//+------------------------------------------------------------------+
//| Find TP: nearest opposite zone minus 0.3*ATR, minimum 1:1        |
//+------------------------------------------------------------------+
double FindTP(const int idx, const double atr,
              const double entry, const double slDist)
  {
   Zone z = g_zones[idx];
   string   oppDir = (z.direction == "buy") ? "sell" : "buy";
   double   bestTP = 0.0;
   double   minDist = DBL_MAX;

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(i == idx) continue;
      if(g_zones[i].direction != oppDir) continue;

      if(z.direction == "buy")
        {
         // Look for sell zones above entry
         // Use the low of the sell zone as the target (price approaches from below)
         double oppLevel = (g_zones[i].kind == "point")
                            ? g_zones[i].price
                            : g_zones[i].zoneLow;
         if(oppLevel <= entry) continue;
         double dist = oppLevel - entry;
         if(dist < minDist)
           {
            minDist = dist;
            bestTP  = NormalizeDouble(oppLevel - 0.3 * atr, _Digits);
           }
        }
      else
        {
         // Look for buy zones below entry
         // Use the high of the buy zone as the target (price approaches from above)
         double oppLevel = (g_zones[i].kind == "point")
                            ? g_zones[i].price
                            : g_zones[i].zoneHigh;
         if(oppLevel >= entry) continue;
         double dist = entry - oppLevel;
         if(dist < minDist)
           {
            minDist = dist;
            bestTP  = NormalizeDouble(oppLevel + 0.3 * atr, _Digits);
           }
        }
     }

   // Enforce 1:1 minimum
   if(bestTP > 0.0)
     {
      double tpDist = MathAbs(bestTP - entry);
      if(tpDist < slDist)
        {
         Print("ZoneTrader: TP below 1:1 — adjusting");
         bestTP = (z.direction == "buy")
                   ? NormalizeDouble(entry + slDist, _Digits)
                   : NormalizeDouble(entry - slDist, _Digits);
        }
     }
   else
     {
      // No opposite zone found — use 1:1
      Print("ZoneTrader: No opposite zone found — defaulting to 1:1 TP");
      bestTP = (z.direction == "buy")
                ? NormalizeDouble(entry + slDist, _Digits)
                : NormalizeDouble(entry - slDist, _Digits);
     }

   return bestTP;
  }

//+------------------------------------------------------------------+
//| Minimum $ risk at 0.01 lot for a 1*ATR stop                      |
//+------------------------------------------------------------------+
double CalcMinRiskPerPosition(const double atr)
  {
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(tickSize == 0.0 || tickVal == 0.0) return 0.0;
   double slTicks = atr / tickSize;
   return slTicks * tickVal * lotMin;
  }

//+------------------------------------------------------------------+
//| $ risk for a given lot size and SL distance                      |
//+------------------------------------------------------------------+
double CalcRiskForLots(const double lots, const double slDist)
  {
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0.0 || tickVal == 0.0) return 0.0;
   return (slDist / tickSize) * tickVal * lots;
  }

//+------------------------------------------------------------------+
//| Lot size: use as much of remaining budget as possible, min 0.01  |
//+------------------------------------------------------------------+
double CalcLots(const double slDist, const double budget)
  {
   double lotMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMax   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize == 0.0 || tickVal == 0.0) return lotMin;

   double riskPerLot = (slDist / tickSize) * tickVal; // $ risk per 1.0 lot
   if(riskPerLot <= 0.0) return lotMin;

   // Use the per-zone budget slice, not cumulative remaining
   double lots = MathFloor((budget / riskPerLot) / lotStep) * lotStep;
   lots = MathMax(lotMin, MathMin(lotMax, lots));
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
//| Close all positions + delete pending orders, reset state         |
//+------------------------------------------------------------------+
void CloseAndReset()
  {
   // Remove pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol)  continue;
      if(OrderGetInteger(ORDER_MAGIC)  != g_magic)   continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action = TRADE_ACTION_REMOVE;
      req.order  = ticket;
      if(!OrderSend(req, res))
         Print("ZoneTrader: Remove order failed #", ticket, " code=", res.retcode);
     }

   // Close open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != g_magic)  continue;

      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = PositionGetDouble(POSITION_VOLUME);
      req.magic        = g_magic;
      req.type_filling = ORDER_FILLING_RETURN;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
         req.type  = ORDER_TYPE_SELL;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
      else
        {
         req.type  = ORDER_TYPE_BUY;
         req.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }

      if(!OrderSend(req, res))
         Print("ZoneTrader: Close failed #", ticket, " code=", res.retcode);
      else
         Print("ZoneTrader: EOD closed #", ticket);
     }

   // Reset session state
   g_zoneCount      = 0;
   g_zonesLoaded    = false;
   g_ordersPlaced   = false;
   g_dailyRiskUsed  = 0.0;
   g_lastPoll       = 0;
   ArrayResize(g_zones, 0);
   Print("ZoneTrader: Session reset complete");
  }

//+------------------------------------------------------------------+
//| Count pending orders + open positions (this symbol + magic)      |
//+------------------------------------------------------------------+
int CountPendingAndOpen()
  {
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != g_magic)  continue;
      count++;
     }
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)  continue;
      count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Latest ATR value                                                  |
//+------------------------------------------------------------------+
double GetATR()
  {
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) <= 0) return 0.0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| NY open check (UTC)                                               |
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
   int kPos = StringFind(obj, "\"" + key + "\"");
   if(kPos < 0) return "";
   int colon = StringFind(obj, ":", kPos);
   if(colon < 0) return "";
   int q1 = StringFind(obj, "\"", colon + 1);
   if(q1 < 0) return "";
   int q2 = StringFind(obj, "\"", q1 + 1);
   if(q2 < 0) return "";
   return StringSubstr(obj, q1 + 1, q2 - q1 - 1);
  }

double JsonGetDouble(const string obj, const string key)
  {
   int kPos = StringFind(obj, "\"" + key + "\"");
   if(kPos < 0) return 0.0;
   int colon = StringFind(obj, ":", kPos);
   if(colon < 0) return 0.0;
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
