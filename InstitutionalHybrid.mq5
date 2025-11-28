//+------------------------------------------------------------------+
//|                                     InstitutionalHybrid.mq5 |
//|                      Copyright 2023, Senior Financial Architect |
//|                                             [Your Name Here] |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Senior Financial Architect"
#property link      "mailto:your.email@example.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Enumeración para los estados de la máquina de estados del EA
enum ENUM_ESTADO_EA
{
    FILTRADO,               // Estado de filtro: Horario o spread no son óptimos
    BUSCANDO_SETUP_ICT,     // Buscando barrido de liquidez, MSS y FVG
    MONITOREANDO_FVG        // FVG válido encontrado, esperando retroceso y vela de señal
};

//--- Inputs del usuario
input group "Gestión de Riesgo"
input double InpLotRiskPercent = 1.0; // Porcentaje de riesgo por operación
input group "Filtros de Calidad"
input int    InpMaxSpreadAsAtrPercent   = 20;  // Spread máximo como %% del ATR (ej. 20 = 20%%)
input string InpLondonKillZone    = "08:00-11:00"; // Killzone de Londres (activo)
input string InpNewYorkKillZone   = "13:00-16:00"; // Killzone de Nueva York (activo)
input group "Indicadores"
input int    InpZigZagDepth       = 12;
input int    InpZigZagDeviation   = 5;
input int    InpZigZagBackstep    = 3;
input int    InpAtrPeriod         = 14;  // Periodo del ATR
input double InpAtrSlMultiplier   = 2.0; // Multiplicador de ATR para Stop Loss
input double InpFvgMinSizeAtrMult = 0.5; // Multiplicador ATR para tamaño mínimo de FVG

//--- Variables globales
CTrade      trade;
ENUM_ESTADO_EA estadoActual = FILTRADO;
string      nombreArchivoLog;
int         handleATR;
int         handleZigZag;
datetime    ultimaVelaProcesada = 0;

//--- Estructura para almacenar información del Fair Value Gap (FVG)
struct FVG_Info
{
    double   precioSuperior;
    double   precioInferior;
    int      velaInicio;
    bool     esValido;
    string   tipo; // "Bullish" o "Bearish"
};

FVG_Info fvgActual; // Variable global para almacenar el FVG actual

//+------------------------------------------------------------------+
//| Función de inicialización del expert                               |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Inicialización del objeto de trading
    trade.SetExpertMagicNumber(12345);
    trade.SetMarginMode();

    //--- Crear handles para los indicadores
    handleATR = iATR(_Symbol, _Period, InpAtrPeriod);
    if(handleATR == INVALID_HANDLE)
    {
        printf("Error creando handle para ATR. Código de error: %d", GetLastError());
        return(INIT_FAILED);
    }

    // Ruta corregida basándose en la información del usuario
    string zigzag_path = "Indicators\\Examples\\ZigZag";
    handleZigZag = iCustom(_Symbol, _Period, zigzag_path, InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep);

    if(handleZigZag == INVALID_HANDLE)
    {
        printf("Error creando handle para ZigZag con la ruta '%s'. Código de error: %d", zigzag_path, GetLastError());
        Print("Asegúrese de que el indicador ZigZag se encuentra en la carpeta MQL5\\Indicators\\Examples\\");
        return(INIT_FAILED);
    }

    //--- Configurar nombre del archivo de log
    nombreArchivoLog = "TradeLog_Institutional_Hybrid.csv";

    //--- Escribir cabecera del CSV si no existe
    int fileHandle = FileOpen(nombreArchivoLog, FILE_READ | FILE_WRITE | FILE_CSV);
    if(fileHandle != INVALID_HANDLE)
    {
        if(FileSize(fileHandle) == 0)
        {
            FileWriteString(fileHandle, "Timestamp,Symbol,Action,Result,Price,SL,TP,Spread,ATR,Comment\n");
        }
        FileClose(fileHandle);
    }

    fvgActual.esValido = false; // Inicializar FVG como no válido

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Función de desinicialización del expert                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Liberar handles de indicadores
    IndicatorRelease(handleATR);
    IndicatorRelease(handleZigZag);

    //--- Comentario final
    Comment("");
}

//+------------------------------------------------------------------+
//| Función de tick del expert                                       |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Solo ejecutar la lógica principal una vez por vela
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 0, 1, rates) < 1) return;

    if(rates[0].time == ultimaVelaProcesada)
    {
        // En cada tick, solo actualizamos el panel y gestionamos trades abiertos (si los hubiera)
        ActualizarPanelDeInfo();
        return;
    }
    ultimaVelaProcesada = rates[0].time;

    //--- Máquina de Estados Principal
    // 1. Aplicar Filtros
    if(!FiltrosSonValidos())
    {
        estadoActual = FILTRADO;
        fvgActual.esValido = false; // Invalidar FVG si estamos fuera de horario
        ActualizarPanelDeInfo();
        return;
    }

    // Si los filtros son válidos, pasamos a buscar setup
    if(estadoActual == FILTRADO)
    {
        estadoActual = BUSCANDO_SETUP_ICT;
    }

    // 2. Lógica de Búsqueda de Setups ICT
    if(estadoActual == BUSCANDO_SETUP_ICT)
    {
        BuscarSetupICT();
    }

    // 3. Lógica de Monitoreo de FVG y Entrada Micro
    if(estadoActual == MONITOREANDO_FVG)
    {
        MonitorearFVG_Y_Entrar();
    }

    ActualizarPanelDeInfo();
}

//+------------------------------------------------------------------+
//| Verifica si las condiciones de mercado son operables.             |
//+------------------------------------------------------------------+
bool FiltrosSonValidos()
{
    //--- Filtro de Killzone (Horario)
    MqlDateTime tiempoServidor;
    TimeCurrent(tiempoServidor);
    int hora = tiempoServidor.hour;

    bool enKillzone = false;
    string londonPartes[], nyPartes[];
    StringSplit(InpLondonKillZone, '-', londonPartes);
    StringSplit(InpNewYorkKillZone, '-', nyPartes);

    if(hora >= (int)StringSubstr(londonPartes[0], 0, 2) && hora < (int)StringSubstr(londonPartes[1], 0, 2)) enKillzone = true;
    if(hora >= (int)StringSubstr(nyPartes[0], 0, 2) && hora < (int)StringSubstr(nyPartes[1], 0, 2)) enKillzone = true;

    if(!enKillzone)
    {
        //Print("Filtro Activo: Fuera de Killzone. Hora del servidor: ", hora);
        return false;
    }

    //--- Filtro de Spread Relativo
    double atrActual = ObtenerValorATR(1);
    if(atrActual <= 0)
    {
        //Print("Filtro Activo: ATR es cero, no se puede calcular el spread relativo.");
        return false;
    }

    double spreadActual = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
    double maxSpreadPermitido = atrActual * (InpMaxSpreadAsAtrPercent / 100.0);

    if(spreadActual > maxSpreadPermitido)
    {
       //Print(StringFormat("Filtro Activo: Spread (%.5f) > Límite (%.5f)", spreadActual, maxSpreadPermitido));
       RegistrarIntento("Filter", "Failed", 0, 0, 0, spreadActual, atrActual, "Spread_Excesivo");
       return false;
    }

    //Print("Filtros OK: Dentro de Killzone y Spread aceptable.");
    return true;
}


//+------------------------------------------------------------------+
//| Busca un setup ICT completo: MSS + FVG.                          |
//+------------------------------------------------------------------+
void BuscarSetupICT()
{
    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 0, 100, rates) < 100) return; // Necesitamos suficientes velas

    double zigzagBuffer[];
    if(CopyBuffer(handleZigZag, 0, 0, 100, zigzagBuffer) < 100) return;

    // Encontrar los últimos 3 puntos del ZigZag (p0=actual, p1=previo, p2=ante-previo)
    double p0_val, p1_val, p2_val;
    int p0_idx, p1_idx, p2_idx;

    if(!ObtenerPuntosZigZag(zigzagBuffer, 100, p0_val, p0_idx, p1_val, p1_idx, p2_val, p2_idx))
    {
        //Print("No se encontraron 3 puntos de ZigZag. Esperando más datos...");
        return;
    }

    //--- Detección de Market Structure Shift (MSS)
    // MSS Bajista: p1 es un máximo (high), p0 es un mínimo (low) que rompe por debajo del mínimo anterior p2.
    bool mssBajista = (p1_val > p0_val && p1_val > p2_val && p0_val < p2_val);

    // MSS Alcista: p1 es un mínimo (low), p0 es un máximo (high) que rompe por encima del máximo anterior p2.
    bool mssAlcista = (p1_val < p0_val && p1_val < p2_val && p0_val > p2_val);

    if(mssBajista || mssAlcista)
    {
        string tipoMSS = mssBajista ? "Bajista" : "Alcista";
        //Print(StringFormat("MSS %s Detectado! Buscando FVG entre velas %d y %d", tipoMSS, p0_idx, p1_idx));

        // Si hay MSS, buscar FVG entre el swing que causó el quiebre (entre p1 y p0)
        for(int i = p0_idx; i > p1_idx && i >= 2; i--)
        {
            if(mssBajista)
            {
                // FVG Bajista: Vela actual low < Vela ante-anterior high
                if(rates[i].low > rates[i-2].high)
                {
                    double fvg_top = rates[i-2].high;
                    double fvg_bottom = rates[i].low;
                    double fvg_size = fvg_top - fvg_bottom;
                    double min_fvg_size = ObtenerValorATR(i) * InpFvgMinSizeAtrMult;

                    if(fvg_size >= min_fvg_size)
                    {
                        fvgActual.precioSuperior = fvg_top;
                        fvgActual.precioInferior = fvg_bottom;
                        fvgActual.velaInicio = i-1;
                        fvgActual.esValido = true;
                        fvgActual.tipo = "Bearish";
                        estadoActual = MONITOREANDO_FVG;
                        Print(StringFormat("FVG Bajista VÁLIDO encontrado en vela %d. Rango: %.5f - %.5f", i-1, fvg_bottom, fvg_top));
                        return; // Salimos al encontrar el primer FVG válido
                    }
                    else
                    {
                        //Print(StringFormat("FVG Bajista DESCARTADO en vela %d por tamaño. Tamaño: %.5f, Mínimo: %.5f", i-1, fvg_size, min_fvg_size));
                    }
                }
            }
            else if(mssAlcista)
            {
                // FVG Alcista: Vela actual high > Vela ante-anterior low
                if(rates[i].high < rates[i-2].low)
                {
                    double fvg_top = rates[i].high;
                    double fvg_bottom = rates[i-2].low;
                    double fvg_size = fvg_bottom - fvg_top;
                    double min_fvg_size = ObtenerValorATR(i) * InpFvgMinSizeAtrMult;

                    if(fvg_size >= min_fvg_size)
                    {
                        fvgActual.precioSuperior = fvg_bottom;
                        fvgActual.precioInferior = fvg_top;
                        fvgActual.velaInicio = i-1;
                        fvgActual.esValido = true;
                        fvgActual.tipo = "Bullish";
                        estadoActual = MONITOREANDO_FVG;
                        Print(StringFormat("FVG Alcista VÁLIDO encontrado en vela %d. Rango: %.5f - %.5f", i-1, fvg_top, fvg_bottom));
                        return; // Salimos al encontrar el primer FVG válido
                    }
                     else
                    {
                        //Print(StringFormat("FVG Alcista DESCARTADO en vela %d por tamaño. Tamaño: %.5f, Mínimo: %.5f", i-1, fvg_size, min_fvg_size));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Monitorea el FVG y busca la entrada micro con una vela de señal. |
//+------------------------------------------------------------------+
void MonitorearFVG_Y_Entrar()
{
    if(!fvgActual.esValido)
    {
        estadoActual = BUSCANDO_SETUP_ICT;
        return;
    }

    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 0, 10, rates) < 10) return;

    // La vela de señal es la vela completada más reciente (índice 1)
    MqlRates velaSenal = rates[1];

    // Verificar si el precio ha tocado el FVG
    bool precioTocoFVG = false;
    if(fvgActual.tipo == "Bearish" && velaSenal.high >= fvgActual.precioInferior) precioTocoFVG = true;
    if(fvgActual.tipo == "Bullish" && velaSenal.low <= fvgActual.precioSuperior) precioTocoFVG = true;

    //Print(StringFormat("Monitoreando FVG %s. Precio actual (vela 1 high/low): %.5f/%.5f. FVG Zone: %.5f-%.5f", fvgActual.tipo, velaSenal.high, velaSenal.low, fvgActual.precioSuperior, fvgActual.precioInferior));

    if(precioTocoFVG)
    {
        //Print("Precio tocó el FVG. Verificando vela de señal...");
        // Criterios para una "Vela de Señal" (Signal Bar) válida
        // 1. Es una vela de reversión (cierra en la dirección opuesta al FVG)
        // 2. Tiene un rango mayor al promedio (indica convicción)

        bool esVelaReversionValida = false;
        string motivoRechazo = "";

        if(fvgActual.tipo == "Bearish" && velaSenal.close < velaSenal.open) esVelaReversionValida = true; // Vela bajista
        else if(fvgActual.tipo == "Bullish" && velaSenal.close > velaSenal.open) esVelaReversionValida = true; // Vela alcista
        else motivoRechazo = "No es vela de reversión.";

        // Comprobar rango
        double rangoVelaSenal = velaSenal.high - velaSenal.low;
        double atrActual = ObtenerValorATR(1);
        if(rangoVelaSenal < (atrActual * 0.7))
        {
            esVelaReversionValida = false; // Rango debe ser significativo
            motivoRechazo += StringFormat(" Rango (%.5f) < Mínimo (%.5f).", rangoVelaSenal, atrActual * 0.7);
        }

        if(esVelaReversionValida)
        {
            Print("Vela de Señal VÁLIDA encontrada. Procediendo a colocar orden.");
            if(PositionsTotal() > 0)
            {
                //Print("Operación abortada: ya existe una posición abierta.");
                return;
            }

            double precioEntrada, sl, tp;
            double atrStop = ObtenerValorATR(1) * InpAtrSlMultiplier;
            double currentSpread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point; // Calcular spread en unidades de precio

            if(fvgActual.tipo == "Bearish")
            {
                precioEntrada = NormalizeDouble(velaSenal.low - _Point, _Digits);
                sl = NormalizeDouble(velaSenal.high + atrStop, _Digits);
                tp = 0; // TP se gestionará con trailing stop, no se establece aquí.

                double lotaje = CalcularLotaje(sl, precioEntrada);
                if(lotaje > 0)
                {
                   if(trade.SellStop(lotaje, precioEntrada, _Symbol, sl, tp, 0, 0, "Sell Stop Institucional"))
                   {
                      RegistrarIntento("SellStop", "Placed", precioEntrada, sl, tp, currentSpread, atrActual, "Orden Colocada");
                   }
                   else
                   {
                      RegistrarIntento("SellStop", "Failed", precioEntrada, sl, tp, currentSpread, atrActual, "Fallo al colocar: " + IntegerToString(trade.ResultRetcode()));
                   }
                }
            }
            else // Bullish
            {
                precioEntrada = NormalizeDouble(velaSenal.high + _Point, _Digits);
                sl = NormalizeDouble(velaSenal.low - atrStop, _Digits);
                tp = 0;

                double lotaje = CalcularLotaje(sl, precioEntrada);
                 if(lotaje > 0)
                {
                   if(trade.BuyStop(lotaje, precioEntrada, _Symbol, sl, tp, 0, 0, "Buy Stop Institucional"))
                   {
                       RegistrarIntento("BuyStop", "Placed", precioEntrada, sl, tp, currentSpread, atrActual, "Orden Colocada");
                   }
                   else
                   {
                       RegistrarIntento("BuyStop", "Failed", precioEntrada, sl, tp, currentSpread, atrActual, "Fallo al colocar: " + IntegerToString(trade.ResultRetcode()));
                   }
                }
            }

            // Una vez se intenta la operación, se invalida el FVG para buscar uno nuevo.
            fvgActual.esValido = false;
            estadoActual = BUSCANDO_SETUP_ICT;
        }
    }

    // Invalidar FVG si el precio lo atraviesa completamente sin generar señal
    if((fvgActual.tipo == "Bearish" && velaSenal.close > fvgActual.precioSuperior) ||
       (fvgActual.tipo == "Bullish" && velaSenal.close < fvgActual.precioInferior))
    {
        fvgActual.esValido = false;
        estadoActual = BUSCANDO_SETUP_ICT;
        //printf("FVG invalidado por quiebre completo.");
    }
}


//+------------------------------------------------------------------+
//| Calcula el tamaño del lote basado en el riesgo porcentual.        |
//+------------------------------------------------------------------+
double CalcularLotaje(double sl, double precioEntrada)
{
    double accountBalance = AccountInfoDouble(ACCOUNT_EQUITY);
    if(accountBalance <= 0) return 0.0;

    double riesgoMonetario = accountBalance * (InpLotRiskPercent / 100.0);
    double riesgoPorLote = 0.0;

    // Diferencia en puntos
    double diferenciaPuntos = MathAbs(precioEntrada - sl) / _Point;

    // Valor del tick y tamaño del tick
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(tickSize > 0)
    {
        riesgoPorLote = diferenciaPuntos * tickValue;
    }

    if(riesgoPorLote <= 0) return 0.0;

    double lotaje = riesgoMonetario / riesgoPorLote;

    // Normalizar y verificar límites de lotaje
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lotaje = MathFloor(lotaje / stepLot) * stepLot;

    if(lotaje < minLot) lotaje = 0; // No operar si el riesgo es demasiado pequeño
    if(lotaje > maxLot) lotaje = maxLot;

    // Para criptomonedas, permitir más decimales.
    int digits = 2;
    string symbol_group = SymbolInfoString(_Symbol, SYMBOL_PATH);
    if(StringFind(symbol_group, "Crypto") != -1)
    {
        digits = 8;
    }

    return NormalizeDouble(lotaje, digits);
}

//+------------------------------------------------------------------+
//| Obtiene el valor del indicador ATR para una vela específica.      |
//+------------------------------------------------------------------+
double ObtenerValorATR(int vela)
{
    double atrBuffer[1];
    if(CopyBuffer(handleATR, 0, vela, 1, atrBuffer) > 0)
    {
        return atrBuffer[0];
    }
    return 0.0;
}

//+------------------------------------------------------------------+
//| Encuentra los últimos 3 puntos del indicador ZigZag.             |
//+------------------------------------------------------------------+
bool ObtenerPuntosZigZag(const double &zigzagBuffer[], int bufferSize,
                         double &p0_val, int &p0_idx,
                         double &p1_val, int &p1_idx,
                         double &p2_val, int &p2_idx)
{
    int encontrados = 0;
    for(int i = 1; i < bufferSize; i++) // Empezar en 1 para evitar la vela actual que puede repintar
    {
        if(zigzagBuffer[i] > 0)
        {
            if(encontrados == 0) { p0_val = zigzagBuffer[i]; p0_idx = i; }
            else if(encontrados == 1) { p1_val = zigzagBuffer[i]; p1_idx = i; }
            else if(encontrados == 2) { p2_val = zigzagBuffer[i]; p2_idx = i; }
            encontrados++;
        }
        if(encontrados == 3) return true;
    }
    return false;
}


//+------------------------------------------------------------------+
//| Actualiza el panel de información en el gráfico.                 |
//+------------------------------------------------------------------+
void ActualizarPanelDeInfo()
{
    string estadoStr = "Desconocido";
    switch(estadoActual)
    {
        case FILTRADO:
            estadoStr = "FILTRADO (Fuera de Horario / Spread Alto)";
            break;
        case BUSCANDO_SETUP_ICT:
            estadoStr = "BUSCANDO SETUP ICT (MSS + FVG)";
            break;
        case MONITOREANDO_FVG:
            estadoStr = "MONITOREANDO FVG (" + fvgActual.tipo + ")";
            break;
    }

    string comment = "--- EA Institucional Híbrido ---\n";
    comment += "Estado Actual: " + estadoStr + "\n";
    comment += "Símbolo: " + _Symbol + "\n";

    if(estadoActual == MONITOREANDO_FVG && fvgActual.esValido)
    {
        comment += StringFormat("FVG Detectado: %.5f - %.5f\n", fvgActual.precioInferior, fvgActual.precioSuperior);
    }

    Comment(comment);
}

//+------------------------------------------------------------------+
//| Registra un intento de trade en el archivo CSV.                  |
//+------------------------------------------------------------------+
void RegistrarIntento(string accion, string resultado, double precio, double sl, double tp, double spread, double atr, string comentario)
{
    int handle = FileOpen(nombreArchivoLog, FILE_WRITE | FILE_READ | FILE_CSV);
    if(handle != INVALID_HANDLE)
    {
        FileSeek(handle, 0, SEEK_END); // Moverse al final del archivo para añadir

        string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "," +
                      _Symbol + "," +
                      accion + "," +
                      resultado + "," +
                      DoubleToString(precio, _Digits) + "," +
                      DoubleToString(sl, _Digits) + "," +
                      DoubleToString(tp, _Digits) + "," +
                      DoubleToString(spread, _Digits) + "," +
                      DoubleToString(atr, _Digits) + "," +
                      comentario;

        FileWriteString(handle, line + "\n");
        FileClose(handle);
    }
}
//+------------------------------------------------------------------+
