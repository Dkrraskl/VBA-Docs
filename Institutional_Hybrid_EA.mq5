//+------------------------------------------------------------------+
//|                                    Institutional_Hybrid_EA.mq5    |
//|                        Sistema Híbrido ICT + Brooks v3.0 PROFIT   |
//|                                      Arquitectura Institucional   |
//+------------------------------------------------------------------+
#property copyright "Trading Institucional 2025"
#property link      "https://www.tradingsystem.com"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//--- Enumeración de Estados del EA
enum ENUM_EA_STATE
{
   STATE_BUSCANDO_SETUP_ICT,    // Buscando Barrida de Liquidez + MSS + FVG
   STATE_MONITOREANDO_FVG,      // Esperando retorno al FVG y vela de señal
   STATE_FILTRADO               // Condiciones de mercado no óptimas
};

//--- Inputs del Usuario
input group "===== CONFIGURACIÓN ICT ====="
input double    InpMinFVGSizeATR = 0.7;           // FVG Mínimo (Múltiplo de ATR)
input int       InpFVGLookback = 75;              // Barras para buscar FVG
input double    InpFVGRetestTolerance = 0.2;      // Tolerancia para retest FVG (ATR)
input double    InpMinImpulsoATR = 1.0;           // Impulso Mínimo (ATR)

input group "===== CONFIGURACIÓN BROOKS ====="
input double    InpSignalBarMinBodyPct = 50.0;    // Vela Señal: Mínimo % Cuerpo
input double    InpSignalBarMinSizeATR = 0.7;     // Vela Señal: Tamaño Mínimo (ATR)
input bool      InpRequireCloseNearExtreme = true; // Vela debe cerrar cerca del extremo - ACTIVADO POR DEFECTO

input group "===== GESTIÓN DE RIESGO ====="
input double    InpRiskPercent = 1.0;             // Riesgo por Operación (%)
input double    InpStopLossATR = 1.5;             // Stop Loss (Múltiplo ATR)
input double    InpTakeProfitRatio = 3.0;         // Ratio TP/SL (para cálculo de R:R)
input double    InpMinRiskReward = 2.0;           // Mínimo Risk:Reward aceptable
input bool      InpPermitirMultiplesPosiciones = false; // Permitir varias posiciones simultáneas

input group "===== FILTROS INSTITUCIONALES ====="
input bool      InpUsarFiltroRegimen = true;      // Usar Filtro de Regimen de Mercado (EMAs)
input int       InpFastEMAPeriod = 50;            // EMA Rápida
input int       InpSlowEMAPeriod = 200;           // EMA Lenta
input bool      InpUsarKillzones = true;          // Usar Killzones
input int       InpHoraInicioLondres = 8;         // Killzone Londres: Inicio (GMT)
input int       InpHoraFinLondres = 12;           // Killzone Londres: Fin (GMT)
input int       InpHoraInicioNY = 13;             // Killzone Nueva York: Inicio (GMT)
input int       InpHoraFinNY = 17;                // Killzone Nueva York: Fin (GMT)
input bool      InpUsarFiltroSpread = true;       // Usar Filtro de Spread
input double    InpMaxSpreadATRPct = 50.0;        // Spread Máximo (% ATR). Forex: 5-10, Crypto: 30-60
input int       InpATRPeriod = 14;                // ATR: Periodo
input int       InpMinATRPoints = 10;             // ATR Mínimo en puntos

input group "===== CONFIGURACIÓN AVANZADA ====="
input int       InpFVGTimeoutBars = 20;           // Timeout FVG (Barras)
input int       InpMaxOperacionesDiarias = 3;     // Máximo operaciones por día
input bool      InpHabilitarCSV = true;           // Guardar Datos en CSV
input bool      InpModoDebug = true;              // Activar logs detallados

//--- Variables Globales
CTrade trade;
ulong  expertMagicNumber = 123456;
int handleATR;
int handleFastEMA;
int handleSlowEMA;
double atrBuffer[];
double fastEMABuffer[];
double slowEMABuffer[];
ENUM_EA_STATE estadoActual = STATE_BUSCANDO_SETUP_ICT;

//--- Estadísticas para debug
int totalFVGsDetectados = 0;
int totalRetestsFallidos = 0;
int totalVelasRechazadas = 0;
int totalRRRechazados = 0;
int totalFiltradosATR = 0;
int totalFiltradosSpread = 0;
int totalFiltradosMaxOps = 0;

//--- Contador de análisis
int contadorAnalisis = 0;

//--- Estructura para almacenar FVG detectado
struct FVGData
{
   bool     valido;
   datetime tiempo;
   double   precioSuperior;
   double   precioInferior;
   double   precioMedio;
   bool     esBullish;
   int      barraCreacion;
};
FVGData fvgActual;

//--- Variables de control
datetime ultimaBarraAnalizada = 0;
int fileHandle = INVALID_HANDLE;
int contadorDebug = 0;
int operacionesHoy = 0;
datetime ultimoDiaContado = 0;

//+------------------------------------------------------------------+
//| Función de Inicialización del Expert Advisor                      |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Inicializar objeto de trading
   trade.SetExpertMagicNumber(expertMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   //--- Crear indicador ATR
   handleATR = iATR(_Symbol, _Period, InpATRPeriod);
   if(handleATR == INVALID_HANDLE)
   {
      Print("❌ ERROR: No se pudo crear el indicador ATR");
      return(INIT_FAILED);
   }

   //--- Crear indicadores EMA
   handleFastEMA = iMA(_Symbol, _Period, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handleFastEMA == INVALID_HANDLE)
   {
      Print("❌ ERROR: No se pudo crear el indicador EMA Rápida");
      return(INIT_FAILED);
   }

   handleSlowEMA = iMA(_Symbol, _Period, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handleSlowEMA == INVALID_HANDLE)
   {
      Print("❌ ERROR: No se pudo crear el indicador EMA Lenta");
      return(INIT_FAILED);
   }

   //--- Configurar buffers
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(fastEMABuffer, true);
   ArraySetAsSeries(slowEMABuffer, true);

   //--- Inicializar archivo CSV
   if(InpHabilitarCSV)
   {
      InicializarArchivoCSV();
   }

   //--- Inicializar estructuras
   ResetearFVG();

   Print("✅ EA Institucional Híbrido ICT + Brooks v3.1 OPTIMIZADO iniciado");
   Print("📊 Símbolo: ", _Symbol, " | Timeframe: ", EnumToString(_Period));
   Print("💰 Riesgo: ", InpRiskPercent, "% | R:R Mínimo: ", InpMinRiskReward, ":1");
   Print("🔧 FVG Mínimo: ", InpMinFVGSizeATR, " ATR | Timeout: ", InpFVGTimeoutBars, " barras");
   Print("🎯 Modo Debug: ", InpModoDebug ? "ACTIVADO" : "DESACTIVADO");

   //--- Iniciar el timer para la gestión de posiciones
   EventSetTimer(5); // El timer se activará cada 5 segundos

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Función OnTimer para gestionar Trailing Stops                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Cada vez que el timer se dispara, llamamos a la función de gestión
   GestionarTrailingStop();
}

//+------------------------------------------------------------------+
//| Lógica del Trailing Stop Dinámico Basado en ATR                   |
//+------------------------------------------------------------------+
void GestionarTrailingStop()
{
   // Necesitamos el ATR actual para el cálculo
   double atr_actual_trailing[1];
   if(CopyBuffer(handleATR, 0, 0, 1, atr_actual_trailing) < 1)
      return;

   double atr_val = atr_actual_trailing[0];

   // Iterar sobre todas las posiciones abiertas
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         // Asegurarse de que la posición pertenece a este EA y a este símbolo
         if(PositionGetInteger(POSITION_MAGIC) == expertMagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
            double current_sl = PositionGetDouble(POSITION_SL);
            long   position_type = PositionGetInteger(POSITION_TYPE);

            double nuevo_sl = current_sl;
            double distancia_trailing = atr_val * InpStopLossATR;

            //--- Lógica para posiciones de COMPRA (long)
            if(position_type == POSITION_TYPE_BUY)
            {
               // El nuevo SL potencial es el precio actual menos la distancia del ATR
               double sl_potencial = current_price - distancia_trailing;

               // Mover el SL solo si el nuevo SL es más alto que el precio de apertura
               // Y más alto que el SL actual (para no moverlo hacia atrás)
               if(sl_potencial > open_price && sl_potencial > current_sl)
               {
                  nuevo_sl = sl_potencial;
               }
            }
            //--- Lógica para posiciones de VENTA (short)
            else if(position_type == POSITION_TYPE_SELL)
            {
               // El nuevo SL potencial es el precio actual más la distancia del ATR
               double sl_potencial = current_price + distancia_trailing;

               // Mover el SL solo si el nuevo SL es más bajo que el precio de apertura
               // Y más bajo que el SL actual
               if(sl_potencial < open_price && (sl_potencial < current_sl || current_sl == 0))
               {
                  nuevo_sl = sl_potencial;
               }
            }

            // Si el nuevo SL es diferente al actual, modificar la posición
            if(nuevo_sl != current_sl)
            {
               // Normalizar el precio del SL antes de enviarlo
               int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
               nuevo_sl = NormalizeDouble(nuevo_sl, digits);

               if(trade.PositionModify(ticket, nuevo_sl, PositionGetDouble(POSITION_TP)))
               {
                  if(InpModoDebug)
                     Print(StringFormat("✅ Trailing Stop actualizado para #%d: %.5f", ticket, nuevo_sl));
               }
               else
               {
                  if(InpModoDebug)
                     Print(StringFormat("❌ Error al actualizar Trailing Stop para #%d: %d", ticket, GetLastError()));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Función de Desinicialización                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Detener el timer
   EventKillTimer();

   if(handleATR != INVALID_HANDLE)
      IndicatorRelease(handleATR);
   if(handleFastEMA != INVALID_HANDLE)
      IndicatorRelease(handleFastEMA);
   if(handleSlowEMA != INVALID_HANDLE)
      IndicatorRelease(handleSlowEMA);

   if(fileHandle != INVALID_HANDLE)
   {
      FileClose(fileHandle);
      fileHandle = INVALID_HANDLE;
   }

   //--- Mostrar estadísticas finales
   if(InpModoDebug)
   {
      Print("\n╔════════════════════════════════════════╗");
      Print("║     ESTADÍSTICAS FINALES DEBUG         ║");
      Print("╚════════════════════════════════════════╝");
      Print("📊 Total Análisis: ", contadorAnalisis);
      Print("🔍 FVGs Detectados: ", totalFVGsDetectados);
      Print("🎯 Retests Fallidos: ", totalRetestsFallidos);
      Print("❌ Velas Rechazadas: ", totalVelasRechazadas);
      Print("⚠️ R:R Rechazados: ", totalRRRechazados);
      Print("📉 Filtrados por ATR bajo: ", totalFiltradosATR);
      Print("📊 Filtrados por Spread: ", totalFiltradosSpread);
      Print("🚫 Filtrados por Max Ops: ", totalFiltradosMaxOps);
      Print("✅ Operaciones Ejecutadas: ", operacionesHoy);
      Print("════════════════════════════════════════");
   }

   Print("🛑 EA detenido | Razón: ", reason);
}

//+------------------------------------------------------------------+
//| Función Principal OnTick                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Actualizar panel cada 100 ticks
   contadorDebug++;
   if(contadorDebug % 100 == 0)
      ActualizarPanelDeInfo();

   //--- Verificar nueva barra
   if(!EsNuevaBarra())
      return;

   contadorAnalisis++;

   //--- Actualizar contador de operaciones diarias
   ActualizarContadorDiario();

   //--- Verificar límite de operaciones
   if(operacionesHoy >= InpMaxOperacionesDiarias)
   {
      totalFiltradosMaxOps++;
      estadoActual = STATE_FILTRADO;

      if(InpModoDebug && totalFiltradosMaxOps % 100 == 1)
         Print("🚫 Límite de operaciones diarias alcanzado: ", operacionesHoy, "/", InpMaxOperacionesDiarias);

      return;
   }

   //--- Actualizar indicadores
   if(CopyBuffer(handleATR, 0, 0, 3, atrBuffer) < 3)
      return;
   if(CopyBuffer(handleFastEMA, 0, 0, 3, fastEMABuffer) < 3)
      return;
   if(CopyBuffer(handleSlowEMA, 0, 0, 3, slowEMABuffer) < 3)
      return;

   double atrActual = atrBuffer[0];

   //--- Verificar ATR mínimo
   if(atrActual < InpMinATRPoints * _Point)
   {
      totalFiltradosATR++;
      estadoActual = STATE_FILTRADO;

      if(InpModoDebug && totalFiltradosATR % 100 == 1)
      {
         Print("📉 ATR muy bajo: ", DoubleToString(atrActual, 2),
               " | Mínimo: ", DoubleToString(InpMinATRPoints * _Point, 2));
      }

      return;
   }

   //--- Verificar filtros institucionales
   if(!VerificarFiltrosInstitucionales(atrActual))
   {
      estadoActual = STATE_FILTRADO;
      return;
   }

   //--- Máquina de Estados
   switch(estadoActual)
   {
      case STATE_BUSCANDO_SETUP_ICT:
         {
            BuscarSetupICT(atrActual);
         }
         break;

      case STATE_MONITOREANDO_FVG:
         {
            MonitorearFVGYBuscarSenal(atrActual);
         }
         break;

      case STATE_FILTRADO:
         {
            estadoActual = STATE_BUSCANDO_SETUP_ICT;
         }
         break;
   }
}

//+------------------------------------------------------------------+
//| Actualizar Contador Diario                                        |
//+------------------------------------------------------------------+
void ActualizarContadorDiario()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime hoy = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(hoy != ultimoDiaContado)
   {
      operacionesHoy = 0;
      ultimoDiaContado = hoy;
      Print("📅 Nuevo día | Contador de operaciones reseteado");
   }
}

//+------------------------------------------------------------------+
//| Actualizar Panel de Información                                    |
//+------------------------------------------------------------------+
void ActualizarPanelDeInfo()
{
   string info = "\n╔════════════════════════════════════════╗\n";
   info += "║   SISTEMA ICT + BROOKS v3.0 PROFIT     ║\n";
   info += "╚════════════════════════════════════════╝\n\n";

   //--- Estado
   string estadoTexto = "";
   switch(estadoActual)
   {
      case STATE_BUSCANDO_SETUP_ICT:
         {
            estadoTexto = "🔍 BUSCANDO SETUP ICT";
            info += "▸ Escaneando Fair Value Gaps...\n";
         }
         break;

      case STATE_MONITOREANDO_FVG:
         {
            estadoTexto = "👁️ MONITOREANDO FVG";
            info += "▸ FVG: " + (fvgActual.esBullish ? "ALCISTA ⬆️" : "BAJISTA ⬇️") + "\n";
            info += StringFormat("▸ Zona: %.2f - %.2f\n", fvgActual.precioInferior, fvgActual.precioSuperior);
            int barrasEsperando = Bars(_Symbol, _Period) - fvgActual.barraCreacion;
            info += StringFormat("▸ Esperando: %d/%d barras\n", barrasEsperando, InpFVGTimeoutBars);
         }
         break;

      case STATE_FILTRADO:
         {
            estadoTexto = "🚫 FILTRADO";
            info += "▸ Condiciones no óptimas\n";
         }
         break;
   }

   info += "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
   info += "🎯 ESTADO: " + estadoTexto + "\n";
   info += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

   //--- Métricas
   double atr = (CopyBuffer(handleATR, 0, 0, 1, atrBuffer) > 0) ? atrBuffer[0] : 0;
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double spreadPctATR = (atr > 0) ? (spread / atr) * 100.0 : 0;

   info += "📊 MÉTRICAS:\n";
   info += StringFormat("   ATR: %.2f\n", atr);
   info += StringFormat("   Spread: %.5f (%.1f%% ATR)\n", spread, spreadPctATR);
   info += StringFormat("   Ops Hoy: %d/%d\n", operacionesHoy, InpMaxOperacionesDiarias);
   info += StringFormat("   Posiciones: %d\n", PositionsTotal());

   if(InpModoDebug)
   {
      info += "\n📈 DEBUG:\n";
      info += StringFormat("   FVGs: %d\n", totalFVGsDetectados);
      info += StringFormat("   Retests Fallidos: %d\n", totalRetestsFallidos);
      info += StringFormat("   Velas Rechazadas: %d\n", totalVelasRechazadas);
      info += StringFormat("   R:R Rechazados: %d\n", totalRRRechazados);
   }

   Comment(info);
}

//+------------------------------------------------------------------+
//| Verificar Nueva Barra                                             |
//+------------------------------------------------------------------+
bool EsNuevaBarra()
{
   datetime tiempoActual = iTime(_Symbol, _Period, 0);
   if(tiempoActual != ultimaBarraAnalizada)
   {
      ultimaBarraAnalizada = tiempoActual;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Verificar Regimen de Mercado (Tendencia)                          |
//+------------------------------------------------------------------+
bool VerificarRegimenDeMercado(bool esSetupBullish)
{
   if(!InpUsarFiltroRegimen)
      return true; // Si el filtro está desactivado, siempre es válido

   double fastEMA_actual = fastEMABuffer[1];
   double slowEMA_actual = slowEMABuffer[1];

   // Lógica del filtro:
   // Para setups ALCISTAS (bullish), la EMA rápida debe estar POR ENCIMA de la lenta.
   if(esSetupBullish && fastEMA_actual < slowEMA_actual)
      return false; // Bloquear compra en tendencia bajista

   // Para setups BAJISTAS (bearish), la EMA rápida debe estar POR DEBAJO de la lenta.
   if(!esSetupBullish && fastEMA_actual > slowEMA_actual)
      return false; // Bloquear venta en tendencia alcista

   return true; // El setup está alineado con la tendencia
}

//+------------------------------------------------------------------+
//| Verificar Filtros Institucionales                                 |
//+------------------------------------------------------------------+
bool VerificarFiltrosInstitucionales(double atr)
{
   //--- Filtro Killzones
   if(InpUsarKillzones && !VerificarKillzone())
      return false;

   //--- Filtro Spread (OPCIONAL)
   if(InpUsarFiltroSpread)
   {
      double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
      double maxSpread = atr * (InpMaxSpreadATRPct / 100.0);

      if(spread > maxSpread)
      {
         totalFiltradosSpread++;

         if(InpModoDebug && totalFiltradosSpread % 50 == 1)
         {
            Print("📊 Spread alto: ", DoubleToString(spread, 5),
                  " | Max: ", DoubleToString(maxSpread, 5),
                  " (", InpMaxSpreadATRPct, "% ATR)");
         }

         RegistrarEnCSV("Spread Excesivo", spread, atr, 0, 0, "Filtrado");
         return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Verificar Killzone                                                |
//+------------------------------------------------------------------+
bool VerificarKillzone()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hora = dt.hour;

   bool enLondres = (hora >= InpHoraInicioLondres && hora < InpHoraFinLondres);
   bool enNY = (hora >= InpHoraInicioNY && hora < InpHoraFinNY);

   return (enLondres || enNY);
}

//+------------------------------------------------------------------+
//| Buscar Setup ICT: Market Structure Shift + FVG                    |
//+------------------------------------------------------------------+
void BuscarSetupICT(double atr)
{
    if(fvgActual.valido) return; // Si ya tenemos un FVG, no buscar más

    MqlRates rates[];
    if(CopyRates(_Symbol, _Period, 0, 200, rates) < 200) return;

    double p0_val, p1_val, p2_val;
    int p0_idx, p1_idx, p2_idx;

    // Usar el cálculo de ZigZag interno que es más robusto
    CalcularPuntosZigZagInterno(rates, InpZigZagDepth, InpZigZagDeviation, InpZigZagBackstep, p0_val, p0_idx, p1_val, p1_idx, p2_val, p2_idx);

    if(p0_idx <= 0 || p1_idx <= 0 || p2_idx <= 0) return;

    // Detectar Market Structure Shift (MSS)
    bool mssBullish = (p1_val < p0_val && p1_val < p2_val && p0_val > p2_val);
    bool mssBearish = (p1_val > p0_val && p1_val > p2_val && p0_val < p2_val);

    if(mssBullish && VerificarRegimenDeMercado(true))
    {
        if(InpModoDebug) Print("📈 MSS Alcista detectado. Buscando FVG...");
        BuscarFVGPostMSS(rates, p1_idx, p0_idx, true, atr);
    }
    else if(mssBearish && VerificarRegimenDeMercado(false))
    {
        if(InpModoDebug) Print("📉 MSS Bajista detectado. Buscando FVG...");
        BuscarFVGPostMSS(rates, p1_idx, p0_idx, false, atr);
    }
}

//+------------------------------------------------------------------+
//| Buscar FVG después de un MSS confirmado                           |
//+------------------------------------------------------------------+
void BuscarFVGPostMSS(const MqlRates &rates[], int idx_inicio_swing, int idx_fin_swing, bool esBullish, double atr)
{
    double minFVGSize = atr * InpMinFVGSizeATR;

    for(int i = idx_fin_swing; i > idx_inicio_swing && i >= 2; i--)
    {
        if(esBullish)
        {
            if(rates[i].high < rates[i-2].low) // FVG alcista
            {
                double fvg_top = rates[i-2].low;
                double fvg_bottom = rates[i].high;
                if(fvg_top - fvg_bottom >= minFVGSize)
                {
                    fvgActual.valido = true;
                    fvgActual.precioSuperior = fvg_top;
                    fvgActual.precioInferior = fvg_bottom;
                    fvgActual.precioMedio = (fvg_top + fvg_bottom) / 2;
                    fvgActual.esBullish = true;
                    fvgActual.barraCreacion = Bars(_Symbol, _Period);

                    estadoActual = STATE_MONITOREANDO_FVG;
                    totalFVGsDetectados++;
                    Print("✅ FVG ALCISTA VÁLIDO ENCONTRADO post-MSS.");
                    return;
                }
            }
        }
        else // esBearish
        {
            if(rates[i].low > rates[i-2].high) // FVG bajista
            {
                double fvg_top = rates[i-2].high;
                double fvg_bottom = rates[i].low;
                if(fvg_top - fvg_bottom >= minFVGSize)
                {
                    fvgActual.valido = true;
                    fvgActual.precioSuperior = fvg_top;
                    fvgActual.precioInferior = fvg_bottom;
                    fvgActual.precioMedio = (fvg_top + fvg_bottom) / 2;
                    fvgActual.esBullish = false;
                    fvgActual.barraCreacion = Bars(_Symbol, _Period);

                    estadoActual = STATE_MONITOREANDO_FVG;
                    totalFVGsDetectados++;
                    Print("✅ FVG BAJISTA VÁLIDO ENCONTRADO post-MSS.");
                    return;
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Monitorear FVG y Buscar Señal                                     |
//+------------------------------------------------------------------+
void MonitorearFVGYBuscarSenal(double atr)
{
   //--- Timeout
   int barrasDesdeDeteccion = Bars(_Symbol, _Period) - fvgActual.barraCreacion;
   if(barrasDesdeDeteccion > InpFVGTimeoutBars)
   {
      Print("⏱️ FVG Timeout");
      RegistrarEnCSV("FVG Timeout", 0, atr, 0, 0, "Timeout");
      ResetearFVG();
      estadoActual = STATE_BUSCANDO_SETUP_ICT;
      return;
   }

   //--- Verificar retorno al FVG
   double high1 = iHigh(_Symbol, _Period, 1);
   double low1 = iLow(_Symbol, _Period, 1);
   double close1 = iClose(_Symbol, _Period, 1);

   double tolerancia = atr * InpFVGRetestTolerance;
   bool haRetornado = false;

   if(fvgActual.esBullish)
   {
      haRetornado = (low1 <= (fvgActual.precioSuperior + tolerancia) &&
                     low1 >= (fvgActual.precioInferior - tolerancia));
   }
   else
   {
      haRetornado = (high1 >= (fvgActual.precioInferior - tolerancia) &&
                     high1 <= (fvgActual.precioSuperior + tolerancia));
   }

   if(!haRetornado)
   {
      totalRetestsFallidos++;
      return;
   }

   if(InpModoDebug)
      Print("🎯 Precio retornó al FVG | Buscando vela de señal...");

   //--- Buscar vela de señal
   if(EsVelaDeSenalMejorada(atr, fvgActual.esBullish, 1))
   {
      if(InpModoDebug)
         Print("✅ Vela de Señal válida");

      EjecutarOrdenMejorada(atr);

      ResetearFVG();
      estadoActual = STATE_BUSCANDO_SETUP_ICT;
   }
   else
   {
      totalVelasRechazadas++;
      if(InpModoDebug)
         Print("❌ Vela de señal rechazada");
   }
}

//+------------------------------------------------------------------+
//| Vela de Señal Mejorada                                            |
//+------------------------------------------------------------------+
bool EsVelaDeSenalMejorada(double atr, bool buscarAlcista, int barraIndex)
{
   double open = iOpen(_Symbol, _Period, barraIndex);
   double high = iHigh(_Symbol, _Period, barraIndex);
   double low = iLow(_Symbol, _Period, barraIndex);
   double close = iClose(_Symbol, _Period, barraIndex);

   double cuerpo = MathAbs(close - open);
   double rango = high - low;

   if(rango == 0) return false;

   double porcentajeCuerpo = (cuerpo / rango) * 100.0;

   //--- Verificar tamaño
   if(rango < atr * InpSignalBarMinSizeATR)
      return false;

   //--- Verificar cuerpo
   if(porcentajeCuerpo < InpSignalBarMinBodyPct)
      return false;

   //--- Verificar dirección y cierre
   if(buscarAlcista)
   {
      if(close <= open) return false;

      if(InpRequireCloseNearExtreme)
      {
         // Para una señal alcista fuerte, el cierre debe estar en el tercio superior de la vela
         double tercio_superior = high - (rango / 3.0);
         if(close < tercio_superior) return false;
      }
   }
   else // Buscando bajista
   {
      if(close >= open) return false;

      if(InpRequireCloseNearExtreme)
      {
         // Para una señal bajista fuerte, el cierre debe estar en el tercio inferior de la vela
         double tercio_inferior = low + (rango / 3.0);
         if(close > tercio_inferior) return false;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| Ejecutar Orden Mejorada                                           |
//+------------------------------------------------------------------+
void EjecutarOrdenMejorada(double atr)
{
   //--- Verificar posiciones (OPCIONAL)
   if(!InpPermitirMultiplesPosiciones && PositionsTotal() > 0)
   {
      Print("⚠️ Ya hay posiciones abiertas (múltiples posiciones desactivadas)");
      return;
   }

   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double precio, sl, tp;

   //--- Calcular niveles
   if(fvgActual.esBullish)
   {
      precio = iHigh(_Symbol, _Period, 1) + spread * 2;
      sl = fvgActual.precioInferior - (atr * InpStopLossATR);
      tp = 0; // TP se gestiona con Trailing Stop, no se establece aquí
   }
   else
   {
      precio = iLow(_Symbol, _Period, 1) - spread * 2;
      sl = fvgActual.precioSuperior + (atr * InpStopLossATR);
      tp = 0; // TP se gestiona con Trailing Stop, no se establece aquí
   }

   //--- Verificar Risk:Reward (usando un TP hipotético para el cálculo)
   double distanciaSL = MathAbs(precio - sl);
   double hipoteticoTP = fvgActual.esBullish ? precio + (distanciaSL * InpTakeProfitRatio) : precio - (distanciaSL * InpTakeProfitRatio);
   double distanciaTP = MathAbs(hipoteticoTP - precio);

   if (distanciaSL == 0) return; // Evitar división por cero
   double riskReward = distanciaTP / distanciaSL;

   if(riskReward < InpMinRiskReward)
   {
      totalRRRechazados++;

      if(InpModoDebug)
      {
         Print("⚠️ R:R insuficiente: ", DoubleToString(riskReward, 2),
               " | Mínimo: ", DoubleToString(InpMinRiskReward, 2));
      }

      RegistrarEnCSV("R:R Insuficiente", spread, atr, precio, 0,
                     StringFormat("RR=%.2f", riskReward));
      return;
   }

   //--- Normalizar
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   precio = NormalizeDouble(precio, digits);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   //--- Calcular lotaje
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riesgoMonetario = balance * (InpRiskPercent / 100.0);

   double lotaje = 0;
   if(tickSize > 0 && tickValue > 0)
   {
      lotaje = riesgoMonetario / ((distanciaSL / tickSize) * tickValue);
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lotaje = MathMax(minLot, lotaje);
   lotaje = MathMin(maxLot, lotaje);
   lotaje = MathFloor(lotaje / stepLot) * stepLot;
   lotaje = NormalizeDouble(lotaje, 2);

   if(lotaje < minLot)
      lotaje = minLot;

   //--- Ejecutar orden
   bool resultado = false;
   string comentario = StringFormat("ICT R:R=%.1f", riskReward);

   if(fvgActual.esBullish)
   {
      resultado = trade.BuyStop(lotaje, precio, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comentario);
   }
   else
   {
      resultado = trade.SellStop(lotaje, precio, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comentario);
   }

   if(resultado)
   {
      operacionesHoy++;
      Print("✅ ORDEN EJECUTADA");
      Print("   Tipo: ", fvgActual.esBullish ? "BUY STOP" : "SELL STOP");
      Print("   Lotaje: ", lotaje, " | R:R: ", DoubleToString(riskReward, 2));
      Print("   Precio: ", precio, " | SL: ", sl, " | TP: ", tp);
      RegistrarEnCSV("Orden Colocada", spread, atr, precio, lotaje, "Placed");
   }
   else
   {
      Print("❌ Error: ", GetLastError(), " | ", trade.ResultRetcodeDescription());
      RegistrarEnCSV("Error Orden", spread, atr, precio, lotaje, "Failed");
   }
}

//+------------------------------------------------------------------+
//| Inicializar CSV                                                   |
//+------------------------------------------------------------------+
void InicializarArchivoCSV()
{
   string ruta = "TradeLog_Institutional_Hybrid.csv";
   fileHandle = FileOpen(ruta, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');

   if(fileHandle != INVALID_HANDLE)
   {
      FileWrite(fileHandle, "Timestamp", "Event", "Spread", "ATR", "Price", "Lotsize", "Result");
      FileClose(fileHandle);
      fileHandle = INVALID_HANDLE;
      Print("📄 CSV inicializado: ", ruta);
   }
   else
   {
      Print("❌ Error CSV: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Registrar en CSV                                                  |
//+------------------------------------------------------------------+
void RegistrarEnCSV(string evento, double spread, double atr, double precio, double lotaje, string resultado)
{
   if(!InpHabilitarCSV)
      return;

   fileHandle = FileOpen("TradeLog_Institutional_Hybrid.csv", FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');

   if(fileHandle != INVALID_HANDLE)
   {
      FileSeek(fileHandle, 0, SEEK_END);
      FileWrite(fileHandle,
                TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
                evento,
                DoubleToString(spread, 5),
                DoubleToString(atr, 5),
                DoubleToString(precio, 5),
                DoubleToString(lotaje, 2),
                resultado);
      FileClose(fileHandle);
      fileHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
//| Resetear FVG                                                      |
//+------------------------------------------------------------------+
void ResetearFVG()
{
   fvgActual.valido = false;
   fvgActual.tiempo = 0;
   fvgActual.precioSuperior = 0;
   fvgActual.precioInferior = 0;
   fvgActual.precioMedio = 0;
   fvgActual.esBullish = false;
   fvgActual.barraCreacion = 0;
}
//+------------------------------------------------------------------+
//| OBTENER PUNTOS ZIGZAG (HELPER)                                     |
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
//| CÁLCULO INTERNO DEL ZIGZAG (VERSIÓN ROBUSTA Y CORREGIDA)           |
//+------------------------------------------------------------------+
void CalcularPuntosZigZagInterno(const MqlRates &rates[], int depth, int deviation, int backstep,
                                 double &p0_val, int &p0_idx,
                                 double &p1_val, int &p1_idx,
                                 double &p2_val, int &p2_idx)
{
    p0_val=0; p0_idx=0; p1_val=0; p1_idx=0; p2_val=0; p2_idx=0;
    int    rates_total = ArraySize(rates);
    if(rates_total < depth) return;

    double zigzag_buffer[], high_buffer[], low_buffer[];
    ArrayResize(zigzag_buffer, rates_total);
    ArrayResize(high_buffer, rates_total);
    ArrayResize(low_buffer, rates_total);

    for(int i = 0; i < rates_total; i++)
    {
        double highest_high = rates[i].high;
        double lowest_low = rates[i].low;
        int limit = MathMin(i + depth, rates_total - 1);
        for(int k = i + 1; k <= limit; k++)
        {
            if(rates[k].high > highest_high) highest_high = rates[k].high;
            if(rates[k].low < lowest_low) lowest_low = rates[k].low;
        }
        high_buffer[i] = highest_high;
        low_buffer[i] = lowest_low;
    }

    double last_high = 0;
    int    last_high_pos = 0;
    double last_low = 0;
    int    last_low_pos = 0;
    int    direction = 0;

    for(int i = rates_total - 2; i >= 0; i--)
    {
        //--- check for high
        if(high_buffer[i] == rates[i].high)
        {
            bool is_high = true;
            int back_limit = MathMin(i + backstep, rates_total - 1);
            for(int k = i + 1; k <= back_limit; k++)
            {
                if(rates[k].high > rates[i].high)
                {
                    is_high = false;
                    break;
                }
            }

            if(is_high)
            {
                if(direction != 1)
                {
                    if(last_high != 0 && last_high < rates[i].high && last_low != 0)
                        zigzag_buffer[last_high_pos] = 0;
                }

                if(last_high == 0 || last_high < rates[i].high)
                {
                    last_high = rates[i].high;
                    last_high_pos = i;
                    zigzag_buffer[i] = last_high;
                    direction = 1;
                    if(last_low != 0)
                    {
                        if(last_high - last_low >= deviation * _Point)
                        {
                            last_low = 0;
                        }
                    }
                }
            }
        }
        //--- check for low
        if(low_buffer[i] == rates[i].low)
        {
            bool is_low = true;
            int back_limit = MathMin(i + backstep, rates_total - 1);
            for(int k = i + 1; k <= back_limit; k++)
            {
                if(rates[k].low < rates[i].low)
                {
                    is_low = false;
                    break;
                }
            }
            if(is_low)
            {
                if(direction != -1)
                {
                    if(last_low != 0 && last_low > rates[i].low && last_high != 0)
                        zigzag_buffer[last_low_pos] = 0;
                }

                if(last_low == 0 || last_low > rates[i].low)
                {
                    last_low = rates[i].low;
                    last_low_pos = i;
                    zigzag_buffer[i] = last_low;
                    direction = -1;
                    if(last_high != 0)
                    {
                        if(last_high - last_low >= deviation * _Point)
                        {
                            last_high = 0;
                        }
                    }
                }
            }
        }
    }

    // Ahora, extraemos los últimos 3 puntos del buffer calculado, igual que antes.
    ObtenerPuntosZigZag(zigzag_buffer, rates_total, p0_val, p0_idx, p1_val, p1_idx, p2_val, p2_idx);
}
//+------------------------------------------------------------------+