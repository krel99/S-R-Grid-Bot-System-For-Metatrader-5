//+------------------------------------------------------------------+
//| ZoneAlerts.mq5                                                   |
//| Polls two endpoints and sends MT5 push notifications on touch.   |
//|                                                                  |
//| /{symbol}         — zone levels (buy/sell, strength)             |
//|   • Nearest boundary: zoneHigh for buy, zoneLow for sell         |
//|   • Silent at/after InpEODHourUTC (21:00 UTC)                   |
//|                                                                  |
//| /options/{symbol} — FX option strikes (above/below)              |
//|   • "above" alerts when ask >= strike                            |
//|   • "below" alerts when bid <= strike                            |
//|   • Silent at/after InpOptCutoffUTC (14:00 UTC = 16:00 CEST)    |
//|   • Today's date only                                            |
//|                                                                  |
//| Both: max 2 alerts per zone lifetime, 60-min cooldown between.  |
//| All state resets at midnight UTC.                                |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.01"
#property strict

//--- Inputs
input string InpServerURL    = "http://37.46.211.146:3000"; // Server URL
input string InpSymbolName   = "";                           // Symbol override (blank = chart)
input int    InpPollMinutes  = 10;                           // Poll interval (minutes)
input int    InpEODHourUTC   = 21;                           // Zone alerts stop at this UTC hour
input int    InpOptCutoffUTC = 14;                           // Options alerts stop at this UTC hour (14 = 16:00 CEST)

//--- Supported base symbols — broker suffix is stripped automatically
string g_bases[] = {"EURUSD","GBPUSD","USDJPY","EURGBP","AUDUSD","AUDNZD","EURJPY","USDCAD","XAUUSD"};

//--- Alert record — shared by both endpoint types
struct AlertZone
  {
   string   id;
   string   source;      // "zone" | "option"
   string   label;       // shown in notification
   double   touchLevel;  // exact price to watch
   bool     touchAbove;  // true = alert when ask >= level; false = alert when bid <= level
   int      alertCount;  // increments on each alert; capped at 2
   datetime lastAlert;   // 0 = never alerted
  };

//--- Globals
AlertZone g_zones[];
int       g_zoneCount = 0;
string    g_symbol    = "";   // full broker symbol e.g. GBPUSD_stp
string    g_base      = "";   // stripped base e.g. GBPUSD
datetime  g_lastPoll  = 0;
int       g_lastDay   = -1;

//+------------------------------------------------------------------+
//| Strip broker suffix, return base symbol or "" if unsupported     |
//+------------------------------------------------------------------+
string ResolveBase(const string sym)
  {
   string up = sym;
   StringToUpper(up);
   for(int i = 0; i < ArraySize(g_bases); i++)
      if(StringFind(up, g_bases[i]) == 0) return g_bases[i];
   return "";
  }

//+------------------------------------------------------------------+
//| JSON helpers                                                      |
//+------------------------------------------------------------------+
string JsonGetString(const string obj, const string key)
  {
   int kp = StringFind(obj, "\"" + key + "\""); if(kp < 0) return "";
   int co = StringFind(obj, ":", kp);            if(co < 0) return "";
   int q1 = StringFind(obj, "\"", co + 1);       if(q1 < 0) return "";
   int q2 = StringFind(obj, "\"", q1 + 1);       if(q2 < 0) return "";
   return StringSubstr(obj, q1 + 1, q2 - q1 - 1);
  }

double JsonGetDouble(const string obj, const string key)
  {
   int kp = StringFind(obj, "\"" + key + "\""); if(kp < 0) return 0.0;
   int co = StringFind(obj, ":", kp);            if(co < 0) return 0.0;
   int vs = co + 1, n = StringLen(obj);
   while(vs < n && StringGetCharacter(obj, vs) == ' ') vs++;
   int ve = vs;
   while(ve < n)
     {
      ushort c = StringGetCharacter(obj, ve);
      if(c == ',' || c == '}' || c == ' ' || c == '\n' || c == '\r') break;
      ve++;
     }
   return StringToDouble(StringSubstr(obj, vs, ve - vs));
  }

int SplitJsonArray(const string body, string &out[])
  {
   ArrayResize(out, 0);
   int cnt = 0, n = StringLen(body), i = 0;
   while(i < n && StringGetCharacter(body, i) != '[') i++;
   if(i >= n) return 0;
   i++;
   while(i < n)
     {
      while(i < n && StringGetCharacter(body, i) != '{') i++;
      if(i >= n) break;
      int depth = 0, start = i;
      bool inStr = false, esc = false;
      for(; i < n; i++)
        {
         ushort c = StringGetCharacter(body, i);
         if(inStr) { if(esc){esc=false;continue;} if(c=='\\'){esc=true;continue;} if(c=='"') inStr=false; continue; }
         if(c == '"') { inStr = true; continue; }
         if(c == '{') depth++;
         else if(c == '}') { if(--depth == 0) { i++; break; } }
        }
      ArrayResize(out, cnt + 1);
      out[cnt++] = StringSubstr(body, start, i - start);
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Restore alert state from previous poll                           |
//+------------------------------------------------------------------+
void RestoreState(AlertZone &z, const AlertZone &prev[], const int prevCount)
  {
   for(int j = 0; j < prevCount; j++)
      if(prev[j].id == z.id && prev[j].source == z.source)
        { z.alertCount = prev[j].alertCount; z.lastAlert = prev[j].lastAlert; return; }
  }

//+------------------------------------------------------------------+
//| HTTP GET                                                          |
//+------------------------------------------------------------------+
string HttpGet(const string url)
  {
   char post[], resp[];
   string hdrs;
   ArrayResize(post, 0);
   int code = WebRequest("GET", url, "", 5000, post, resp, hdrs);
   if(code != 200)
     {
      PrintFormat("[ZoneAlerts] GET %s failed HTTP=%d err=%d (whitelist URL in MT5 settings)",
                  url, code, GetLastError());
      return "";
     }
   return CharArrayToString(resp);
  }

string TodayUTC()
  {
   MqlDateTime d;
   TimeToStruct(TimeGMT(), d);
   return StringFormat("%04d-%02d-%02d", d.year, d.mon, d.day);
  }

//+------------------------------------------------------------------+
//| Poll /{base} — zone levels                                       |
//+------------------------------------------------------------------+
void PollZones(AlertZone &prev[], const int prevCount)
  {
   string body = HttpGet(InpServerURL + "/" + g_base);
   if(body == "") return;

   string elems[];
   int n = SplitJsonArray(body, elems);
   int loaded = 0;

   for(int i = 0; i < n; i++)
     {
      string obj  = elems[i];
      string id   = JsonGetString(obj, "id");
      string dir  = JsonGetString(obj, "direction");
      string str  = JsonGetString(obj, "strength");
      string kind = JsonGetString(obj, "kind");

      if(id == "" || (dir != "buy" && dir != "sell")) continue;

      double touchLevel = 0.0;
      bool   touchAbove = false;

      if(kind == "point")
        {
         touchLevel = JsonGetDouble(obj, "price");
         touchAbove = (dir == "sell");
        }
      else
        {
         double from = JsonGetDouble(obj, "from");
         double to   = JsonGetDouble(obj, "to");
         if(from <= 0.0 || to <= 0.0) continue;
         if(dir == "buy")
           { touchLevel = MathMax(from, to); touchAbove = false; }
         else
           { touchLevel = MathMin(from, to); touchAbove = true; }
        }

      if(touchLevel <= 0.0) continue;

      AlertZone z;
      z.id         = id;
      z.source     = "zone";
      z.label      = StringFormat("%s %s %s @ %.5f",
                                  g_base,
                                  dir == "buy" ? "BUY" : "SELL",
                                  str,
                                  touchLevel);
      z.touchLevel = touchLevel;
      z.touchAbove = touchAbove;
      z.alertCount = 0;
      z.lastAlert  = 0;
      RestoreState(z, prev, prevCount);

      ArrayResize(g_zones, g_zoneCount + 1);
      g_zones[g_zoneCount++] = z;
      loaded++;
     }

   PrintFormat("[ZoneAlerts] %d zone level(s) loaded", loaded);
  }

//+------------------------------------------------------------------+
//| Poll /options/{base} — option strikes                            |
//+------------------------------------------------------------------+
void PollOptions(AlertZone &prev[], const int prevCount)
  {
   string body = HttpGet(InpServerURL + "/options/" + g_base);
   if(body == "") return;

   string today = TodayUTC();
   string elems[];
   int n = SplitJsonArray(body, elems);
   int loaded = 0;

   for(int i = 0; i < n; i++)
     {
      string obj  = elems[i];
      string id   = JsonGetString(obj, "id");
      string dir  = JsonGetString(obj, "direction");
      string date = JsonGetString(obj, "date");
      string time = JsonGetString(obj, "time");
      double px   = JsonGetDouble(obj, "price");

      if(id == "" || (dir != "above" && dir != "below")) continue;
      if(date != today || px <= 0.0) continue;
      if(time == "") time = "16:00";

      AlertZone z;
      z.id         = id;
      z.source     = "option";
      z.label      = StringFormat("%s OPTION %s @ %.5f exp %s",
                                  g_base,
                                  dir == "above" ? "ABOVE" : "BELOW",
                                  px,
                                  time);
      z.touchLevel = px;
      z.touchAbove = (dir == "above");
      z.alertCount = 0;
      z.lastAlert  = 0;
      RestoreState(z, prev, prevCount);

      ArrayResize(g_zones, g_zoneCount + 1);
      g_zones[g_zoneCount++] = z;
      loaded++;
     }

   PrintFormat("[ZoneAlerts] %d option strike(s) loaded", loaded);
  }

//+------------------------------------------------------------------+
//| Poll both endpoints                                              |
//+------------------------------------------------------------------+
void PollAll()
  {
   g_lastPoll = TimeCurrent();

   int       prevCount = g_zoneCount;
   AlertZone prev[];
   ArrayResize(prev, prevCount);
   for(int i = 0; i < prevCount; i++) prev[i] = g_zones[i];

   ArrayResize(g_zones, 0);
   g_zoneCount = 0;

   PollZones(prev, prevCount);
   PollOptions(prev, prevCount);
  }

//+------------------------------------------------------------------+
//| Check all zones against current price                            |
//+------------------------------------------------------------------+
void CheckZones()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int utcHour = dt.hour;

   double   bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double   ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   datetime now = TimeCurrent();

   for(int i = 0; i < g_zoneCount; i++)
     {
      if(g_zones[i].source == "zone"   && utcHour >= InpEODHourUTC)   continue;
      if(g_zones[i].source == "option" && utcHour >= InpOptCutoffUTC)  continue;
      if(g_zones[i].alertCount >= 2) continue;
      if(g_zones[i].lastAlert > 0 && now - g_zones[i].lastAlert < 3600) continue;

      bool hit = g_zones[i].touchAbove ? (ask >= g_zones[i].touchLevel)
                                       : (bid <= g_zones[i].touchLevel);
      if(!hit) continue;

      SendNotification(g_zones[i].label);
      Print("[ZoneAlerts] ALERT #", g_zones[i].alertCount + 1, " — ", g_zones[i].label);

      g_zones[i].alertCount++;
      g_zones[i].lastAlert = now;
     }
  }

//+------------------------------------------------------------------+
//| Daily reset                                                      |
//+------------------------------------------------------------------+
void DailyReset(const int day)
  {
   g_lastDay   = day;
   g_zoneCount = 0;
   ArrayResize(g_zones, 0);
   g_lastPoll  = 0;
   Print("[ZoneAlerts] Daily reset");
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   string sym = (InpSymbolName != "") ? InpSymbolName : _Symbol;
   g_base = ResolveBase(sym);
   if(g_base == "")
     {
      PrintFormat("[ZoneAlerts] Symbol %s not in supported list. EA disabled.", sym);
      return INIT_FAILED;
     }
   g_symbol = sym;

   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   g_lastDay = dt.day_of_year;

   EventSetTimer(30);
   PollAll();

   PrintFormat("[ZoneAlerts] Ready — chart=%s base=%s  zone EOD=%d:00 UTC  options cutoff=%d:00 UTC",
               g_symbol, g_base, InpEODHourUTC, InpOptCutoffUTC);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.day_of_year != g_lastDay) DailyReset(dt.day_of_year);
   if(TimeCurrent() - g_lastPoll >= (datetime)(InpPollMinutes * 60)) PollAll();
   CheckZones();
  }

void OnTick()
  {
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   if(dt.day_of_year != g_lastDay) DailyReset(dt.day_of_year);
   CheckZones();
  }
//+------------------------------------------------------------------+
