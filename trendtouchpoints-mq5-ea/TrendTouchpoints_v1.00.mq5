//+------------------------------------------------------------------+
//|                                       TrendTouchpoints_v1.00.mq5 |
//|                                  Tori Trade — Trendline Playbook |
//|                                                                  |
//|  Bounce + 2pt-Break + 3pt-Break on H4, action/safety-line risk   |
//|  Slot Market-Char filter (favored UTC hours)                     |
//|  ICT RTH session filter                                          |
//+------------------------------------------------------------------+
#property copyright "KSE"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//============================== INPUTS ===============================
input group "=== Strategy ==="
input ENUM_TIMEFRAMES InpTF                = PERIOD_H4;     // Working timeframe
input bool   InpUseBounce                  = true;          // Enable Trendline Bounce
input bool   InpUseBreak2pt                = true;          // Enable 2-touchpoint Break
input bool   InpUseBreak3pt                = true;          // Enable 3-touchpoint Break
input int    InpBounceMinTouches           = 2;             // Bounce min touchpoints (2 or 3)
input int    InpBreak2ptTouches            = 2;             // 2pt break required touches
input int    InpBreak3ptTouches            = 3;             // 3pt break required touches
input int    InpMinDaysSpan                = 7;             // Min days from 1st touch to entry (playbook: 1 week)
input int    InpLookbackBars               = 600;           // Bars scanned to find swings/lines (~100 days H4)

input group "=== Swing Detection ==="
input int    InpFractalLeft                = 3;             // Bars to left of pivot
input int    InpFractalRight               = 3;             // Bars to right of pivot
input double InpTouchToleranceATR          = 0.35;          // Touch tolerance (× ATR)
input int    InpATRPeriod                  = 14;            // ATR length for tolerance + buffer
input double InpBreakBufferATR             = 0.10;          // Close beyond line by N×ATR to confirm break
input double InpMaxBreakDistanceATR        = 2.0;           // Skip break if safety line > N×ATR away (playbook: "close to safety line")

input group "=== Risk ==="
input double InpRiskPercent                = 0.5;           // Risk per trade (% of balance). 0 = use InpFixedLots
input double InpFixedLots                  = 0.10;          // Used if InpRiskPercent = 0
input double InpStopBufferATR              = 0.25;          // SL placed N×ATR beyond line (give wick room — playbook)
input double InpMaxLots                    = 5.0;           // Hard cap
input int    InpMagicNumber                = 20260511;      // EA magic

input group "=== Slot Market-Char Filter (UTC hours) ==="
input bool   InpUseSlotFilter              = false;         // Restrict entries to favored UTC start-hours
input string InpFavoredHoursCSV            = "8,12,16,20";  // H4 bar start-hour whitelist (UTC). Empty = allow all.

input group "=== ICT RTH Filter ==="
input bool   InpUseRTHFilter               = false;         // Only enter inside RTH window
input int    InpRTHStartHourUTC            = 13;            // RTH session start (UTC). Gold COMEX = 13
input int    InpRTHEndHourUTC              = 20;            // RTH session end   (UTC). Gold COMEX = 20

input group "=== Misc ==="
input bool   InpVerbose                    = true;          // Verbose logging

//============================== GLOBALS ==============================
CTrade  g_trade;
int     g_atrHandle = INVALID_HANDLE;
datetime g_lastBarTime = 0;

// Pivot record
struct Pivot {
   datetime time;
   int      bar;        // index in series-true H4 buffer
   double   price;
   bool     isHigh;     // true=swing high, false=swing low
};

// Trendline record (for diagnostics / management)
struct TLine {
   bool     valid;
   bool     isUp;       // up=connects lows (support); down=connects highs (resistance)
   double   price0;     // anchor price at time0
   datetime time0;
   double   slope;      // price per second
   int      touches;
   datetime firstTouchTime;
};

Pivot   g_pivots[];
TLine   g_currentActionLine;    // For trade management (trail)
TLine   g_currentSafetyLine;    // For break setups
bool    g_inLong  = false;
bool    g_inShort = false;
ulong   g_currentTicket = 0;
int     g_currentSetupType = 0; // 1=bounce, 2=break2, 3=break3

//============================== INIT =================================
int OnInit() {
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_atrHandle = iATR(_Symbol, InpTF, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE) {
      Print("ATR handle creation failed");
      return INIT_FAILED;
   }

   g_currentActionLine.valid = false;
   g_currentSafetyLine.valid = false;

   if(InpVerbose) PrintFormat("TrendTouchpoints v1.00 init OK on %s %s", _Symbol, EnumToString(InpTF));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
}

//============================== TICK =================================
void OnTick() {
   // Bar-open gate
   datetime curBar = iTime(_Symbol, InpTF, 0);
   if(curBar == g_lastBarTime) {
      // Inside same bar — only manage trails on each tick? Playbook trails on bar close.
      // We re-evaluate trail on each new bar to keep it deterministic.
      return;
   }
   g_lastBarTime = curBar;

   // Manage open trade first (trail / exit on close-through)
   if(PositionExistsForMagic()) {
      ManageOpenTrade();
      return;
   } else {
      g_inLong = g_inShort = false;
      g_currentActionLine.valid = false;
      g_currentSafetyLine.valid = false;
   }

   // Refresh pivot universe
   if(!BuildPivots()) {
      if(InpVerbose) Print("Pivot build failed / insufficient bars");
      return;
   }

   // Apply session filters BEFORE searching for entry signals
   if(!SlotFilterPassed()) {
      if(InpVerbose) PrintFormat("Slot filter blocked entry (bar start hour=%d UTC)", BarStartHourUTC(1));
      return;
   }
   if(!RTHFilterPassed()) {
      if(InpVerbose) PrintFormat("RTH filter blocked entry (bar start hour=%d UTC, RTH=[%d,%d))",
                                  BarStartHourUTC(1), InpRTHStartHourUTC, InpRTHEndHourUTC);
      return;
   }

   // Scan setups (prefer lower-risk: bounce > break3 > break2)
   if(InpUseBounce   && TryBounce())   return;
   if(InpUseBreak3pt && TryBreak(InpBreak3ptTouches, 3)) return;
   if(InpUseBreak2pt && TryBreak(InpBreak2ptTouches, 2)) return;
}

//================== POSITION HELPERS =================================
bool PositionExistsForMagic() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) {
         g_currentTicket = ticket;
         g_inLong  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         g_inShort = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL);
         return true;
      }
   }
   return false;
}

//================== PIVOT / SWING DETECTION ==========================
bool BuildPivots() {
   ArrayResize(g_pivots, 0);

   int need = MathMin(InpLookbackBars, Bars(_Symbol, InpTF) - 5);
   if(need < 60) return false;

   double high[], low[];
   datetime tm[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);
   ArraySetAsSeries(tm,   true);

   if(CopyHigh (_Symbol, InpTF, 0, need, high) <= 0) return false;
   if(CopyLow  (_Symbol, InpTF, 0, need, low)  <= 0) return false;
   if(CopyTime (_Symbol, InpTF, 0, need, tm)   <= 0) return false;

   int L = InpFractalLeft, R = InpFractalRight;

   // Walk from oldest detectable to most recent confirmed pivot.
   // index range: [R .. need-1-L]   (series-true, so 0 = latest)
   for(int i = need - 1 - L; i >= R; i--) {
      // Swing high check
      bool isHi = true;
      for(int k = 1; k <= L && isHi; k++) if(high[i] <= high[i+k]) isHi = false;
      for(int k = 1; k <= R && isHi; k++) if(high[i] <  high[i-k]) isHi = false;

      // Swing low check
      bool isLo = true;
      for(int k = 1; k <= L && isLo; k++) if(low[i] >= low[i+k]) isLo = false;
      for(int k = 1; k <= R && isLo; k++) if(low[i] >  low[i-k]) isLo = false;

      if(isHi || isLo) {
         Pivot p;
         p.time   = tm[i];
         p.bar    = i;
         p.price  = isHi ? high[i] : low[i];
         p.isHigh = isHi;
         int n = ArraySize(g_pivots);
         ArrayResize(g_pivots, n+1);
         g_pivots[n] = p;
      }
   }
   return ArraySize(g_pivots) >= 4;
}

//================== TRENDLINE GEOMETRY ===============================
// price(t) = price0 + slope * (t - time0)   (slope in price-per-second)
double LinePriceAt(const TLine &ln, datetime t) {
   return ln.price0 + ln.slope * (double)((long)t - (long)ln.time0);
}

TLine MakeLine(const Pivot &a, const Pivot &b) {
   TLine ln; ln.valid = false; ln.touches = 0; ln.firstTouchTime = a.time;
   long dt = (long)b.time - (long)a.time;
   if(dt == 0) return ln;
   ln.price0 = a.price;
   ln.time0  = a.time;
   ln.slope  = (b.price - a.price) / (double)dt;
   ln.isUp   = (b.price > a.price);
   ln.valid  = true;
   return ln;
}

double CurrentATR() {
   double atr[1];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) != 1) return 0.0;
   return atr[0];
}

int CountTouchpoints(const TLine &ln, bool useHighs, double tolerance, datetime earliest, datetime latest) {
   int count = 0;
   for(int i = 0; i < ArraySize(g_pivots); i++) {
      Pivot p = g_pivots[i];
      if(p.isHigh != useHighs) continue;
      if(p.time < earliest || p.time > latest) continue;
      double proj = LinePriceAt(ln, p.time);
      if(MathAbs(p.price - proj) <= tolerance) count++;
   }
   return count;
}

//================== BOUNCE SETUP =====================================
// Bounce LONG: ascending line through swing LOWS, price tests it, no close-through.
// Bounce SHORT: descending line through swing HIGHS.
bool TryBounce() {
   double atr = CurrentATR();
   if(atr <= 0) return false;
   double tol = atr * InpTouchToleranceATR;

   datetime now = iTime(_Symbol, InpTF, 0);
   double curClose = iClose(_Symbol, InpTF, 1); // last fully closed bar
   double curLow   = iLow  (_Symbol, InpTF, 1);
   double curHigh  = iHigh (_Symbol, InpTF, 1);

   // ---- LONG bounce: try every pair of swing lows from most recent backward ----
   for(int i = 0; i < ArraySize(g_pivots) - 1; i++) {
      if(g_pivots[i].isHigh) continue;
      Pivot pB = g_pivots[i];   // newer (smaller bar index? our build appends oldest→newest; so newer = larger time)
      for(int j = i + 1; j < ArraySize(g_pivots); j++) {
         if(g_pivots[j].isHigh) continue;
         Pivot pA = g_pivots[j];  // older
         if(pA.time >= pB.time) continue;
         if(pB.price <= pA.price) continue; // require ascending (higher low)

         TLine ln = MakeLine(pA, pB);
         if(!ln.valid || ln.slope <= 0) continue;

         // ≥ 1 week from first touchpoint to NOW
         double daysSpan = (double)((long)now - (long)pA.time) / 86400.0;
         if(daysSpan < InpMinDaysSpan) continue;

         int tp = CountTouchpoints(ln, false, tol, pA.time, now);
         if(tp < InpBounceMinTouches) continue;

         // Entry trigger: last closed bar's LOW touched line within tolerance AND close ABOVE line (respected)
         double lineNow = LinePriceAt(ln, iTime(_Symbol, InpTF, 1));
         bool touched   = (curLow  <= lineNow + tol);
         bool respected = (curClose > lineNow);
         if(touched && respected) {
            return EnterBounceLong(ln, atr, tp);
         }
      }
   }

   // ---- SHORT bounce: descending line through swing HIGHS ----
   for(int i = 0; i < ArraySize(g_pivots) - 1; i++) {
      if(!g_pivots[i].isHigh) continue;
      Pivot pB = g_pivots[i];
      for(int j = i + 1; j < ArraySize(g_pivots); j++) {
         if(!g_pivots[j].isHigh) continue;
         Pivot pA = g_pivots[j];
         if(pA.time >= pB.time) continue;
         if(pB.price >= pA.price) continue; // descending (lower high)

         TLine ln = MakeLine(pA, pB);
         if(!ln.valid || ln.slope >= 0) continue;

         double daysSpan = (double)((long)now - (long)pA.time) / 86400.0;
         if(daysSpan < InpMinDaysSpan) continue;

         int tp = CountTouchpoints(ln, true, tol, pA.time, now);
         if(tp < InpBounceMinTouches) continue;

         double lineNow = LinePriceAt(ln, iTime(_Symbol, InpTF, 1));
         bool touched   = (curHigh >= lineNow - tol);
         bool respected = (curClose < lineNow);
         if(touched && respected) {
            return EnterBounceShort(ln, atr, tp);
         }
      }
   }

   return false;
}

//================== BREAK SETUP ======================================
// Break LONG = price closes ABOVE a descending line through HIGHS (broken resistance)
//              Safety line = ascending line through recent LOWS.
// Break SHORT = price closes BELOW an ascending line through LOWS (broken support)
//              Safety line = descending line through recent HIGHS.
bool TryBreak(int requiredTouches, int setupKind) {
   double atr = CurrentATR();
   if(atr <= 0) return false;
   double tol  = atr * InpTouchToleranceATR;
   double brk  = atr * InpBreakBufferATR;
   double maxD = atr * InpMaxBreakDistanceATR;

   datetime now    = iTime(_Symbol, InpTF, 0);
   datetime closed = iTime(_Symbol, InpTF, 1);
   double curClose = iClose(_Symbol, InpTF, 1);
   double prevClose = iClose(_Symbol, InpTF, 2);

   // ---- BREAK LONG: action = descending line through HIGHS ----
   for(int i = 0; i < ArraySize(g_pivots) - 1; i++) {
      if(!g_pivots[i].isHigh) continue;
      Pivot pB = g_pivots[i];
      for(int j = i + 1; j < ArraySize(g_pivots); j++) {
         if(!g_pivots[j].isHigh) continue;
         Pivot pA = g_pivots[j];
         if(pA.time >= pB.time) continue;
         if(pB.price >= pA.price) continue;

         TLine action = MakeLine(pA, pB);
         if(!action.valid || action.slope >= 0) continue;

         double daysSpan = (double)((long)now - (long)pA.time) / 86400.0;
         if(daysSpan < InpMinDaysSpan) continue;

         int tp = CountTouchpoints(action, true, tol, pA.time, now);
         if(tp < requiredTouches) continue;

         // Confirm break on last closed bar
         double lineNow = LinePriceAt(action, closed);
         if(!(curClose > lineNow + brk && prevClose <= lineNow + brk)) continue;

         // Build safety line — ascending line through 2 most recent swing LOWS, both before `closed`
         TLine safety;
         if(!BuildSafetyAscending(closed, safety)) continue;

         double safetyNow = LinePriceAt(safety, closed);
         // Playbook: break must be close to safety line.
         double dist = MathAbs(curClose - safetyNow);
         if(dist > maxD) continue;
         // Safety must be BELOW entry price for a long.
         if(safetyNow >= curClose) continue;

         return EnterBreakLong(action, safety, atr, tp, setupKind);
      }
   }

   // ---- BREAK SHORT: action = ascending line through LOWS ----
   for(int i = 0; i < ArraySize(g_pivots) - 1; i++) {
      if(g_pivots[i].isHigh) continue;
      Pivot pB = g_pivots[i];
      for(int j = i + 1; j < ArraySize(g_pivots); j++) {
         if(g_pivots[j].isHigh) continue;
         Pivot pA = g_pivots[j];
         if(pA.time >= pB.time) continue;
         if(pB.price <= pA.price) continue;

         TLine action = MakeLine(pA, pB);
         if(!action.valid || action.slope <= 0) continue;

         double daysSpan = (double)((long)now - (long)pA.time) / 86400.0;
         if(daysSpan < InpMinDaysSpan) continue;

         int tp = CountTouchpoints(action, false, tol, pA.time, now);
         if(tp < requiredTouches) continue;

         double lineNow = LinePriceAt(action, closed);
         if(!(curClose < lineNow - brk && prevClose >= lineNow - brk)) continue;

         TLine safety;
         if(!BuildSafetyDescending(closed, safety)) continue;

         double safetyNow = LinePriceAt(safety, closed);
         double dist = MathAbs(safetyNow - curClose);
         if(dist > maxD) continue;
         if(safetyNow <= curClose) continue;

         return EnterBreakShort(action, safety, atr, tp, setupKind);
      }
   }

   return false;
}

//================== SAFETY-LINE BUILDERS =============================
bool BuildSafetyAscending(datetime before, TLine &out) {
   // Two most recent swing LOWS strictly before `before` that form ascending line
   int newerIdx = -1;
   for(int i = 0; i < ArraySize(g_pivots); i++) {
      if(g_pivots[i].isHigh || g_pivots[i].time >= before) continue;
      if(newerIdx < 0) { newerIdx = i; continue; }
      // current pivot is older than the newer we already locked
      if(g_pivots[newerIdx].price > g_pivots[i].price &&
         g_pivots[i].time         < g_pivots[newerIdx].time) {
         out = MakeLine(g_pivots[i], g_pivots[newerIdx]);
         return out.valid && out.slope > 0;
      }
   }
   return false;
}

bool BuildSafetyDescending(datetime before, TLine &out) {
   int newerIdx = -1;
   for(int i = 0; i < ArraySize(g_pivots); i++) {
      if(!g_pivots[i].isHigh || g_pivots[i].time >= before) continue;
      if(newerIdx < 0) { newerIdx = i; continue; }
      if(g_pivots[newerIdx].price < g_pivots[i].price &&
         g_pivots[i].time         < g_pivots[newerIdx].time) {
         out = MakeLine(g_pivots[i], g_pivots[newerIdx]);
         return out.valid && out.slope < 0;
      }
   }
   return false;
}

//================== ENTRIES ==========================================
double CalcLots(double slDistancePrice) {
   if(InpRiskPercent <= 0.0) return NormalizeLots(InpFixedLots);
   double bal       = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = bal * InpRiskPercent / 100.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0 || slDistancePrice <= 0) return NormalizeLots(InpFixedLots);
   double lots = riskMoney / (slDistancePrice / tickSize * tickValue);
   return NormalizeLots(lots);
}

double NormalizeLots(double lots) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots/step) * step;
   lots = MathMax(mn, MathMin(MathMin(mx, InpMaxLots), lots));
   return NormalizeDouble(lots, 2);
}

bool EnterBounceLong(const TLine &action, double atr, int touches) {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lineNow = LinePriceAt(action, iTime(_Symbol, InpTF, 0));
   double sl = lineNow - atr * InpStopBufferATR;
   if(sl >= price) return false;
   double lots = CalcLots(price - sl);
   if(lots <= 0) return false;

   string cmt = StringFormat("BounceLong tp=%d", touches);
   if(g_trade.Buy(lots, _Symbol, price, sl, 0.0, cmt)) {
      g_currentActionLine = action;
      g_currentSafetyLine = action; // bounce: action = safety
      g_currentSetupType = 1;
      g_inLong = true;
      if(InpVerbose) PrintFormat("ENTER BounceLong @ %.5f sl=%.5f lots=%.2f touches=%d", price, sl, lots, touches);
      return true;
   }
   return false;
}

bool EnterBounceShort(const TLine &action, double atr, int touches) {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lineNow = LinePriceAt(action, iTime(_Symbol, InpTF, 0));
   double sl = lineNow + atr * InpStopBufferATR;
   if(sl <= price) return false;
   double lots = CalcLots(sl - price);
   if(lots <= 0) return false;

   string cmt = StringFormat("BounceShort tp=%d", touches);
   if(g_trade.Sell(lots, _Symbol, price, sl, 0.0, cmt)) {
      g_currentActionLine = action;
      g_currentSafetyLine = action;
      g_currentSetupType = 1;
      g_inShort = true;
      if(InpVerbose) PrintFormat("ENTER BounceShort @ %.5f sl=%.5f lots=%.2f touches=%d", price, sl, lots, touches);
      return true;
   }
   return false;
}

bool EnterBreakLong(const TLine &action, const TLine &safety, double atr, int touches, int kind) {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double safetyNow = LinePriceAt(safety, iTime(_Symbol, InpTF, 0));
   double sl = safetyNow - atr * InpStopBufferATR;
   if(sl >= price) return false;
   double lots = CalcLots(price - sl);
   if(lots <= 0) return false;

   string cmt = StringFormat("Break%dLong tp=%d", kind, touches);
   if(g_trade.Buy(lots, _Symbol, price, sl, 0.0, cmt)) {
      g_currentActionLine = action;
      g_currentSafetyLine = safety;
      g_currentSetupType = (kind == 3 ? 3 : 2);
      g_inLong = true;
      if(InpVerbose) PrintFormat("ENTER Break%dLong @ %.5f sl=%.5f lots=%.2f touches=%d", kind, price, sl, lots, touches);
      return true;
   }
   return false;
}

bool EnterBreakShort(const TLine &action, const TLine &safety, double atr, int touches, int kind) {
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double safetyNow = LinePriceAt(safety, iTime(_Symbol, InpTF, 0));
   double sl = safetyNow + atr * InpStopBufferATR;
   if(sl <= price) return false;
   double lots = CalcLots(sl - price);
   if(lots <= 0) return false;

   string cmt = StringFormat("Break%dShort tp=%d", kind, touches);
   if(g_trade.Sell(lots, _Symbol, price, sl, 0.0, cmt)) {
      g_currentActionLine = action;
      g_currentSafetyLine = safety;
      g_currentSetupType = (kind == 3 ? 3 : 2);
      g_inShort = true;
      if(InpVerbose) PrintFormat("ENTER Break%dShort @ %.5f sl=%.5f lots=%.2f touches=%d", kind, price, sl, lots, touches);
      return true;
   }
   return false;
}

//================== TRADE MANAGEMENT =================================
// Playbook: exit when price CLOSES through the safety line. Trail stop along safety line as new swings form.
void ManageOpenTrade() {
   if(!PositionSelectByTicket(g_currentTicket)) return;
   if(!g_currentSafetyLine.valid) return;

   double atr = CurrentATR();
   if(atr <= 0) return;

   datetime closedBarTime = iTime(_Symbol, InpTF, 1);
   double curClose        = iClose(_Symbol, InpTF, 1);
   double safetyAtClosed  = LinePriceAt(g_currentSafetyLine, closedBarTime);

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   if(g_inLong) {
      // Exit on close-through
      if(curClose < safetyAtClosed) {
         g_trade.PositionClose(g_currentTicket);
         if(InpVerbose) PrintFormat("EXIT Long (close-through safety) close=%.5f safety=%.5f", curClose, safetyAtClosed);
         return;
      }
      // Trail along line: tighten SL up to line - buffer
      double newSL = LinePriceAt(g_currentSafetyLine, iTime(_Symbol, InpTF, 0)) - atr * InpStopBufferATR;
      if(newSL > currentSL + _Point) {
         g_trade.PositionModify(g_currentTicket, newSL, currentTP);
      }
   } else if(g_inShort) {
      if(curClose > safetyAtClosed) {
         g_trade.PositionClose(g_currentTicket);
         if(InpVerbose) PrintFormat("EXIT Short (close-through safety) close=%.5f safety=%.5f", curClose, safetyAtClosed);
         return;
      }
      double newSL = LinePriceAt(g_currentSafetyLine, iTime(_Symbol, InpTF, 0)) + atr * InpStopBufferATR;
      if(currentSL == 0.0 || newSL < currentSL - _Point) {
         g_trade.PositionModify(g_currentTicket, newSL, currentTP);
      }
   }
}

//================== SLOT + RTH FILTERS ===============================
int BarStartHourUTC(int shift) {
   datetime t = iTime(_Symbol, InpTF, shift);
   MqlDateTime mt; TimeToStruct(t, mt);
   return mt.hour;   // server-time hour; broker servers are typically UTC+2/3.
                     // Adjust InpRTHStartHourUTC accordingly if your broker server isn't UTC.
}

bool SlotFilterPassed() {
   if(!InpUseSlotFilter) return true;
   string csv = InpFavoredHoursCSV;
   StringTrimLeft(csv); StringTrimRight(csv);
   if(StringLen(csv) == 0) return true;

   int hour = BarStartHourUTC(1);   // last closed bar's start hour
   string parts[];
   int n = StringSplit(csv, ',', parts);
   for(int i = 0; i < n; i++) {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) == 0) continue;
      if((int)StringToInteger(s) == hour) return true;
   }
   return false;
}

bool RTHFilterPassed() {
   if(!InpUseRTHFilter) return true;
   int hour = BarStartHourUTC(1);
   if(InpRTHEndHourUTC > InpRTHStartHourUTC) {
      return (hour >= InpRTHStartHourUTC && hour < InpRTHEndHourUTC);
   }
   // wrap-around window
   return (hour >= InpRTHStartHourUTC || hour < InpRTHEndHourUTC);
}
//+------------------------------------------------------------------+
