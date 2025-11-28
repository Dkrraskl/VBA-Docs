//+------------------------------------------------------------------+
//|                                     Institutional_Hybrid_EA.mq5 |
//|                        Copyright 2023, Senior Financial Architect |
//|                                             Jules AI Assistant |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Senior Financial Architect"
#property link      "https://github.com/metaquotes"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Declaración de Clases (Forward Declaration)
class CData_Logger;
class CRisk_Manager;
class CVolatility_Filter;
class CKillzone_Filter;
class CICT_Analyzer;
class CBrooks_Executor;

//--- Estructuras de Datos
struct FairValueGap
{
    double top_edge;       // Borde superior del FVG
    double bottom_edge;    // Borde inferior del FVG
    datetime time_start;   // Tiempo de la primera vela
    datetime time_end;     // Tiempo de la tercera vela
    bool is_bullish;       // True si es un FVG alcista (esperando compras), False si es bajista
    bool is_active;        // Estado del FVG

    void Reset()
    {
        top_edge = 0;
        bottom_edge = 0;
        time_start = 0;
        time_end = 0;
        is_bullish = false;
        is_active = false;
    }
};

//+------------------------------------------------------------------+
//|  Parámetros de Entrada del Expert Advisor                        |
//+------------------------------------------------------------------+
input group "Gestión de Riesgo"
input double InpRiskPercent = 0.5;              // Porcentaje de riesgo por operación
input double InpMinRewardRatio = 2.0;           // Ratio mínimo de Recompensa/Riesgo

input group "Filtro de Horario (Killzones)"
input int    InpLondonKillzoneStart   = 9;      // Hora de inicio Killzone Londres (GMT+2/3)
input int    InpLondonKillzoneEnd     = 12;     // Hora de fin Killzone Londres
input int    InpNewYorkKillzoneStart  = 15;     // Hora de inicio Killzone Nueva York
input int    InpNewYorkKillzoneEnd    = 18;     // Hora de fin Killzone Nueva York

input group "Filtro de Volatilidad y Spread"
input int    InpAtrPeriod = 14;                 // Período del ATR
input double InpMaxSpreadAtrRatio = 0.1;        // Ratio Máximo de Spread vs ATR (e.g., 0.1 = 10%)
input double InpMinFvgAtrRatio = 0.5;           // Ratio Mínimo: Tamaño FVG vs ATR

input group "Parámetros de Indicadores (ICT)"
input int    InpZigZagDepth = 12;
input int    InpZigZagDeviation = 5;
input int    InpZigZagBackstep = 3;

input group "Gestión de Órdenes"
input ulong  InpMagicNumber = 13579;            // Número Mágico para las órdenes
input int    InpSlippage = 3;                   // Deslizamiento máximo permitido
input string InpCsvLogFileName = "TradeLog_Institutional_Hybrid.csv"; // Nombre del archivo de log

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

//--- Manejadores de indicadores
int      g_handle_atr;
int      g_handle_zigzag;

//--- Máquina de Estados y Panel
enum EA_State
{
    BUSCANDO_SETUP_ICT, // Buscando Barrida + MSS + FVG
    MONITOREANDO_FVG,   // Esperando retroceso al FVG y vela señal
    FILTRADO            // En espera por horario o spread
};
EA_State g_current_state = FILTRADO; // Estado inicial

//--- Variables de estado
datetime g_last_bar_time = 0;
FairValueGap g_active_fvg;


//+------------------------------------------------------------------+
//| Clase CData_Logger: Gestiona el registro de datos en CSV         |
//+------------------------------------------------------------------+
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
        Print("Error abriendo el archivo de log: ", GetLastError());
        return false;
    }

    // Escribir cabecera si el archivo es nuevo (tamaño 0)
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
              DoubleToString(entry_price, _Digits),
              DoubleToString(stop_loss, _Digits),
              DoubleToString(take_profit, _Digits),
              DoubleToString(lot_size, 8), // Mayor precisión para cripto
              DoubleToString(spread_quote_currency, _Digits),
              DoubleToString(atr, _Digits),
              result);
}

//+------------------------------------------------------------------+
//| Clase CRisk_Manager: Calcula el tamaño del lote                  |
//+------------------------------------------------------------------+
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
        Print("Valor de tick o tamaño de tick inválido. No se puede calcular el lotaje.");
        return 0.0;
    }

    // Fórmula estándar para calcular el valor monetario de la pérdida por lote.
    // (stop_loss_pips * _Point) es la distancia del SL en precio.
    // (tick_value / tick_size) es el valor monetario por unidad de precio.
    double loss_per_lot = (stop_loss_pips * _Point) * (tick_value / tick_size);

    if(loss_per_lot <= 0) return 0.01;

    double lots = risk_amount / loss_per_lot;

    // Normalizar y ajustar a los límites de lote
    double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lots = fmax(lots, min_lot);
    lots = fmin(lots, max_lot);
    lots = floor(lots / step_lot) * step_lot;

    return lots;
}

//+------------------------------------------------------------------+
//| Clase CVolatility_Filter: Filtros de ATR y Spread                |
//+------------------------------------------------------------------+
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
    double atr_buffer[];
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

//+------------------------------------------------------------------+
//| Clase CKillzone_Filter: Filtra operaciones por sesión            |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Clase CICT_Analyzer: Lógica Macro de ICT                         |
//+------------------------------------------------------------------+
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
    // 1. Obtener los últimos 3 puntos del ZigZag
    double zigzag_values[];
    if(CopyBuffer(m_zigzag_handle, 0, 0, 100, zigzag_values) < 3) return false;

    double last_extrema[3];
    int extrema_pos[3];
    int count = 0;
    for(int i = 99; i >= 0 && count < 3; i--)
    {
        if(zigzag_values[i] > 0)
        {
            last_extrema[count] = zigzag_values[i];
            extrema_pos[count] = i;
            count++;
        }
    }
    if(count < 3) return false;

    // Notación: Extremo 0 es el más reciente, 1 el anterior, 2 el antepasado.
    double p0 = last_extrema[0]; int pos0 = extrema_pos[0];
    double p1 = last_extrema[1]; int pos1 = extrema_pos[1];
    double p2 = last_extrema[2]; int pos2 = extrema_pos[2];

    // 2. Detectar Liquidity Sweep y Market Structure Shift (MSS)
    bool is_bullish_mss = false; // Buscando compras
    bool is_bearish_mss = false; // Buscando ventas

    // MSS Bajista: Se barre un máximo (p1 > p2) y luego se rompe el mínimo intermedio (p0 < p1).
    if (p1 > p0 && p1 > p2 && p0 < p2)
    {
        // p1 es un máximo, p0 es un mínimo más bajo que el mínimo anterior p2
        is_bearish_mss = true;
    }
    // MSS Alcista: Se barre un mínimo (p1 < p2) y luego se rompe el máximo intermedio (p0 > p1).
    else if (p1 < p0 && p1 < p2 && p0 > p2)
    {
        // p1 es un mínimo, p0 es un máximo más alto que el máximo anterior p2
        is_bullish_mss = true;
    }

    if(!is_bullish_mss && !is_bearish_mss) return false;

    // 3. Buscar Fair Value Gap (FVG) en el movimiento impulsivo (entre pos1 y pos0)
    MqlRates candles[];
    int candles_to_copy = pos1 - pos0 + 3; // +3 para margen
    if(CopyRates(_Symbol, _Period, pos0, candles_to_copy, candles) < candles_to_copy) return false;

    double min_fvg_size = g_volatility->GetATR(pos0) * m_min_fvg_atr_ratio;
    if(min_fvg_size <= 0) return false;

    for(int i = ArraySize(candles) - 3; i >= 1; i--)
    {
        // FVG Bajista (para setups de Venta)
        if(is_bearish_mss && candles[i].low > candles[i+2].high)
        {
            double fvg_size = candles[i].low - candles[i+2].high;
            if(fvg_size >= min_fvg_size)
            {
                fvg_out.is_bullish = false;
                fvg_out.top_edge = candles[i].low;
                fvg_out.bottom_edge = candles[i+2].high;
                fvg_out.time_start = candles[i+2].time;
                fvg_out.time_end = candles[i].time;
                fvg_out.is_active = true;
                Print("FVG Bajista Encontrado. Top: ", fvg_out.top_edge, " Bottom: ", fvg_out.bottom_edge);
                return true;
            }
        }
        // FVG Alcista (para setups de Compra)
        else if(is_bullish_mss && candles[i].high < candles[i+2].low)
        {
            double fvg_size = candles[i+2].low - candles[i].high;
            if(fvg_size >= min_fvg_size)
            {
                fvg_out.is_bullish = true;
                fvg_out.top_edge = candles[i+2].low;
                fvg_out.bottom_edge = candles[i].high;
                fvg_out.time_start = candles[i+2].time;
                fvg_out.time_end = candles[i].time;
                fvg_out.is_active = true;
                Print("FVG Alcista Encontrado. Top: ", fvg_out.top_edge, " Bottom: ", fvg_out.bottom_edge);
                return true;
            }
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| Clase CBrooks_Executor: Lógica Micro de Price Action             |
//+------------------------------------------------------------------+
class CBrooks_Executor
{
public:
    CBrooks_Executor();
    bool FindSignalBarAndPlaceOrder(FairValueGap &fvg, double atr);
};

CBrooks_Executor::CBrooks_Executor() {}

bool CBrooks_Executor::FindSignalBarAndPlaceOrder(FairValueGap &fvg, double atr)
{
    MqlRates candles[3];
    if(CopyRates(_Symbol, _Period, 0, 3, candles) < 3) return false;

    // Usamos la vela cerrada más reciente (índice 1) como la vela a evaluar
    MqlRates signal_candle = candles[1];
    MqlRates prev_candle = candles[2];

    bool price_in_fvg = false;
    // La lógica de FVG es:
    // - Alcista (Bullish): El precio debe retroceder (bajar) para tocar la zona. El borde superior es top_edge.
    // - Bajista (Bearish): El precio debe retroceder (subir) para tocar la zona. El borde inferior es bottom_edge.
    if(fvg.is_bullish) // Buscando compras, el precio debe haber entrado en la zona desde arriba.
    {
        // La vela de señal toca o penetra el FVG si su mínimo es menor o igual al borde superior del gap.
        price_in_fvg = (signal_candle.low <= fvg.top_edge);
    }
    else // Buscando ventas, el precio debe haber entrado en la zona desde abajo.
    {
        // La vela de señal toca o penetra el FVG si su máximo es mayor o igual al borde inferior del gap.
        price_in_fvg = (signal_candle.high >= fvg.bottom_edge);
    }

    if(!price_in_fvg) return false;

    // Definición de Vela Señal: Vela de reversión fuerte.
    // Ej. Alcista: Cierre en el 50% superior y cuerpo > 30% del rango total.
    bool is_bullish_signal = (signal_candle.close > signal_candle.open &&
                             (signal_candle.close - signal_candle.open) > (signal_candle.high - signal_candle.low) * 0.3 &&
                             signal_candle.close > (signal_candle.high + signal_candle.low) / 2);

    bool is_bearish_signal = (signal_candle.close < signal_candle.open &&
                             (signal_candle.open - signal_candle.close) > (signal_candle.high - signal_candle.low) * 0.3 &&
                              signal_candle.close < (signal_candle.high + signal_candle.low) / 2);

    // Colocar Orden
    if(fvg.is_bullish && is_bullish_signal)
    {
        double entry_buffer = atr * 0.05; // Buffer dinámico: 5% del ATR
        double entry_price = signal_candle.high + entry_buffer;
        double stop_loss = signal_candle.low - atr * 0.2;
        double sl_pips = (entry_price - stop_loss) / _Point;
        double take_profit = entry_price + (sl_pips * InpMinRewardRatio * _Point);
        double lot_size = g_risk->CalculateLotSize(sl_pips);
        double current_spread_quote = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
        string quote_currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

        if(trade.BuyStop(lot_size, entry_price, _Symbol, stop_loss, take_profit, 0, 0, "Buy Stop by Institutional EA"))
        {
            g_logger->LogTrade("ICT+Brooks", "BUY", entry_price, stop_loss, take_profit, lot_size, current_spread_quote, atr, "Placed", quote_currency);
            return true;
        }
        else
        {
            g_logger->LogTrade("ICT+Brooks", "BUY", entry_price, stop_loss, take_profit, lot_size, current_spread_quote, atr, "Failed: " + IntegerToString(trade.ResultRetcode()), quote_currency);
        }
    }
    else if(!fvg.is_bullish && is_bearish_signal)
    {
        double entry_buffer = atr * 0.05; // Buffer dinámico: 5% del ATR
        double entry_price = signal_candle.low - entry_buffer;
        double stop_loss = signal_candle.high + atr * 0.2;
        double sl_pips = (stop_loss - entry_price) / _Point;
        double take_profit = entry_price - (sl_pips * InpMinRewardRatio * _Point);
        double lot_size = g_risk->CalculateLotSize(sl_pips);
        double current_spread_quote = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
        string quote_currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

        if(trade.SellStop(lot_size, entry_price, _Symbol, stop_loss, take_profit, 0, 0, "Sell Stop by Institutional EA"))
        {
            g_logger->LogTrade("ICT+Brooks", "SELL", entry_price, stop_loss, take_profit, lot_size, current_spread_quote, atr, "Placed", quote_currency);
            return true;
        }
        else
        {
            g_logger->LogTrade("ICT+Brooks", "SELL", entry_price, stop_loss, take_profit, lot_size, current_spread_quote, atr, "Failed: " + IntegerToString(trade.ResultRetcode()), quote_currency);
        }
    }

    return false;
}


//+------------------------------------------------------------------+
//| Funciones del Expert Advisor                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Inicialización de objetos
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetMarginMode();
    trade.SetSlippage(InpSlippage);

    g_logger = new CData_Logger(InpCsvLogFileName);
    if(!g_logger->OpenFile())
    {
        return INIT_FAILED;
    }

    g_risk = new CRisk_Manager(InpRiskPercent);
    g_killzone = new CKillzone_Filter(InpLondonKillzoneStart, InpLondonKillzoneEnd, InpNewYorkKillzoneStart, InpNewYorkKillzoneEnd);

    //--- Inicialización de indicadores
    g_handle_atr = iATR(_Symbol, _Period, InpAtrPeriod);
    if(g_handle_atr == INVALID_HANDLE)
    {
        Print("Error creando el handle del ATR");
        return INIT_FAILED;
    }

    g_handle_zigzag = iZigZag(_Symbol, _Period, InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);
    if(g_handle_zigzag == INVALID_HANDLE)
    {
        Print("Error creando el handle del ZigZag");
        return INIT_FAILED;
    }

    //--- Inicialización de objetos dependientes de handles
    g_volatility = new CVolatility_Filter(g_handle_atr, InpMaxSpreadAtrRatio);
    g_ict = new CICT_Analyzer(g_handle_zigzag, InpMinFvgAtrRatio);
    g_brooks = new CBrooks_Executor();

    g_active_fvg.Reset();

    return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Limpiar panel y liberar recursos
    Comment("");
    if(CheckPointer(g_logger) == POINTER_DYNAMIC) delete g_logger;
    if(CheckPointer(g_risk) == POINTER_DYNAMIC) delete g_risk;
    if(CheckPointer(g_volatility) == POINTER_DYNAMIC) delete g_volatility;
    if(CheckPointer(g_killzone) == POINTER_DYNAMIC) delete g_killzone;
    if(CheckPointer(g_ict) == POINTER_DYNAMIC) delete g_ict;
    if(CheckPointer(g_brooks) == POINTER_DYNAMIC) delete g_brooks;

    IndicatorRelease(g_handle_atr);
    IndicatorRelease(g_handle_zigzag);
}
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Ejecutar lógica solo una vez por barra
    if(IsNewBar())
    {
        //--- FILTROS GLOBALES ---
        // 1. ¿Hay posiciones abiertas? Si es así, no hacer nada.
        if(PositionSelect(_Symbol))
        {
            return;
        }

        // 2. ¿Estamos en horario operativo (Killzone)?
        if(!g_killzone->IsInKillzone())
        {
            g_current_state = FILTRADO;
            return;
        }

        // 3. ¿El spread es aceptable?
        if(!g_volatility->IsSpreadValid())
        {
            Print("Spread demasiado alto, no se opera.");
            g_current_state = FILTRADO;
            return;
        }

        //--- LÓGICA DE TRADING ---
        // 1. Si NO hay un FVG activo, buscar un nuevo setup macro (ICT).
        if(!g_active_fvg.is_active)
        {
            g_current_state = BUSCANDO_SETUP_ICT;
            g_ict->FindSetup(g_active_fvg);
        }

        // 2. Si HAY un FVG activo, buscar la entrada micro (Brooks).
        if(g_active_fvg.is_active)
        {
            g_current_state = MONITOREANDO_FVG;

            // Prioridad 1: Buscar señal de entrada.
            double current_atr = g_volatility->GetATR();
            bool order_placed = g_brooks->FindSignalBarAndPlaceOrder(g_active_fvg, current_atr);

            if(order_placed)
            {
                Print("Orden colocada. Reseteando FVG activo.");
                g_active_fvg.Reset(); // Resetear para buscar el siguiente setup
                g_current_state = BUSCANDO_SETUP_ICT;
            }
            else
            {
                // Prioridad 2: Si no hay señal, verificar si el FVG se ha invalidado.
                MqlRates current_candle[1];
                CopyRates(_Symbol, _Period, 0, 1, current_candle);

                // Un FVG alcista se invalida si el precio cierra por debajo de su borde inferior (bottom_edge).
                // Un FVG bajista se invalida si el precio cierra por encima de su borde superior (top_edge).
                if((g_active_fvg.is_bullish && current_candle[0].close < g_active_fvg.bottom_edge) ||
                   (!g_active_fvg.is_bullish && current_candle[0].close > g_active_fvg.top_edge))
                {
                   Print("El FVG ha sido invalidado por el precio. Buscando nuevo setup.");
                   g_active_fvg.Reset();
                   CancelPendingOrders(); // Cancelar órdenes pendientes asociadas al FVG invalidado
                   g_current_state = BUSCANDO_SETUP_ICT;
                }
            }
        }
    }

    //--- Actualizar el panel de información en cada tick
    ActualizarPanelDeInfo();
}

//+------------------------------------------------------------------+
//| Funciones de Ayuda                                               |
//+------------------------------------------------------------------+
void CancelPendingOrders()
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(OrderSelect(ticket))
        {
            if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol)
            {
                if(OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED)
                {
                    trade.OrderDelete(ticket);
                    ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
                    double current_spread_quote = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
                    string quote_currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
                    g_logger->LogTrade("Management", order_type == ORDER_TYPE_BUY_STOP ? "BUY" : "SELL",
                                       OrderGetDouble(ORDER_PRICE_OPEN), 0, 0, OrderGetDouble(ORDER_VOLUME_CURRENT),
                                       current_spread_quote, 0, "Cancelled-FVG-Invalid", quote_currency);
                }
            }
        }
    }
}

bool IsNewBar()
{
    datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
    if(g_last_bar_time < current_bar_time)
    {
        g_last_bar_time = current_bar_time;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Función para mostrar el panel de información en el gráfico       |
//+------------------------------------------------------------------+
void ActualizarPanelDeInfo()
{
    string estado_texto = "";
    switch(g_current_state)
    {
        case BUSCANDO_SETUP_ICT:
            estado_texto = "Buscando Setup ICT (Sweep+MSS+FVG)";
            break;
        case MONITOREANDO_FVG:
            estado_texto = "Monitoreando FVG. Esperando Vela Señal.";
            break;
        case FILTRADO:
            estado_texto = "En Espera (Fuera de Horario o Spread Alto)";
            break;
    }

    string panel_texto = "--- Estado del EA Institucional ---\n";
    panel_texto += "Estado Actual: " + estado_texto + "\n";
    panel_texto += "FVG Activo: " + (g_active_fvg.is_active ? (g_active_fvg.is_bullish ? "Alcista" : "Bajista") : "Ninguno") + "\n";
    if(g_active_fvg.is_active)
    {
       panel_texto += "   - Top Edge: " + DoubleToString(g_active_fvg.top_edge, _Digits) + "\n";
       panel_texto += "   - Bottom Edge: " + DoubleToString(g_active_fvg.bottom_edge, _Digits) + "\n";
    }

    Comment(panel_texto);
}
//+------------------------------------------------------------------+
