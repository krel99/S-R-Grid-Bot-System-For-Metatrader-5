//+------------------------------------------------------------------+
//| ZoneAlerts.mq5                                                   |
//|                                                                  |
//| Loads levels from two endpoints, fires SendNotification() once   |
//| per candle when the candle crosses a level.                      |
//|                                                                  |
//| POLLING: pulls the server until at least one level (zone OR      |
//| option) is loaded, then STOPS for the rest of the UTC day. If a  |
//| poll returns nothing, it retries every InpPollMins. DailyReset   |
//| re-arms polling at the UTC midnight rollover.                    |
//|                                                                  |
//| Cross logic (checked on every tick using current candle OHLC):   |
//|   Resistance / option "below" -> alert when candle crosses UP    |
//|     condition: Open < level AND High > level                     |
//|   Support    / option "above" -> alert when candle crosses DOWN  |
//|     condition: Open > level AND Low  < level                     |
//|   NWOG -> BOTH directions: fires on UP cross at low edge AND     |
//|     DOWN cross at high edge. Source="nwog", no time cutoff,      |
//|     valid until end of trading week.                             |
//|                                                                  |
//| Once the alert fires for a candle, it won't repeat for the same  |
//| candle -- but it resets on the next candle.                      |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "4.50"
#property strict

input string InpServerURL      = "http://37.46.211.146:3000"; // Server URL
input string InpSymbolName     = "";     // Symbol override (blank = chart symbol)
input int    InpPollMins       = 5;      // RETRY interval (mins) until zones load; polling halts once loaded
input int    InpZoneEndUTC     = 19;     // Zone alerts end hour UTC (19 = 21:00 CEST)
input int    InpOptEndUTC      = 14;     // Option alerts end hour UTC (14 = 16:00 CEST)
input bool   InpVerbose        = false;  // Enable detailed Experts log
input bool   InpAlertEnabled   = false;  // Enable in-app Alert() popups
input bool   InpTelegramEnabled= true;   // Enable Telegram notifications
input string InpTelegramToken  = "8573876556:AAE6F1YA6hg9FZX10vJNhDnwsh8wayS8tm0"; // Telegram bot token
input string InpTelegramChatID = "768502430"; // Telegram chat_id

string g_bases[] = {"EURUSD","GBPUSD","USDJPY","EURGBP","AUDUSD","AUDNZD","EURJPY","USDCAD","XAUUSD"};

struct Level
  {
   string   id;
   string   source;       // "zone" | "option"
   string   label;        // notification text
   double   price;        // the level
   bool     resistanceUp; // true = alert on cross UP; false = alert on cross DOWN
   bool     primed;       // armed only after price seen on the non-crossing side
   datetime lastAlertBar; // open time of the last candle that fired an alert
  };

Level    g_levels[];
int      g_levelCount = 0;
string   g_symbol     = "";
string   g_base       = "";
datetime g_lastPoll   = 0;
int      g_lastDay    = -1;
bool     g_loaded     = false;   // true once >=1 level loaded; halts further polling until DailyReset

//+------------------------------------------------------------------+
string ResolveBase(const string sym)
  {
   string up = sym; StringToUpper(up);
   for(int i = 0; i < ArraySize(g_bases); i++)
      if(StringFind(up, g_bases[i]) == 0) return g_bases[i];
   return "";
  }

//+------------------------------------------------------------------+
//| JSON helpers                                                      |
//+------------------------------------------------------------------+
string JsonStr(const string obj, const string key)
  {
   int kp = StringFind(obj, "\""+key+"\""); if(kp<0) return "";
   int co = StringFind(obj, ":", kp);       if(co<0) return "";
   int q1 = StringFind(obj, "\"", co+1);    if(q1<0) return "";
   int q2 = StringFind(obj, "\"", q1+1);    if(q2<0) return "";
   return StringSubstr(obj, q1+1, q2-q1-1);
  }

double JsonDbl(const string obj, const string key)
  {
   int kp = StringFind(obj, "\""+key+"\""); if(kp<0) return 0.0;
   int co = StringFind(obj, ":", kp);       if(co<0) return 0.0;
   int vs = co+1, n = StringLen(obj);
   while(vs<n && StringGetCharacter(obj,vs)==' ') vs++;
   int ve = vs;
   while(ve<n) { ushort c=StringGetCharacter(obj,ve); if(c==','||c=='}'||c==' '||c=='\n'||c=='\r') break; ve++; }
   return StringToDouble(StringSubstr(obj, vs, ve-vs));
  }

bool JsonBool(const string obj, const string key)
  {
   int kp = StringFind(obj, "\""+key+"\""); if(kp<0) return false;
   int co = StringFind(obj, ":", kp);       if(co<0) return false;
   int vs = co+1, n = StringLen(obj);
   while(vs<n && StringGetCharacter(obj,vs)==' ') vs++;
   return (StringSubstr(obj, vs, 4) == "true");
  }

string FmtPrice(const double p)
  {
   int digits = (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
   return DoubleToString(p, digits);
  }

int SplitArray(const string body, string &out[])
  {
   ArrayResize(out,0);
   int cnt=0, n=StringLen(body), i=0;
   while(i<n && StringGetCharacter(body,i)!='[') i++;
   if(i>=n) return 0;
   i++;
   while(i<n)
     {
      while(i<n && StringGetCharacter(body,i)!='{') i++;
      if(i>=n) break;
      int depth=0, start=i; bool inStr=false, esc=false;
      for(;i<n;i++)
        {
         ushort c=StringGetCharacter(body,i);
         if(inStr){if(esc){esc=false;continue;}if(c=='\\'){esc=true;continue;}if(c=='"')inStr=false;continue;}
         if(c=='"'){inStr=true;continue;}
         if(c=='{') depth++;
         else if(c=='}'){if(--depth==0){i++;break;}}
        }
      ArrayResize(out,cnt+1);
      out[cnt++]=StringSubstr(body,start,i-start);
     }
   return cnt;
  }

//+------------------------------------------------------------------+
string HttpGet(const string url)
  {
   char post[], resp[]; string hdrs; ArrayResize(post,0);
   int code = WebRequest("GET", url, "", 5000, post, resp, hdrs);
   if(code!=200)
     { PrintFormat("[ZoneAlerts] GET %s HTTP=%d err=%d", url, code, GetLastError()); return ""; }
   return CharArrayToString(resp);
  }

string TodayUTC()
  {
   MqlDateTime d; TimeToStruct(TimeGMT(),d);
   return StringFormat("%04d-%02d-%02d",d.year,d.mon,d.day);
  }

//+------------------------------------------------------------------+
//| Telegram                                                         |
//+------------------------------------------------------------------+
void SendTelegram(const string msg)
  {
   if(!InpTelegramEnabled || InpTelegramToken=="" || InpTelegramChatID=="") return;

   string safe = msg;
   StringReplace(safe, "\\", "\\\\");
   StringReplace(safe, "\"", "\\\"");

   string url  = "https://api.telegram.org/bot" + InpTelegramToken + "/sendMessage";
   string body = "{\"chat_id\":\"" + InpTelegramChatID + "\",\"text\":\"" + safe + "\"}";

   char   post[], resp[]; string hdrs;
   int    bodyLen = StringLen(body);
   ArrayResize(post, bodyLen);
   StringToCharArray(body, post, 0, bodyLen);

   int code = WebRequest(
      "POST", url,
      "Content-Type: application/json\r\n",
      5000, post, resp, hdrs
   );

   if(InpVerbose)
      PrintFormat("[ZoneAlerts] Telegram HTTP=%d err=%d", code, GetLastError());
  }

//+------------------------------------------------------------------+
void PollZones()
  {
   string body = HttpGet(InpServerURL+"/"+g_base);
   if(body=="") return;
   string elems[]; int n=SplitArray(body,elems); int loaded=0;
   for(int i=0;i<n;i++)
     {
      string obj =elems[i];
      string id  =JsonStr(obj,"id");
      string dir =JsonStr(obj,"direction");
      string str =JsonStr(obj,"strength");
      string kind=JsonStr(obj,"kind");
      if(id=="" || (dir!="buy" && dir!="sell" && dir!="nwog")) continue;

      // ── NWOG: bidirectional zone, valid all week, no time cutoff ──
      if(dir=="nwog")
        {
         double nwFrom=JsonDbl(obj,"from"), nwTo=JsonDbl(obj,"to");
         if(nwFrom<=0 || nwTo<=0) continue;
         double lo=MathMin(nwFrom,nwTo), hi=MathMax(nwFrom,nwTo);
         string nwLabel=StringFormat("%s NWOG %s-%s", g_base, FmtPrice(lo), FmtPrice(hi));

         // UP entry: alert when candle crosses up through the low edge
         Level lvUp;
         lvUp.id           = id+"_up";
         lvUp.source       = "nwog";
         lvUp.label        = nwLabel+" [UP]";
         lvUp.price        = lo;
         lvUp.resistanceUp = true;
         lvUp.primed       = false;
         lvUp.lastAlertBar = 0;
         ArrayResize(g_levels, g_levelCount+1);
         g_levels[g_levelCount++]=lvUp;

         // DOWN entry: alert when candle crosses down through the high edge
         Level lvDn;
         lvDn.id           = id+"_dn";
         lvDn.source       = "nwog";
         lvDn.label        = nwLabel+" [DOWN]";
         lvDn.price        = hi;
         lvDn.resistanceUp = false;
         lvDn.primed       = false;
         lvDn.lastAlertBar = 0;
         ArrayResize(g_levels, g_levelCount+1);
         g_levels[g_levelCount++]=lvDn;

         loaded+=2;
         continue;
        }

      // ── Regular buy/sell zone ──
      bool   resUp      = (dir=="sell");
      bool   watched    = JsonBool(obj,"watchedOnly");
      string watchLabel = watched ? "WATCH" : "ORDER";
      string dirLabel   = (dir=="buy") ? "BUY" : "SELL";

      double lvl=0.0;
      string label="";

      if(kind=="point")
        {
         lvl = JsonDbl(obj,"price");
         if(lvl<=0) continue;
         label = StringFormat("%s %s %s %s @ %s",
                   g_base, dirLabel, str, watchLabel, FmtPrice(lvl));
        }
      else
        {
         double from=JsonDbl(obj,"from"), to=JsonDbl(obj,"to");
         if(from<=0||to<=0) continue;
         double lo=MathMin(from,to), hi=MathMax(from,to);
         lvl   = resUp ? lo : hi;   // cross fires at the near edge
         label = StringFormat("%s %s %s %s zone %s-%s",
                   g_base, dirLabel, str, watchLabel, FmtPrice(lo), FmtPrice(hi));
        }

      Level lv;
      lv.id           = id;
      lv.source       = "zone";
      lv.label        = label;
      lv.price        = lvl;
      lv.resistanceUp = resUp;
      lv.primed       = false;
      lv.lastAlertBar = 0;
      ArrayResize(g_levels, g_levelCount+1);
      g_levels[g_levelCount++]=lv;
      loaded++;
     }
   if(InpVerbose) PrintFormat("[ZoneAlerts] %d zone level(s) loaded", loaded);
  }

void PollOptions()
  {
   string body = HttpGet(InpServerURL+"/options/"+g_base);
   if(body=="") return;
   string today=TodayUTC(), elems[]; int n=SplitArray(body,elems); int loaded=0;
   for(int i=0;i<n;i++)
     {
      string obj =elems[i];
      string id  =JsonStr(obj,"id");
      string dir =JsonStr(obj,"direction");
      string date=JsonStr(obj,"date");
      string time=JsonStr(obj,"time");
      double px  =JsonDbl(obj,"price");
      if(id==""||( dir!="above"&&dir!="below")) continue;
      if(date!=today||px<=0) continue;
      if(time=="") time="16:00";

      bool resUp=(dir=="below");

      Level lv;
      lv.id           = id;
      lv.source       = "option";
      lv.label        = StringFormat("%s OPT %s @ %s exp %s", g_base, dir=="above"?"ABOVE":"BELOW", FmtPrice(px), time);
      lv.price        = px;
      lv.resistanceUp = resUp;
      lv.primed       = false;
      lv.lastAlertBar = 0;
      ArrayResize(g_levels, g_levelCount+1);
      g_levels[g_levelCount++]=lv;
      loaded++;
     }
   if(InpVerbose) PrintFormat("[ZoneAlerts] %d option strike(s) loaded", loaded);
  }

//+------------------------------------------------------------------+
//| Poll both endpoints once. Sets g_loaded when anything is found,  |
//| which halts further polling until the next DailyReset.           |
//+------------------------------------------------------------------+
void PollAll()
  {
   g_lastPoll=TimeCurrent();
   ArrayResize(g_levels,0); g_levelCount=0;
   PollZones();
   PollOptions();
   g_loaded = (g_levelCount > 0);
   if(InpVerbose)
      PrintFormat("[ZoneAlerts] poll complete -- %d level(s); polling %s",
                  g_levelCount, g_loaded ? "HALTED until next UTC day" : "will retry next interval");
  }

//+------------------------------------------------------------------+
//| Cross check -- called on every tick                              |
//+------------------------------------------------------------------+
void CheckLevels()
  {
   // Gate ONLY during a brief post-init settle window. After that, a flaky
   // SYNCHRONIZED read must never silence a live cross check -- the primed
   // flag already prevents attach-time false fires on its own.
   static datetime armAt = 0;
   if(armAt==0) armAt = TimeCurrent() + 15;            // 15s settle
   bool synced = (bool)SeriesInfoInteger(g_symbol,_Period,SERIES_SYNCHRONIZED);
   if(!synced && TimeCurrent() < armAt) return;

   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   int utcHour=dt.hour;

   datetime barOpen=(datetime)SeriesInfoInteger(g_symbol,_Period,SERIES_LASTBAR_DATE);
   double   open   =iOpen (g_symbol,_Period,0);
   double   high   =iHigh (g_symbol,_Period,0);
   double   low    =iLow  (g_symbol,_Period,0);
   if(open<=0 || high<=0 || low<=0 || barOpen<=0) return;

   for(int i=0;i<g_levelCount;i++)
     {
      if(g_levels[i].source=="zone"   && utcHour>=InpZoneEndUTC) continue;
      if(g_levels[i].source=="option" && utcHour>=InpOptEndUTC)  continue;

      double lvl=g_levels[i].price;
      bool   crossed = g_levels[i].resistanceUp ? (open<lvl && high>lvl)
                                                : (open>lvl && low<lvl);

      // Arm only after price has been seen on the non-crossing side. Until
      // then (price already past at attach, or a glitchy read) we never alert.
      if(!g_levels[i].primed)
        {
         if(!crossed)
           {
            g_levels[i].primed = true;
            if(InpVerbose) PrintFormat("[ZoneAlerts] primed %s", g_levels[i].label);
           }
         continue;
        }

      if(g_levels[i].lastAlertBar==barOpen) continue;
      if(!crossed) continue;

      bool pushed = SendNotification(g_levels[i].label);
      SendTelegram(g_levels[i].label);
      if(InpAlertEnabled) Alert(g_levels[i].label);
      PrintFormat("[ZoneAlerts] CROSS -- %s | push=%s err=%d", g_levels[i].label, pushed?"OK":"FAILED", GetLastError());
      g_levels[i].lastAlertBar=barOpen;
     }
  }

void DailyReset(const int day)
  {
   g_lastDay=day; g_levelCount=0; ArrayResize(g_levels,0); g_lastPoll=0; g_loaded=false;
   if(InpVerbose) Print("[ZoneAlerts] Daily reset -- polling re-armed");
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   string sym=(InpSymbolName!="") ? InpSymbolName : _Symbol;
   g_base=ResolveBase(sym);
   if(g_base=="")
     { PrintFormat("[ZoneAlerts] Symbol '%s' not supported.",sym); return INIT_FAILED; }
   g_symbol=sym;

   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   g_lastDay=dt.day_of_year;

   string startMsg = "ZoneAlerts v4 started on " + g_base;
   bool initPush = SendNotification(startMsg);
   SendTelegram(startMsg);
   PrintFormat("[ZoneAlerts] Startup push notification: %s (err=%d)", initPush?"OK":"FAILED", GetLastError());

   // Add api.telegram.org AND http://37.46.211.146:3000 to
   // Tools > Options > Expert Advisors > Allow WebRequest
   EventSetTimer(60);
   PollAll();
   if(InpVerbose) PrintFormat("[ZoneAlerts] Ready -- %s (%s)  zone end=%d UTC  opt end=%d UTC",
               g_symbol,g_base,InpZoneEndUTC,InpOptEndUTC);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer()
  {
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   if(dt.day_of_year!=g_lastDay) DailyReset(dt.day_of_year);
   if(!g_loaded && TimeCurrent()-g_lastPoll>=(datetime)(InpPollMins*60)) PollAll();
   CheckLevels();
  }

void OnTick()
  {
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   if(dt.day_of_year!=g_lastDay) DailyReset(dt.day_of_year);
   CheckLevels();
  }
//+------------------------------------------------------------------+
