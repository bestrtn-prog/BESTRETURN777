////+------------------------------------------------------------------+
//|                                              breaksPL101811.mq4    |
//+------------------------------------------------------------------+
#property copyright "breaksPL101811"
#property version   "1.06"
#property strict

//--- パラメータ
input double  RiskPercent        = 10.0;   // リスク許容率(%)
input double  MarginLimitPercent = 5.0;   // 証拠金制限率（%）（日本規制4%に対する上乗せ）
input int     LookbackBars       = 10;     // エントリー閾値取得バー数
input int     ExitLookbackBars   = 5;     // エグジット閾値取得バー数
input double  EntrySpreadPips    = 3.0;   // エントリー許容スプレッド(pips)
input double  ExitSpreadPips     = 30.0;  // エグジット許容スプレッド(pips)
input int     HistoryBars        = 200;    // 起動時の過去分析バー数

//--- グローバル変数
string   CSVFileName;
bool     LastTradeWasLoss = false;
bool     WaitingForExit = false;  // 起動時分析でポジション中と判定され、エグジット待ちフラグ

//--- 仮想ポジション構造体
struct VirtualPosition
{
   bool     Active;
   int      Type;
   double   OpenPrice;
   datetime OpenTime;
   double   Lots;
   string   UniqueID;
};
VirtualPosition VirtualPos;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   VirtualPos.Active    = false;
   VirtualPos.Type      = -1;
   VirtualPos.OpenPrice = 0;
   VirtualPos.OpenTime  = 0;
   VirtualPos.Lots      = 0;
   VirtualPos.UniqueID  = "";

   string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
   StringReplace(ts, ":", "");
   StringReplace(ts, ".", "");
   StringReplace(ts, " ", "_");
   CSVFileName = "breaksPL101811_" + ts + ".csv";

   InitializeCSV();
   
   // 起動時に過去のバーを分析して状態を復元
   AnalyzeHistoricalBars();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| ティック処理                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   if(HasRealPosition())
   {
      CheckRealPositionExit();
      // ポジションがクローズされたらWaitingForExitフラグを解除
      if(!HasRealPosition() && WaitingForExit)
      {
         WaitingForExit = false;
         Print("エグジット完了。次のエントリーシグナルを待機します。");
      }
      return;
   }
   if(VirtualPos.Active)
   {
      CheckVirtualPositionExit();
      // 仮想ポジションがクローズされたらWaitingForExitフラグを解除
      if(!VirtualPos.Active && WaitingForExit)
      {
         WaitingForExit = false;
         Print("仮想ポジションエグジット完了。次のエントリーシグナルを待機します。");
      }
      return;
   }
   
   // WaitingForExitフラグが立っている場合は新規エントリーしない
   if(WaitingForExit)
   {
      return;
   }
   
   CheckEntrySignals();
}

//+------------------------------------------------------------------+
//| 実ポジ有無確認                                                  |
//+------------------------------------------------------------------+
bool HasRealPosition()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES)
      && OrderSymbol()==Symbol()
      && OrderMagicNumber()==GetMagicNumber())
         return true;
   return false;
}

//+------------------------------------------------------------------+
//| 実ポジ エグジット処理                                           |
//+------------------------------------------------------------------+
void CheckRealPositionExit()
{
   double bid = MarketInfo(Symbol(), MODE_BID);
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double tick = GetTickSize();
   int pipScale = (Digits == 3 || Digits == 5) ? 10 : 1;
   double spreadPips = (ask - bid) / tick / pipScale;
   if(spreadPips > ExitSpreadPips) return;

   int maxBars = Bars(Symbol(),0);
   if(ExitLookbackBars >= maxBars) return;

   double highTh = GetHighThreshold(ExitLookbackBars);
   double lowTh  = GetLowThreshold(ExitLookbackBars);

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()||OrderMagicNumber()!=GetMagicNumber()) continue;

      bool   shouldClose = false;
      string exitDir     = "";
      double threshold   = 0;
      double closePrice  = 0;

      if(OrderType()==OP_BUY && bid <= lowTh)
      {
         shouldClose = true; exitDir = "Sell"; threshold = lowTh; closePrice = bid;
      }
      else if(OrderType()==OP_SELL && bid >= highTh)
      {
         shouldClose = true; exitDir = "Buy"; threshold = highTh; closePrice = ask;
      }
      if(!shouldClose) continue;

      int ticket = OrderTicket();
      int orderType = OrderType();
      double openPrice = OrderOpenPrice();
      double lots = OrderLots();
      
      bool closed = false;
      for(int r=0; r<3; r++)
      {
         RefreshRates(); Sleep(100);
         closePrice = (orderType==OP_BUY) ? MarketInfo(Symbol(),MODE_BID) : MarketInfo(Symbol(),MODE_ASK);
         closed = OrderClose(ticket, lots, closePrice, 3, clrRed);
         if(closed) break;
         Sleep(500);
      }
      if(!closed) continue;

      if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY)) continue;
      
      double commission = OrderCommission();
      double swap       = OrderSwap();
      double netProfit  = OrderProfit() + commission + swap;
      LastTradeWasLoss  = (netProfit < 0);
      double priceDiffPips = ((orderType == OP_BUY)
                              ? (closePrice - threshold)
                              : (threshold - closePrice)) / tick / pipScale;
      double pipsProfit    = ((orderType == OP_BUY)
                              ? (closePrice - openPrice)
                              : (openPrice - closePrice)) / tick / pipScale;
      double slPips = 0;

      LogTrade(
         "Exit",
         exitDir,
         OrderCloseTime(),
         slPips,
         lots,
         threshold,
         closePrice,
         priceDiffPips,
         pipsProfit,
         commission,
         swap,
         netProfit,
         AccountBalance(),
         IntegerToString(ticket),
         0
      );
   }
}

//+------------------------------------------------------------------+
//| 仮想ポジションのエグジット処理                                  |
//+------------------------------------------------------------------+
void CheckVirtualPositionExit()
{
   double bid    = MarketInfo(Symbol(), MODE_BID);
   double ask    = MarketInfo(Symbol(), MODE_ASK);
   double tick   = GetTickSize();
   int pipScale  = (Digits == 3 || Digits == 5) ? 10 : 1;
   double spreadPips = (ask - bid) / tick / pipScale;
   if(spreadPips > ExitSpreadPips) return;

   int maxBars = Bars(Symbol(),0);
   if(ExitLookbackBars >= maxBars) return;

   double highTh = GetHighThreshold(ExitLookbackBars);
   double lowTh  = GetLowThreshold(ExitLookbackBars);

   bool   shouldExit = false;
   string exitDir    = "";
   double threshold  = 0;

   if(VirtualPos.Type == OP_BUY && bid <= lowTh)
   {
      shouldExit = true; exitDir = "Sell"; threshold = lowTh;
   }
   else if(VirtualPos.Type == OP_SELL && bid >= highTh)
   {
      shouldExit = true; exitDir = "Buy"; threshold = highTh;
   }
   if(!shouldExit) return;

   double closePrice = (VirtualPos.Type == OP_BUY) ? bid : ask;
   double openPrice  = VirtualPos.OpenPrice;
   double lots       = VirtualPos.Lots;
   datetime closeTime = TimeCurrent();

   double priceDiffPips = ((VirtualPos.Type == OP_BUY)
                           ? (closePrice - threshold)
                           : (threshold - closePrice)) / tick / pipScale;
   double pipsProfit    = ((VirtualPos.Type == OP_BUY)
                           ? (closePrice - openPrice)
                           : (openPrice - closePrice)) / tick / pipScale;

   double commission = 0;
   double swap       = 0;
   double netProfit  = pipsProfit * lots * MarketInfo(Symbol(), MODE_TICKVALUE);

   LastTradeWasLoss = (netProfit < 0);

   LogTrade(
      "Virtual exit",
      exitDir,
      closeTime,
      0,
      lots,
      threshold,
      closePrice,
      priceDiffPips,
      pipsProfit,
      commission,
      swap,
      netProfit,
      AccountBalance(),
      VirtualPos.UniqueID,
      0
   );

   VirtualPos.Active    = false;
   VirtualPos.Type      = -1;
   VirtualPos.OpenPrice = 0;
   VirtualPos.OpenTime  = 0;
   VirtualPos.Lots      = 0;
   VirtualPos.UniqueID  = "";
}

//+------------------------------------------------------------------+
//| エントリーシグナルチェック                                       |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   double bid = MarketInfo(Symbol(), MODE_BID);
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double tick = GetTickSize();
   int pipScale = (Digits == 3 || Digits == 5) ? 10 : 1;
   double spreadPips = (ask - bid) / tick / pipScale;
   if(spreadPips > EntrySpreadPips) return;

   if(LookbackBars >= Bars(Symbol(),0)) return;

   double buyTh  = GetHighThreshold(LookbackBars);
   double sellTh = GetLowThreshold(LookbackBars);

   bool buySig  = (bid >= buyTh)  && ((ask - buyTh) / tick / pipScale <= EntrySpreadPips);
   bool sellSig = (bid <= sellTh) && ((sellTh - bid) / tick / pipScale <= EntrySpreadPips);

   if(buySig)
   {
      double lowTh = GetLowThreshold(ExitLookbackBars);
      double slPips = MathAbs(buyTh - lowTh) / tick / pipScale;
      
      if(!LastTradeWasLoss)
      {
         double lots = CalculateLotSize(buyTh, lowTh);
         VirtualPos.Active    = true;
         VirtualPos.Type      = OP_BUY;
         VirtualPos.OpenPrice = ask;
         VirtualPos.OpenTime  = TimeCurrent();
         VirtualPos.Lots      = lots;
         VirtualPos.UniqueID  = GenerateUniqueID();
         
         double priceDiffPips = (buyTh - ask) / tick / pipScale;
         
         LogTrade(
            "Virtual entry",
            "Buy",
            VirtualPos.OpenTime,
            slPips,
            lots,
            buyTh,
            ask,
            priceDiffPips,
            0,
            0,
            0,
            0,
            AccountBalance(),
            VirtualPos.UniqueID,
            0
         );
      }
      else
      {
         OpenRealPosition(OP_BUY, buyTh, lowTh);
      }
   }
   else if(sellSig)
   {
      double highTh = GetHighThreshold(ExitLookbackBars);
      double slPips = MathAbs(highTh - sellTh) / tick / pipScale;
      
      if(!LastTradeWasLoss)
      {
         double lots = CalculateLotSize(highTh, sellTh);
         VirtualPos.Active    = true;
         VirtualPos.Type      = OP_SELL;
         VirtualPos.OpenPrice = bid;
         VirtualPos.OpenTime  = TimeCurrent();
         VirtualPos.Lots      = lots;
         VirtualPos.UniqueID  = GenerateUniqueID();
         
         double priceDiffPips = (bid - sellTh) / tick / pipScale;
         
         LogTrade(
            "Virtual entry",
            "Sell",
            VirtualPos.OpenTime,
            slPips,
            lots,
            sellTh,
            bid,
            priceDiffPips,
            0,
            0,
            0,
            0,
            AccountBalance(),
            VirtualPos.UniqueID,
            0
         );
      }
      else
      {
         OpenRealPosition(OP_SELL, sellTh, highTh);
      }
   }
}

//+------------------------------------------------------------------+
//| 実ポジション建て                                                |
//+------------------------------------------------------------------+
int OpenRealPosition(int type, double threshold, double slThreshold)
{
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   int prec = 0;
   double tmp = lotStep;
   while(tmp < 1.0)
   {
      tmp *= 10.0;
      prec++;
   }

   double price = (type == OP_BUY) ? MarketInfo(Symbol(), MODE_ASK) : MarketInfo(Symbol(), MODE_BID);
   double lots  = CalculateLotSize(threshold, slThreshold);
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = NormalizeDouble(lots, prec);

   int ticket = -1;
   for(int r = 0; r < 3; r++)
   {
      RefreshRates();
      Sleep(100);
      price = (type == OP_BUY) ? MarketInfo(Symbol(), MODE_ASK) : MarketInfo(Symbol(), MODE_BID);
      ticket = OrderSend(Symbol(), type, lots, price, 3, 0, 0, "breaksPL101811", GetMagicNumber(), 0, clrGreen);
      if(ticket > 0) break;
      Sleep(500);
   }

   double bid = MarketInfo(Symbol(), MODE_BID);
   double ask = MarketInfo(Symbol(), MODE_ASK);
   double tick = GetTickSize();
   int pipScale = (Digits == 3 || Digits == 5) ? 10 : 1;
   double slPips = MathAbs(threshold - slThreshold) / tick / pipScale;

   if(ticket > 0)
   {
      double priceDiffPips = ((type == OP_BUY)
                              ? (threshold - price)
                              : (price - threshold)) / tick / pipScale;
      
      LogTrade(
         "Entry",
         (type == OP_BUY) ? "Buy" : "Sell",
         TimeCurrent(),
         slPips,
         lots,
         threshold,
         price,
         priceDiffPips,
         0,
         0,
         0,
         0,
         AccountBalance(),
         IntegerToString(ticket),
         0
      );
   }
   else
   {
      int err = GetLastError();
      LogTrade(
         "Entry",
         (type == OP_BUY) ? "Buy" : "Sell",
         TimeCurrent(),
         slPips,
         lots,
         threshold,
         price,
         0,
         0,
         0,
         0,
         0,
         AccountBalance(),
         "ERROR",
         err
      );
      LastTradeWasLoss = false;
   }
   return(ticket);
}

//+------------------------------------------------------------------+
//| 過去High閾値取得                                                |
//+------------------------------------------------------------------+
double GetHighThreshold(int BarsCount)
{
   double h = iHigh(Symbol(), 0, 1);
   for(int i = 2; i <= BarsCount; i++)
      h = MathMax(h, iHigh(Symbol(), 0, i));
   return(h);
}

//+------------------------------------------------------------------+
//| 過去Low閾値取得                                                 |
//+------------------------------------------------------------------+
double GetLowThreshold(int BarsCount)
{
   double l = iLow(Symbol(), 0, 1);
   for(int i = 2; i <= BarsCount; i++)
      l = MathMin(l, iLow(Symbol(), 0, i));
   return(l);
}

//+------------------------------------------------------------------+
//| ロット算出（口座資金の50%を基準）                               |
//+------------------------------------------------------------------+
double CalculateLotSize(double EntryPrice, double ExitPrice)
{
   double balance   = AccountBalance() * 0.5;
   double riskAmt   = balance * RiskPercent / 100.0;
   double tick      = GetTickSize();
   int pipScale     = (Digits == 3 || Digits == 5) ? 10 : 1;
   double stopPips  = MathAbs(EntryPrice - ExitPrice) / tick / pipScale;
   if(stopPips <= 0) stopPips = 10;
   
   double tickVal   = MarketInfo(Symbol(), MODE_TICKVALUE);
   double pipVal    = tickVal * pipScale;
   double lotsRisk  = riskAmt / (stopPips * pipVal);
   
   double marginReqBroker = MarketInfo(Symbol(), MODE_MARGINREQUIRED);
   double marginPerLot    = marginReqBroker * (MarginLimitPercent / 4.0);
   double freeMarg        = AccountFreeMargin() * 0.5;
   double lotsMarg        = (marginPerLot > 0) ? freeMarg / marginPerLot : lotsRisk;
   
   double minLot    = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot    = MarketInfo(Symbol(), MODE_MAXLOT);
   double result    = MathMin(lotsRisk, lotsMarg);
   result           = MathMax(result, minLot);
   result           = MathMin(result, maxLot);
   
   return result;
}

//+------------------------------------------------------------------+
//| ユニークID生成                                                  |
//+------------------------------------------------------------------+
string GenerateUniqueID()
{
   int    ms  = GetTickCount();
   string sym = Symbol();
   int    sum = 0;
   for(int i = 0; i < StringLen(sym); i++)
      sum += StringGetCharacter(sym, i);
   return "ID" + IntegerToString(sum) + "_" + IntegerToString(ms);
}

//+------------------------------------------------------------------+
//| Magic Number                                                    |
//+------------------------------------------------------------------+
int GetMagicNumber()
{
   return(100118);
}

//+------------------------------------------------------------------+
//| ティックサイズ取得（全資産クラス対応）                          |
//+------------------------------------------------------------------+
double GetTickSize()
{
   return MarketInfo(Symbol(), MODE_TICKSIZE);
}

//+------------------------------------------------------------------+
//| CSV初期化                                                       |
//+------------------------------------------------------------------+
void InitializeCSV()
{
   int handle = FileOpen(CSVFileName, FILE_READ);
   if(handle == INVALID_HANDLE)
   {
      handle = FileOpen(CSVFileName, FILE_WRITE);   
      if(handle != INVALID_HANDLE)
      {
         string header = "Type,Direction,DateTime,SL_Pips,Lots,Threshold," +
                        "ExecutionPrice,PriceDiffPips,PipsProfit," +
                        "Commission,Swap,NetProfit,Balance,ID,ErrorCode\n";
         FileWriteString(handle, header);
         FileClose(handle);
      }
   }
   else
      FileClose(handle);
}

//+------------------------------------------------------------------+
//| 過去バーを分析して状態復元                                       |
//+------------------------------------------------------------------+
void AnalyzeHistoricalBars()
{
   int totalBars = Bars(Symbol(), 0);
   int barsToAnalyze = MathMin(HistoryBars, totalBars - LookbackBars - 1);
   
   Print("起動時分析開始: totalBars=", totalBars, " barsToAnalyze=", barsToAnalyze);
   
   if(barsToAnalyze <= 0)
   {
      Print("起動時分析: 十分なバーがありません (totalBars=", totalBars, ")");
      return;
   }
   
   double tick = GetTickSize();
   int pipScale = (Digits == 3 || Digits == 5) ? 10 : 1;
   
   // 仮想的な取引履歴を再現
   bool inVirtualPosition = false;
   int virtualType = -1;
   double virtualOpenPrice = 0;
   int virtualOpenBar = 0;
   bool lastWasLoss = false;
   
   // 過去から現在に向かってバーをスキャン
   for(int bar = barsToAnalyze; bar >= 1; bar--)
   {
      // ポジション中でない場合、エントリーシグナルをチェック
      if(!inVirtualPosition)
      {
         if(bar <= LookbackBars) continue;
         
         double buyTh = 0, sellTh = 0;
         
         // bar時点でのエントリー閾値を計算
         buyTh = iHigh(Symbol(), 0, bar + 1);
         for(int i = bar + 2; i <= bar + LookbackBars; i++)
            buyTh = MathMax(buyTh, iHigh(Symbol(), 0, i));
            
         sellTh = iLow(Symbol(), 0, bar + 1);
         for(int i = bar + 2; i <= bar + LookbackBars; i++)
            sellTh = MathMin(sellTh, iLow(Symbol(), 0, i));
         
         double barHigh = iHigh(Symbol(), 0, bar);
         double barLow = iLow(Symbol(), 0, bar);
         double barClose = iClose(Symbol(), 0, bar);
         
         // Buyシグナル（High価格が閾値を超えた場合）
         if(barHigh >= buyTh)
         {
            if(!lastWasLoss)
            {
               // 仮想ポジションとしてエントリー
               inVirtualPosition = true;
               virtualType = OP_BUY;
               virtualOpenPrice = buyTh;
               virtualOpenBar = bar;
               Print("起動時分析: bar[", bar, "] で仮想Buyエントリー検出 (High=", barHigh, " >= buyTh=", buyTh, ")");
            }
            else
            {
               // 実ポジションが建つはずなので、このバーでクローズされたと仮定
               Print("起動時分析: bar[", bar, "] で実Buyエントリー&即決済（前回負けトレード後）");
               lastWasLoss = false;
            }
         }
         // Sellシグナル（Low価格が閾値を下回った場合）
         else if(barLow <= sellTh)
         {
            if(!lastWasLoss)
            {
               // 仮想ポジションとしてエントリー
               inVirtualPosition = true;
               virtualType = OP_SELL;
               virtualOpenPrice = sellTh;
               virtualOpenBar = bar;
               Print("起動時分析: bar[", bar, "] で仮想Sellエントリー検出 (Low=", barLow, " <= sellTh=", sellTh, ")");
            }
            else
            {
               // 実ポジションが建つはずなので、このバーでクローズされたと仮定
               Print("起動時分析: bar[", bar, "] で実Sellエントリー&即決済（前回負けトレード後）");
               lastWasLoss = false;
            }
         }
      }
      else
      {
         // ポジション中の場合、エグジット条件をチェック
         if(bar <= ExitLookbackBars) continue;
         
         double exitHighTh = iHigh(Symbol(), 0, bar + 1);
         for(int i = bar + 2; i <= bar + ExitLookbackBars; i++)
            exitHighTh = MathMax(exitHighTh, iHigh(Symbol(), 0, i));
            
         double exitLowTh = iLow(Symbol(), 0, bar + 1);
         for(int i = bar + 2; i <= bar + ExitLookbackBars; i++)
            exitLowTh = MathMin(exitLowTh, iLow(Symbol(), 0, i));
         
         double barHigh = iHigh(Symbol(), 0, bar);
         double barLow = iLow(Symbol(), 0, bar);
         bool shouldExit = false;
         
         if(virtualType == OP_BUY && barLow <= exitLowTh)
         {
            shouldExit = true;
            double profit = (exitLowTh - virtualOpenPrice) / tick / pipScale;
            lastWasLoss = (profit < 0);
            Print("起動時分析: bar[", bar, "] で仮想Buyエグジット検出 (Low=", barLow, " <= exitLowTh=", exitLowTh, " profit=", profit, "pips lastWasLoss=", lastWasLoss, ")");
         }
         else if(virtualType == OP_SELL && barHigh >= exitHighTh)
         {
            shouldExit = true;
            double profit = (virtualOpenPrice - exitHighTh) / tick / pipScale;
            lastWasLoss = (profit < 0);
            Print("起動時分析: bar[", bar, "] で仮想Sellエグジット検出 (High=", barHigh, " >= exitHighTh=", exitHighTh, " profit=", profit, "pips lastWasLoss=", lastWasLoss, ")");
         }
         
         if(shouldExit)
         {
            inVirtualPosition = false;
            virtualType = -1;
            virtualOpenPrice = 0;
            virtualOpenBar = 0;
         }
      }
   }
   
   // 現在の状態を設定
   LastTradeWasLoss = lastWasLoss;
   
   Print("起動時分析完了: inVirtualPosition=", inVirtualPosition, " virtualOpenBar=", virtualOpenBar, " LastTradeWasLoss=", lastWasLoss);
   
   // 現在ポジション中の場合
   if(inVirtualPosition)
   {
      // ポジション中と判定された場合、エグジット待ちフラグを立てる
      WaitingForExit = true;
      
      // 実ポジションが存在するか確認
      if(HasRealPosition())
      {
         Print("起動時分析: ポジション中です。実ポジションあり。エグジット条件を待ちます。WaitingForExit=true");
      }
      else
      {
         // 仮想ポジションを復元（現在価格でエントリーしたものとして扱う）
         double currentPrice = (virtualType == OP_BUY) ? MarketInfo(Symbol(), MODE_ASK) : MarketInfo(Symbol(), MODE_BID);
         
         VirtualPos.Active = true;
         VirtualPos.Type = virtualType;
         VirtualPos.OpenPrice = currentPrice;
         VirtualPos.OpenTime = iTime(Symbol(), 0, 1);
         VirtualPos.Lots = 0;  // ロット数は不明なので0に設定
         VirtualPos.UniqueID = "RESTORED_" + IntegerToString(GetTickCount());
         
         Print("起動時分析: 仮想ポジションを復元しました。Type=", (virtualType == OP_BUY ? "BUY" : "SELL"), " エグジット条件を待ちます。WaitingForExit=true");
      }
   }
   else
   {
      // ポジション中でない場合
      WaitingForExit = false;
      
      if(HasRealPosition())
      {
         Print("起動時分析: 待機状態ですが実ポジションが存在します。エグジット条件を待ちます。WaitingForExit=true");
         WaitingForExit = true;
      }
      else
      {
         Print("起動時分析: エントリー待機状態。LastTradeWasLoss=", lastWasLoss, " WaitingForExit=false");
      }
   }
}

//+------------------------------------------------------------------+
//| ログ出力                                                        |
//+------------------------------------------------------------------+
void LogTrade(
   string  Type,
   string  Direction,
   datetime TradeTime,
   double  SL_Pips,
   double  Lots,
   double  Threshold,
   double  ExecPrice,
   double  PriceDiffPips,
   double  PipsProfit,
   double  Commission,
   double  Swap,
   double  NetProfit,
   double  Balance,
   string  ID,
   int     ErrorCode
)
{
   int handle = FileOpen(CSVFileName, FILE_READ|FILE_WRITE);
   if(handle == INVALID_HANDLE) return;
   FileSeek(handle, 0, SEEK_END);
   
   string errStr = (ErrorCode == 0) ? "" : IntegerToString(ErrorCode);
   
   string csvLine = Type + "," +
                    Direction + "," +
                    TimeToString(TradeTime, TIME_DATE|TIME_SECONDS) + "," +
                    StringFormat("%.1f", SL_Pips) + "," +
                    DoubleToString(Lots, 2) + "," +
                    DoubleToString(Threshold, Digits) + "," +
                    DoubleToString(ExecPrice, Digits) + "," +
                    StringFormat("%.1f", PriceDiffPips) + "," +
                    StringFormat("%.1f", PipsProfit) + "," +
                    DoubleToString(Commission, 2) + "," +
                    DoubleToString(Swap, 2) + "," +
                    DoubleToString(NetProfit, 2) + "," +
                    DoubleToString(Balance, 2) + "," +
                    ID + "," +
                    errStr + "\n";
   
   FileWriteString(handle, csvLine);
   
   if(StringFind(Type, "exit") >= 0 || StringFind(Type, "Exit") >= 0)
   {
      string separator = "--------,--------,--------,--------,--------," +
                        "--------,--------,--------,--------,--------," +
                        "--------,--------,--------,--------,--------\n";
      FileWriteString(handle, separator);
   }
   
   FileClose(handle);
}
//+------------------------------------------------------------------+
