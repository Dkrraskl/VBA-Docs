//+------------------------------------------------------------------+
//|                                     Institutional_Hybrid_EA.mq5 |
//|                        Copyright 2023, Senior Financial Architect |
//|                                             Jules AI Assistant |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Senior Financial Architect"
#property link      "https://github.com/metaquotes"
#property version   "1.06" // Sintaxis de punto y mejoras de código
#property strict

#include <Trade\Trade.mqh>
#include <Arrays\ArrayObj.mqh>

// --- Guardia de Preprocesador para el Calendario Económico ---
#ifdef USE_CALENDAR_FILTER
#include <EconomicCalendar\EconomicCalendar.mqh>
#endif

//--- Declaración de Clases (Forward Declaration)
class CData_Logger;
class CRisk_Manager;
class CVolatility_Filter;
class CKillzone_Filter;
class CICT_Analyzer;
class CBrooks_Executor;

//--- Estructuras de Datos
enum AssetClass { FOREX, CRYPTO, METAL, GENERIC };
enum MarketRegime { REGIME_UPTREND, REGIME_DOWNTREND, REGIME_RANGE };

struct AssetProfile
{
    bool use_killzones;
    double atr_sl_multiplier;
};

struct FairValueGap
{
    double top_edge;
    double bottom_edge;
    datetime time_start;
    datetime time_end;
    bool is_bullish;
    bool is_active;

    void Reset()
    {
        top_edge = 0; bottom_edge = 0;
        time_start = 0; time_end = 0;
        is_bullish = false; is_active = false;
    }
};

//+------------------------------------------------------------------+
//|  Parámetros de Entrada del Expert Advisor                        |
//+------------------------------------------------------------------+
input group "Filtro de Calendario Económico"
input bool InpUseCalendarFilter = true;
input int  InpEmbargoMinutes = 30;
input bool InpFilterHighImpact = true;
input bool InpFilterMediumImpact = false;
input bool InpFilterLowImpact = false;

input group "Gestión de Riesgo"
input double InpRiskPercent = 0.5;

input group "Gestión de Salida Dinámica (Trailing Stop)"
input bool   InpUseTrailingStop = true;
input double InpTrailingStopActivationR = 1.0;
input double InpTrailingStopAtrMultiplier = 2.5;

input group "Filtro de Horario (Killzones)"
input int    InpLondonKillzoneStart   = 9;
input int    InpLondonKillzoneEnd     = 12;
input int    InpNewYorkKillzoneStart  = 15;
input int    InpNewYorkKillzoneEnd    = 18;

input group "Filtro de Volatilidad y Spread"
input int    InpAtrPeriod = 14;
input double InpMaxSpreadAtrRatio = 0.1;
input double InpMinFvgAtrRatio = 0.5;

input group "Parámetros de Indicadores (ICT)"
input int    InpZigZagDepth = 12;
input int    InpZigZagDeviation = 5;
input int    InpZigZagBackstep = 3;

input group "Gestión de Órdenes"
input ulong  InpMagicNumber = 13579;
input int    InpSlippage = 3;
input string InpCsvLogFileName = "TradeLog_Institutional_Hybrid.csv";

input group "Filtro de Régimen de Mercado (Tendencia)"
input bool InpUseTrendFilter = true;
input int  InpTrendEmaPeriod = 200;

//+------------------------------------------------------------------+
//|  Variables Globales y Objetos                                    |
//+------------------------------------------------------------------+
CTrade              trade;
CData_Logger       *g_logger;
CRisk_Manager      *g_risk;
CVolatility_Filter *g_volatility;
CKillzone_Filter   *g_killzone;
CICT_Analyzer      *g_ict;
CBrooks_Executor   *g_brooks;

int      g_handle_atr;
int      g_handle_zigzag;
int      g_handle_ema_trend;

enum EA_State { BUSCANDO_SETUP_ICT, MONITOREANDO_FVG, FILTRADO };
EA_State g_current_state = FILTRADO;

datetime g_last_bar_time = 0;
FairValueGap g_active_fvg;
AssetProfile g_profile;

//+------------------------------------------------------------------+
//| Funciones de Ayuda (Prototipos)                                  |
//+------------------------------------------------------------------+
bool IsNearHighImpactNews();
void AdjustStopsToBrokerLimits(double entry, double &sl, double &tp, bool is_buy);
MarketRegime GetMarketRegime();

//+------------------------------------------------------------------+
//| Implementación de Clases y Funciones                             |
//+------------------------------------------------------------------+
void LoadAssetProfile()
{
    string symbol_name = _Symbol; StringToUpper(symbol_name);
    AssetClass asset_class = GENERIC;
    if(StringFind(symbol_name, "BTC") >= 0 || StringFind(symbol_name, "ETH") >= 0) asset_class = CRYPTO;
    else if(StringFind(symbol_name, "XAU") >= 0 || StringFind(symbol_name, "XAG") >= 0) asset_class = METAL;
    else if(StringLen(symbol_name) == 6) asset_class = FOREX;

    switch(asset_class) {
        case CRYPTO: g_profile.use_killzones = false; g_profile.atr_sl_multiplier = 2.5; break;
        case METAL: g_profile.use_killzones = true; g_profile.atr_sl_multiplier = 3.0; break;
        default: g_profile.use_killzones = true; g_profile.atr_sl_multiplier = 2.0; break;
    }
}

class CData_Logger
{
private:
    string m_file_name;
    int    m_file_handle;
    string m_delimiter;

public:
    CData_Logger(string file_name, string delimiter = ",");
   ~CData_Logger();

    bool OpenFile();
    void CloseFile();
    void LogTrade(
        string signal_type,
        string trade_direction,
        double entry_price,
        double stop_loss,
        double take_profit,
        double lot_size,
        double spread_quote_currency,
        double atr,
        string result,
        string quote_currency);
};

CData_Logger::CData_Logger(string file_name, string delimiter = ",")
{
    m_file_name = file_name;
    m_delimiter = delimiter;
    m_file_handle = INVALID_HANDLE;
}

CData_Logger::~CData_Logger()
{
    CloseFile();
}

bool CData_Logger::OpenFile()
{
    m_file_handle = FileOpen(m_file_name, FILE_WRITE | FILE_CSV | FILE_ANSI, m_delimiter);
    if(m_file_handle == INVALID_HANDLE)
    {
        PrintFormat("Error abriendo el archivo de log: %d", GetLastError());
        return false;
    }

    if(FileSize(m_file_handle) == 0)
    {
        FileWrite(m_file_handle,
                  "Timestamp", "Symbol", "Quote_Currency", "SignalType", "Direction",
                  "EntryPrice", "StopLoss", "TakeProfit", "LotSize", "Spread_QuoteCurrency", "ATR", "Result");
    }
    return true;
}

void CData_Logger::CloseFile()
{
    if(m_file_handle != INVALID_HANDLE)
    {
        FileClose(m_file_handle);
        m_file_handle = INVALID_HANDLE;
    }
}

void CData_Logger::LogTrade(string signal_type, string trade_direction, double entry_price,
                            double stop_loss, double take_profit, double lot_size,
                            double spread_quote_currency, double atr, string result, string quote_currency)
{
    if(m_file_handle == INVALID_HANDLE) return;

    FileSeek(m_file_handle, 0, SEEK_END);
    FileWrite(m_file_handle,
              TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
              _Symbol,
              quote_currency,
              signal_type,
              trade_direction,
              DoubleToString(entry_price, (int)_Digits),
              DoubleToString(stop_loss, (int)_Digits),
              DoubleToString(take_profit, (int)_Digits),
              DoubleToString(lot_size, 8),
              DoubleToString(spread_quote_currency, (int)_Digits),
              DoubleToString(atr, (int)_Digits),
              result);
}

class CRisk_Manager
{
private:
    double m_risk_percent;

public:
    CRisk_Manager(double risk_percent);
    double CalculateLotSize(double stop_loss_pips);
};

CRisk_Manager::CRisk_Manager(double risk_percent)
{
    m_risk_percent = risk_percent / 100.0;
}

double CRisk_Manager::CalculateLotSize(double stop_loss_pips)
{
    if(stop_loss_pips <= 0) return 0.01;

    double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_amount = account_balance * m_risk_percent;
    double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(tick_value <= 0 || tick_size <= 0)
    {
        PrintFormat("Valor de tick (%.5f) o tamaño de tick (%.5f) inválido para el símbolo %s. No se puede calcular el lotaje.", tick_value, tick_size, _Symbol);
        return 0.0;
    }

    double loss_per_lot = (stop_loss_pips * _Point) * (tick_value / tick_size);

    if(loss_per_lot <= 0) return 0.01;

    double lots = risk_amount / loss_per_lot;

    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lots = fmax(lots, min_lot);
    lots = fmin(lots, max_lot);
    lots = floor(lots / step_lot) * step_lot;

    return lots;
}

class CVolatility_Filter
{
private:
    int    m_atr_handle;
    double m_max_spread_ratio;

public:
    CVolatility_Filter(int atr_handle, double max_spread_ratio);
    double GetATR(int shift = 1);
    bool   IsSpreadValid();
};

CVolatility_Filter::CVolatility_Filter(int atr_handle, double max_spread_ratio)
{
    m_atr_handle = atr_handle;
    m_max_spread_ratio = max_spread_ratio;
}

double CVolatility_Filter::GetATR(int shift = 1)
{
    if(m_atr_handle == INVALID_HANDLE) return 0.0;
    double atr_buffer[1];
    if(CopyBuffer(m_atr_handle, 0, shift, 1, atr_buffer) > 0)
    {
        return atr_buffer[0];
    }
    return 0.0;
}

bool CVolatility_Filter::IsSpreadValid()
{
    double current_spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
    double atr = GetATR();
    if(atr <= 0) return false;

    return current_spread <= (atr * m_max_spread_ratio);
}

class CKillzone_Filter
{
private:
    int m_london_start;
    int m_london_end;
    int m_ny_start;
    int m_ny_end;

public:
    CKillzone_Filter(int lon_start, int lon_end, int ny_start, int ny_end);
    bool IsInKillzone();
};

CKillzone_Filter::CKillzone_Filter(int lon_start, int lon_end, int ny_start, int ny_end)
{
    m_london_start = lon_start;
    m_london_end = lon_end;
    m_ny_start = ny_start;
    m_ny_end = ny_end;
}

bool CKillzone_Filter::IsInKillzone()
{
    MqlDateTime current_time;
    TimeCurrent(current_time);
    int hour = current_time.hour;

    bool is_london = (hour >= m_london_start && hour < m_london_end);
    bool is_newyork = (hour >= m_ny_start && hour < m_ny_end);

    return is_london || is_newyork;
}

class CICT_Analyzer
{
private:
    int    m_zigzag_handle;
    double m_min_fvg_atr_ratio;

public:
    CICT_Analyzer(int zigzag_handle, double min_fvg_atr_ratio);
    bool FindSetup(FairValueGap &fvg_out);
};

CICT_Analyzer::CICT_Analyzer(int zigzag_handle, double min_fvg_atr_ratio)
{
    m_zigzag_handle = zigzag_handle;
    m_min_fvg_atr_ratio = min_fvg_atr_ratio;
}

bool CICT_Analyzer::FindSetup(FairValueGap &fvg_out)
{
    double zigzag_values[];
    if(CopyBuffer(m_zigzag_handle, 0, 0, 100, zigzag_values) < 3) return false;

    ArraySetAsSeries(zigzag_values, true);

    double last_extrema[3];
    int extrema_pos[3];
    int count = 0;
    for(int i = 0; i < 100 && count < 3; i++)
    {
        if(zigzag_values[i] > 0)
        {
            last_extrema[count] = zigzag_values[i];
            extrema_pos[count] = i;
            count++;
        }
    }
    if(count < 3) return false;

    double p0 = last_extrema[0]; int pos0 = extrema_pos[0];
    double p1 = last_extrema[1]; int pos1 = extrema_pos[1];
    double p2 = last_extrema[2];

    bool is_bullish_mss = (p2 > p1 && p0 > p2);
    bool is_bearish_mss = (p2 < p1 && p0 < p2);

    if(!is_bullish_mss && !is_bearish_mss) return false;

    MqlRates candles[];
    int candles_to_copy = pos1 + 2;
    if(CopyRates(_Symbol, _Period, 0, candles_to_copy, candles) < candles_to_copy) return false;
    ArraySetAsSeries(candles, true);

    double min_fvg_size = g_volatility.GetATR(pos0) * m_min_fvg_atr_ratio;
    if(min_fvg_size <= 0) return false;

    for(int i = pos0 + 1; i < pos1 - 1; i++)
    {
        if(is_bullish_mss && candles[i].high < candles[i+2].low)
        {
            double fvg_size = candles[i+2].low - candles[i].high;
            if(fvg_size >= min_fvg_size)
            {
                fvg_out.is_bullish = true; fvg_out.top_edge = candles[i+2].low; fvg_out.bottom_edge = candles[i].high;
                fvg_out.time_start = candles[i+2].time; fvg_out.time_end = candles[i].time; fvg_out.is_active = true;
                return true;
            }
        }
        else if(is_bearish_mss && candles[i].low > candles[i+2].high)
        {
            double fvg_size = candles[i].low - candles[i+2].high;
            if(fvg_size >= min_fvg_size)
            {
                fvg_out.is_bullish = false; fvg_out.top_edge = candles[i].low; fvg_out.bottom_edge = candles[i+2].high;
                fvg_out.time_start = candles[i+2].time; fvg_out.time_end = candles[i].time; fvg_out.is_active = true;
                return true;
            }
        }
    }
    return false;
}

class CBrooks_Executor
{
public:
    CBrooks_Executor();
    bool FindSignalBarAndPlaceOrder(FairValueGap &fvg, double atr);
};

CBrooks_Executor::CBrooks_Executor() {}

bool CBrooks_Executor::FindSignalBarAndPlaceOrder(FairValueGap &fvg, double atr)
{
    MqlRates candles[3]; if(CopyRates(_Symbol, _Period, 0, 3, candles) < 3) return false;
    ArraySetAsSeries(candles, true);
    MqlRates signal_candle = candles[1];

    bool price_in_fvg = fvg.is_bullish ? (signal_candle.low <= fvg.top_edge) : (signal_candle.high >= fvg.bottom_edge);
    if(!price_in_fvg) return false;

    MqlRates past_candles[21]; if(CopyRates(_Symbol, _Period, 1, 21, past_candles) < 21) return false;
    double avg_range = 0;
    for(int i = 0; i < 20; i++) avg_range += past_candles[i].high - past_candles[i].low;
    avg_range /= 20.0;

    double signal_candle_range = signal_candle.high - signal_candle.low;
    if (signal_candle_range <= avg_range) return false;

    bool is_bullish_signal = (signal_candle.close > signal_candle.open && (signal_candle.close - signal_candle.open) >= signal_candle_range * 0.3 && signal_candle.close > (signal_candle.high + signal_candle.low) / 2);
    bool is_bearish_signal = (signal_candle.close < signal_candle.open && (signal_candle.open - signal_candle.close) >= signal_candle_range * 0.3 && signal_candle.close < (signal_candle.high + signal_candle.low) / 2);

    if(fvg.is_bullish && is_bullish_signal)
    {
        double entry_price = signal_candle.high;
        double stop_loss = signal_candle.low - (atr * g_profile.atr_sl_multiplier);
        double take_profit = 0;
        AdjustStopsToBrokerLimits(entry_price, stop_loss, take_profit, true);
        double sl_pips = (entry_price - stop_loss) / _Point;
        double lot_size = g_risk.CalculateLotSize(sl_pips);
        if(trade.BuyStop(lot_size, entry_price, _Symbol, stop_loss, take_profit, 0, 0, "Buy Stop")) {
            g_logger.LogTrade("ICT+Brooks", "BUY", entry_price, stop_loss, take_profit, lot_size, SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, atr, "Placed", SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT));
            return true;
        }
    }
    else if(!fvg.is_bullish && is_bearish_signal)
    {
        double entry_price = signal_candle.low;
        double stop_loss = signal_candle.high + (atr * g_profile.atr_sl_multiplier);
        double take_profit = 0;
        AdjustStopsToBrokerLimits(entry_price, stop_loss, take_profit, false);
        double sl_pips = (stop_loss - entry_price) / _Point;
        double lot_size = g_risk.CalculateLotSize(sl_pips);
        if(trade.SellStop(lot_size, entry_price, _Symbol, stop_loss, take_profit, 0, 0, "Sell Stop")) {
            g_logger.LogTrade("ICT+Brooks", "SELL", entry_price, stop_loss, take_profit, lot_size, SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point, atr, "Placed", SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT));
            return true;
        }
    }
    return false;
}

int OnInit()
{
    LoadAssetProfile();
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetMarginMode();
    trade.SetSlippage(InpSlippage);
    string log_name = StringFormat("%s_%s_M%d.csv", StringSubstr(InpCsvLogFileName, 0, StringLen(InpCsvLogFileName) - 4), _Symbol, (int)_Period);
    g_logger = new CData_Logger(log_name);
    if(!g_logger.OpenFile()) return INIT_FAILED;
    g_risk = new CRisk_Manager(InpRiskPercent);
    g_killzone = new CKillzone_Filter(InpLondonKillzoneStart, InpLondonKillzoneEnd, InpNewYorkKillzoneStart, InpNewYorkKillzoneEnd);
    g_handle_atr = iATR(_Symbol, _Period, InpAtrPeriod); if(g_handle_atr == INVALID_HANDLE) return INIT_FAILED;
    g_handle_zigzag = iZigZag(_Symbol, _Period, InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep); if(g_handle_zigzag == INVALID_HANDLE) return INIT_FAILED;
    g_handle_ema_trend = iMA(_Symbol, _Period, InpTrendEmaPeriod, 0, MODE_EMA, PRICE_CLOSE); if(g_handle_ema_trend == INVALID_HANDLE) return INIT_FAILED;
    g_volatility = new CVolatility_Filter(g_handle_atr, InpMaxSpreadAtrRatio);
    g_ict = new CICT_Analyzer(g_handle_zigzag, InpMinFvgAtrRatio);
    g_brooks = new CBrooks_Executor();
    g_active_fvg.Reset();
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
    Comment("");
    if(CheckPointer(g_logger) == POINTER_DYNAMIC) { delete g_logger; g_logger = NULL; }
    if(CheckPointer(g_risk) == POINTER_DYNAMIC) { delete g_risk; g_risk = NULL; }
    if(CheckPointer(g_volatility) == POINTER_DYNAMIC) { delete g_volatility; g_volatility = NULL; }
    if(CheckPointer(g_killzone) == POINTER_DYNAMIC) { delete g_killzone; g_killzone = NULL; }
    if(CheckPointer(g_ict) == POINTER_DYNAMIC) { delete g_ict; g_ict = NULL; }
    if(CheckPointer(g_brooks) == POINTER_DYNAMIC) { delete g_brooks; g_brooks = NULL; }
    IndicatorRelease(g_handle_atr);
    IndicatorRelease(g_handle_zigzag);
    IndicatorRelease(g_handle_ema_trend);
}

void OnTick()
{
    ManageOpenPositions();
    if(IsNewBar())
    {
        if(IsNearHighImpactNews()) { g_current_state = FILTRADO; return; }
        if(IsTradeOpenForThisEA()) return;
        if(g_profile.use_killzones && !g_killzone.IsInKillzone()) { g_current_state = FILTRADO; return; }
        if(!g_volatility.IsSpreadValid()) { g_current_state = FILTRADO; return; }

        MarketRegime regime = GetMarketRegime();
        if(!g_active_fvg.is_active)
        {
            g_current_state = BUSCANDO_SETUP_ICT;
            if(g_ict.FindSetup(g_active_fvg))
            {
                if(InpUseTrendFilter && ((regime == REGIME_UPTREND && !g_active_fvg.is_bullish) || (regime == REGIME_DOWNTREND && g_active_fvg.is_bullish)))
                {
                    g_active_fvg.Reset();
                }
            }
        }
        if(g_active_fvg.is_active)
        {
            g_current_state = MONITOREANDO_FVG;
            if(g_brooks.FindSignalBarAndPlaceOrder(g_active_fvg, g_volatility.GetATR()))
            {
                g_active_fvg.Reset();
                g_current_state = BUSCANDO_SETUP_ICT;
            }
            else
            {
                MqlRates candle[1]; CopyRates(_Symbol, _Period, 0, 1, candle);
                if((g_active_fvg.is_bullish && candle[0].low < g_active_fvg.bottom_edge) || (!g_active_fvg.is_bullish && candle[0].high > g_active_fvg.top_edge))
                {
                   g_active_fvg.Reset();
                   CancelPendingOrders();
                   g_current_state = BUSCANDO_SETUP_ICT;
                }
            }
        }
    }
}

MarketRegime GetMarketRegime()
{
    if(!InpUseTrendFilter) return REGIME_RANGE;
    double ema[2]; if(CopyBuffer(g_handle_ema_trend, 0, 1, 2, ema) < 2) return REGIME_RANGE;
    MqlRates price[1]; if(CopyRates(_Symbol, _Period, 0, 1, price) < 1) return REGIME_RANGE;
    if(price[0].close > ema[0] && ema[0] > ema[1]) return REGIME_UPTREND;
    if(price[0].close < ema[0] && ema[0] < ema[1]) return REGIME_DOWNTREND;
    return REGIME_RANGE;
}

bool IsTradeOpenForThisEA()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) return true;
    }
    return false;
}

void ManageOpenPositions()
{
    if(!InpUseTrailingStop) return;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
            long ticket = PositionGetTicket(i);
            double open = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);
            long type = PositionGetInteger(POSITION_TYPE);
            double risk_points = (type == POSITION_TYPE_BUY) ? (open - sl) : (sl - open);
            if(risk_points <= 0) continue;
            double price = SymbolInfoDouble(_Symbol, type == POSITION_TYPE_BUY ? SYMBOL_BID : SYMBOL_ASK);
            double profit_points = (type == POSITION_TYPE_BUY) ? (price - open) : (open - price);
            if(profit_points / risk_points >= InpTrailingStopActivationR)
            {
                double new_sl;
                if(type == POSITION_TYPE_BUY) {
                    new_sl = price - (g_volatility.GetATR(0) * InpTrailingStopAtrMultiplier);
                    if(InpTrailingStopActivationR == 1.0) new_sl = fmax(new_sl, open);
                } else {
                    new_sl = price + (g_volatility.GetATR(0) * InpTrailingStopAtrMultiplier);
                    if(InpTrailingStopActivationR == 1.0) new_sl = fmin(new_sl, open);
                }
                if((type == POSITION_TYPE_BUY && new_sl > sl) || (type == POSITION_TYPE_SELL && new_sl < sl)) {
                    trade.PositionModify(ticket, new_sl, tp);
                }
            }
        }
    }
}

void AdjustStopsToBrokerLimits(double entry, double &sl, double &tp, bool is_buy)
{
    double level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(is_buy) {
        if(sl > 0 && entry - sl < level) sl = entry - level;
        if(tp > 0 && tp - entry < level) tp = entry + level;
    } else {
        if(sl > 0 && sl - entry < level) sl = entry + level;
        if(tp > 0 && entry - tp < level) tp = entry - level;
    }
}

void CancelPendingOrders()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if(OrderSelect(ticket) && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol) {
            trade.OrderDelete(ticket);
        }
    }
}

bool IsNewBar()
{
    datetime time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
    if(g_last_bar_time < time) {
        g_last_bar_time = time;
        return true;
    }
    return false;
}

bool IsNearHighImpactNews()
{
#ifdef USE_CALENDAR_FILTER
    if(!InpUseCalendarFilter) return false;

    datetime now = TimeCurrent();
    datetime from = now - (now % 86400);
    datetime to = from + 86400 - 1;

    if(!TerminalInfoInteger(TERMINAL_CALENDAR_EVENTS))
    {
       PrintFormat("Error: Habilite 'Eventos del Calendario' en las opciones (Herramientas -> Opciones -> Gráficos).");
       return false;
    }

    long embargo_seconds = InpEmbargoMinutes * 60;
    string currency1 = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
    string currency2 = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_MARGIN);

    CArrayObj* news_array = CalendarValueHistory(from, to);
    if(CheckPointer(news_array) == POINTER_INVALID) return false;

    for(int i = 0; i < news_array->Total(); i++)
    {
        CCalendarValue* event = news_array->At(i);
        if(CheckPointer(event) == POINTER_INVALID) continue;

        if(StringFind(event->GetCurrency(), currency1) < 0 && StringFind(event->GetCurrency(), currency2) < 0) continue;

        bool impact_check = (InpFilterHighImpact && event->GetImportance() == CALENDAR_IMPORTANCE_HIGH) ||
                            (InpFilterMediumImpact && event->GetImportance() == CALENDAR_IMPORTANCE_MODERATE) ||
                            (InpFilterLowImpact && event->GetImportance() == CALENDAR_IMPORTANCE_LOW);

        if(!impact_check) continue;

        datetime event_time = event->GetTime();
        if(now >= event_time - embargo_seconds && now <= event_time + embargo_seconds)
        {
            PrintFormat("ALERTA: Embargo de noticias activo. Evento: %s", event->GetEvent());
            delete news_array;
            return true;
        }
    }

    delete news_array;
#endif

    return false;
}