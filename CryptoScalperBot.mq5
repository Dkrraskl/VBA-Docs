//|                                             CryptoScalperBot.mq5 |
//|                        Copyright 2023, MetaQuotes Software Corp. |
//|                                              https://www.mql5.com |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Comprueba si ya existe una posición abierta para el símbolo      |
//| actual, gestionada por este EA.                                  |
//+------------------------------------------------------------------+
bool IsPositionOpen()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionGetInteger(POSITION_MAGIC) == magic_number && PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            return(true); // Se encontró una posición
        }
    }
    return(false); // No hay posiciones abiertas para este símbolo y magic number
}
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Asesor Experto de Scalping para BTCUSD en M5/M15 basado en Wyckoff y Elliott Wave."

// --- Incluir la librería de trading
#include <Trade\Trade.mqh>

// --- Parámetros de entrada del EA
// --- Parámetros CRÍTICOS para el ZigZag
input int      zigzag_depth = 3;        // Profundidad del ZigZag
input int      zigzag_deviation = 1;    // Desviación del ZigZag
input int      zigzag_backstep = 1;     // Backstep del ZigZag
// --- Otros parámetros
input int      ema_period = 20;         // Período de la EMA
input int      stop_loss_pips = 150;    // Stop Loss fijo en pips
input int      take_profit_pips = 100;  // Take Profit fijo en pips
input ulong    magic_number = 666777;   // Número Mágico para identificar las operaciones del EA
input double   lot_size = 0.01;         // Tamaño del lote

// --- Variables globales
CTrade         trade;                   // Objeto para operaciones de trading
int            zigzag_handle;           // Handle para el indicador ZigZag
int            ema_handle;              // Handle para el indicador EMA

// --- Nombres de los objetos gráficos para fácil gestión
string         sup_line_name = "SupportLine_";
string         res_line_name = "ResistanceLine_";
string         buy_arrow_name = "BuyArrow_";
string         sell_arrow_name = "SellArrow_";

//+------------------------------------------------------------------+
//| Función de inicialización del Experto                            |
//+------------------------------------------------------------------+
int OnInit()
{
    // --- Configurar el objeto de trading
    trade.SetExpertMagicNumber(magic_number);
    trade.SetMarginMode();
    trade.SetTypeFillingBySymbol(_Symbol);

    // --- Crear handle para el indicador iCustom ZigZag
    // --- Usamos el indicador ZigZag estándar que viene con MetaTrader 5
    zigzag_handle = iCustom(_Symbol, _Period, "Examples\\ZigZag", zigzag_depth, zigzag_deviation, zigzag_backstep);
    if(zigzag_handle == INVALID_HANDLE)
    {
        Print("Error al crear el handle del indicador ZigZag. Código de error: ", GetLastError());
        return(INIT_FAILED);
    }

    // --- Crear handle para la EMA
    ema_handle = iMA(_Symbol, _Period, ema_period, 0, MODE_EMA, PRICE_CLOSE);
    if(ema_handle == INVALID_HANDLE)
    {
        Print("Error al crear el handle del indicador EMA. Código de error: ", GetLastError());
        return(INIT_FAILED);
    }

    Print("Asesor Experto CryptoScalperBot inicializado correctamente.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Función de desinicialización del Experto                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // --- Liberar los handles de los indicadores
    IndicatorRelease(zigzag_handle);
    IndicatorRelease(ema_handle);

    // --- Eliminar objetos gráficos creados por el EA
    ObjectsDeleteAll(0, sup_line_name);
    ObjectsDeleteAll(0, res_line_name);
    ObjectsDeleteAll(0, buy_arrow_name);
    ObjectsDeleteAll(0, sell_arrow_name);

    Print("Asesor Experto CryptoScalperBot desinicializado.");
}

//+------------------------------------------------------------------+
//| Función OnTick - se ejecuta en cada nuevo tick                   |
//+------------------------------------------------------------------+
void OnTick()
{
    // --- Solo ejecutar la lógica una vez por barra para optimizar
    static datetime prev_bar_time = 0;
    datetime current_bar_time = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
    if(current_bar_time == prev_bar_time)
    {
        return; // Si no es una nueva barra, salir
    }
    prev_bar_time = current_bar_time;

    // --- Comprobar si ya hay una posición abierta por este EA para el símbolo actual (CORREGIDO)
    if(IsPositionOpen())
    {
        return; // Si ya hay una posición para este símbolo, no hacer nada
    }

    // --- Arrays para almacenar los datos de los indicadores
    double ema_buffer[];

    // --- Copiar el último valor de la EMA
    if(CopyBuffer(ema_handle, 0, 0, 2, ema_buffer) <= 0)
    {
        Print("Error al copiar el buffer de la EMA. ", GetLastError());
        return;
    }

    // --- Lógica para encontrar los últimos picos y valles del ZigZag (CORREGIDA)
    // --- El buffer del ZigZag es "sparse" (disperso), contiene valores solo en los puntos de inflexión.
    // --- Creamos una estructura para almacenar los puntos encontrados
    struct Extremum {
        double value;
        int bar_index;
    };

    Extremum extrema[4]; // Almacenaremos los últimos 4 puntos
    int extrema_found = 0;

    // --- Copiamos los datos del indicador para el análisis
    double zigzag_buffer[];
    // --- Copiamos un rango más grande para asegurarnos de encontrar los puntos necesarios
    if(CopyBuffer(zigzag_handle, 0, 0, 200, zigzag_buffer) <= 0)
    {
        Print("Error al copiar el buffer del ZigZag. ", GetLastError());
        return;
    }

    // --- Iteramos hacia atrás en el tiempo (desde el índice 1, para ignorar la barra actual)
    for(int i = 1; i < 200 && extrema_found < 4; i++)
    {
        double zigzag_val = zigzag_buffer[i];

        if(zigzag_val > 0)
        {
            // --- Evitar registrar el mismo punto dos veces
            if(extrema_found > 0 && extrema[extrema_found-1].value == zigzag_val) continue;

            extrema[extrema_found].value = zigzag_val;
            extrema[extrema_found].bar_index = i;
            extrema_found++;
        }
    }

    // --- Asegurarse de que tenemos suficientes puntos (al menos 3 para definir una estructura)
    if(extrema_found < 3) return;

    // --- Identificar los picos y valles a partir de los puntos encontrados
    // --- Comparamos los valores para clasificarlos
    double last_high = 0, prev_high = 0;
    double last_low = 0, prev_low = 0;

    // --- El punto más reciente (extrema[0]) define la naturaleza del anterior (extrema[1])
    // --- Si extrema[0] > extrema[1], entonces extrema[0] es un PICO y extrema[1] es un VALLE.
    if(extrema[0].value > extrema[1].value)
    {
        last_high = extrema[0].value;
        last_low = extrema[1].value;
        // El punto en extrema[2] debe ser el pico anterior (prev_high)
        if(extrema_found > 2) prev_high = extrema[2].value;
        // El punto en extrema[3] debe ser el valle anterior (prev_low)
        if(extrema_found > 3) prev_low = extrema[3].value;
    }
    else // El más reciente es un VALLE
    {
        last_low = extrema[0].value;
        last_high = extrema[1].value;
        // El punto en extrema[2] debe ser el valle anterior (prev_low)
        if(extrema_found > 2) prev_low = extrema[2].value;
        // El punto en extrema[3] debe ser el pico anterior (prev_high)
        if(extrema_found > 3) prev_high = extrema[3].value;
    }

    // --- Asegurarse de que tenemos los 4 puntos necesarios para la lógica
    if(last_high == 0 || prev_high == 0 || last_low == 0 || prev_low == 0) return;

    // --- Obtener el precio de cierre actual
    MqlTick last_tick;
    SymbolInfoTick(_Symbol, last_tick);
    double current_price = last_tick.ask; // Usar 'ask' para compras
    double current_price_bid = last_tick.bid; // Usar 'bid' para ventas
    double ema_value = ema_buffer[1]; // EMA de la barra anterior completa

    // --- LÓGICA DE COMPRA (BUY SIGNAL) con SL/TP FIJOS
    // --- 1. Se forma un Higher Low (último valle es más alto que el valle anterior).
    // --- 2. El precio rompe por encima del último pico (Break of Structure - BOS).
    // --- 3. El precio actual está por encima de la EMA de 20 períodos.
    if(last_low > prev_low && current_price > last_high && current_price > ema_value)
    {
        double stop_loss = current_price - (stop_loss_pips * _Point);
        double take_profit = current_price + (take_profit_pips * _Point);

        // --- Enviar orden de compra
        if(trade.Buy(lot_size, _Symbol, current_price, stop_loss, take_profit, "Buy by CryptoScalperBot"))
        {
            DrawHorizontalLine(res_line_name + (string)TimeCurrent(), last_high, clrRed, 1, STYLE_SOLID);
            DrawTradeMarker(buy_arrow_name + (string)TimeCurrent(), TimeCurrent(), current_price - (_Digits * 10 * _Point), 233, clrGreen);
        }
    }

    // --- LÓGICA DE VENTA (SELL SIGNAL) con SL/TP FIJOS
    // --- 1. Se forma un Lower High (último pico es más bajo que el pico anterior).
    // --- 2. El precio rompe por debajo del último valle (Break of Structure - BOS).
    // --- 3. El precio actual está por debajo de la EMA de 20 períodos.
    if(last_high < prev_high && current_price_bid < last_low && current_price_bid < ema_value)
    {
        double stop_loss = current_price_bid + (stop_loss_pips * _Point);
        double take_profit = current_price_bid - (take_profit_pips * _Point);

        // --- Enviar orden de venta
        if(trade.Sell(lot_size, _Symbol, current_price_bid, stop_loss, take_profit, "Sell by CryptoScalperBot"))
        {
            DrawHorizontalLine(sup_line_name + (string)TimeCurrent(), last_low, clrBlue, 1, STYLE_SOLID);
            DrawTradeMarker(sell_arrow_name + (string)TimeCurrent(), TimeCurrent(), current_price_bid + (_Digits * 10 * _Point), 234, clrRed);
        }
    }
}

//+------------------------------------------------------------------+
//| Dibuja una línea horizontal en el gráfico                        |
//+------------------------------------------------------------------+
void DrawHorizontalLine(string name, double price, color clr, int width, ENUM_LINE_STYLE style)
{
    // --- Borrar líneas antiguas para mantener el gráfico limpio
    ObjectsDeleteAll(0, "SupportLine_");
    ObjectsDeleteAll(0, "ResistanceLine_");

    if(ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
    {
        ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
        ObjectSetInteger(0, name, OBJPROP_STYLE, style);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    }
}

//+------------------------------------------------------------------+
//| Dibuja un marcador de operación (triángulo) en el gráfico        |
//+------------------------------------------------------------------+
void DrawTradeMarker(string name, datetime time, double price, int code, color clr)
{
    if(ObjectCreate(0, name, OBJ_ARROW, 0, time, price))
    {
        ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    }
}
//+------------------------------------------------------------------+
