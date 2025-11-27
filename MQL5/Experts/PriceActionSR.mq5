//+------------------------------------------------------------------+
//|                                                PriceActionSR.mq5 |
//|                      Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "4.00"
#property description "EA con GUI, cruce estricto y filtros anti-fakeout para S/R."

//--- Parámetros de entrada
input group             "Análisis de Zonas"
input int               InpLookBackPeriod = 500;
input int               InpSwingPeriod    = 5;
input int               InpMinTouches     = 3;
input group             "Filtro de Volatilidad (ATR)"
input int               InpATRPeriod      = 14;
input double            InpATRMultiplier  = 1.0;
input double            InpBreakoutMargin = 0.2;    // Margen extra (multiplicador de ATR) para confirmar ruptura

//--- Estructuras
enum ENUM_LEVEL_TYPE { SUPPORT, RESISTANCE };
struct PriceLevel
  {
   double            price;
   int               touches;
   ENUM_LEVEL_TYPE   level_type;
  };

//--- Variables Globales
datetime   g_lastBarTime;
PriceLevel g_validated_levels[];
int        g_atr_handle;
double     g_current_atr_multiplier; // Multiplicador interno para la GUI

//--- Prototipos de funciones de GUI
void CreateInteractiveDashboard();
void UpdateDashboardText();

//+------------------------------------------------------------------+
//| Función de inicialización del EA                                 |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_lastBarTime = 0;
   g_current_atr_multiplier = InpATRMultiplier;

   g_atr_handle = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
     {
      Print("Error al crear el handle del indicador ATR.");
      return(INIT_FAILED);
     }

   Print("PriceActionSR EA v4.0 (Anti-Fakeout) inicializado.");
   CreateInteractiveDashboard();
   DrawSRLevels();
   UpdateDashboardText();

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Función de desinicialización del EA                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, "SR_GUI_");
   ObjectsDeleteAll(0, "SR_Level_");
   ObjectsDeleteAll(0, "SR_Arrow_");
   IndicatorRelease(g_atr_handle);
   ChartRedraw();
   Print("PriceActionSR EA desinicializado.");
  }
//+------------------------------------------------------------------+
//| Función de Tick del EA                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime > g_lastBarTime)
     {
      g_lastBarTime = currentBarTime;
      DrawSRLevels();
      CheckForBreakouts();
      UpdateDashboardText();
     }
  }
//+------------------------------------------------------------------+
//| Manejador de eventos del gráfico (para la GUI)                   |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == "SR_GUI_Btn_Minus")
        {
         g_current_atr_multiplier -= 0.1;
         if(g_current_atr_multiplier < 0.1) g_current_atr_multiplier = 0.1;
         Print("ATR Multiplier cambiado a: ", g_current_atr_multiplier);
         DrawSRLevels();
         UpdateDashboardText();
         ChartRedraw();
        }
      if(sparam == "SR_GUI_Btn_Plus")
        {
         g_current_atr_multiplier += 0.1;
         Print("ATR Multiplier cambiado a: ", g_current_atr_multiplier);
         DrawSRLevels();
         UpdateDashboardText();
         ChartRedraw();
        }
      if(sparam == "SR_GUI_Btn_Reset")
        {
         g_current_atr_multiplier = InpATRMultiplier;
         Print("ATR Multiplier reseteado a: ", g_current_atr_multiplier);
         DrawSRLevels();
         UpdateDashboardText();
         ChartRedraw();
        }
     }
  }
//+------------------------------------------------------------------+
//| Lógica principal de cálculo de niveles                           |
//+------------------------------------------------------------------+
void DrawSRLevels()
  {
   ObjectsDeleteAll(0, "SR_Level_");
   ObjectsDeleteAll(0, "SR_Arrow_");
   ArrayFree(g_validated_levels);

   double high[], low[];
   if(CopyHigh(_Symbol, _Period, 0, InpLookBackPeriod, high) < InpLookBackPeriod ||
      CopyLow(_Symbol, _Period, 0, InpLookBackPeriod, low) < InpLookBackPeriod)
      return;
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   PriceLevel potential_levels[];
   int levels_count = 0;
   for(int i = InpSwingPeriod; i < InpLookBackPeriod - InpSwingPeriod; i++)
     {
      bool is_swing_high = true, is_swing_low = true;
      for(int j = 1; j <= InpSwingPeriod; j++)
        {
         if(high[i] < high[i - j] || high[i] < high[i + j]) is_swing_high = false;
         if(low[i] > low[i - j] || low[i] > low[i + j]) is_swing_low = false;
        }
      if(is_swing_high)
        {
         ArrayResize(potential_levels, levels_count + 1);
         potential_levels[levels_count].price = high[i];
         potential_levels[levels_count].level_type = RESISTANCE;
         levels_count++;
        }
      if(is_swing_low)
        {
         ArrayResize(potential_levels, levels_count + 1);
         potential_levels[levels_count].price = low[i];
         potential_levels[levels_count].level_type = SUPPORT;
         levels_count++;
        }
     }

   double atr_buffer[];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buffer) < 1) return;
   double tolerance = atr_buffer[0] * g_current_atr_multiplier;
   PrintFormat("ATR Actual: %.5f | Tolerancia Calculada: %.5f", atr_buffer[0], tolerance);

   PriceLevel grouped_levels[];
   int grouped_count = 0;
   for(int i = 0; i < levels_count; i++)
     {
      bool is_grouped = false;
      for(int j = 0; j < grouped_count; j++)
        {
         if(potential_levels[i].level_type == grouped_levels[j].level_type &&
            MathAbs(potential_levels[i].price - grouped_levels[j].price) <= tolerance)
           {
            is_grouped = true;
            break;
           }
        }
      if(!is_grouped)
        {
         ArrayResize(grouped_levels, grouped_count + 1);
         grouped_levels[grouped_count] = potential_levels[i];
         grouped_count++;
        }
     }

   for(int i = 0; i < grouped_count; i++)
     {
      grouped_levels[i].touches = 0;
      for(int k = 0; k < InpLookBackPeriod; k++)
        {
         if(grouped_levels[i].level_type == RESISTANCE && MathAbs(high[k] - grouped_levels[i].price) <= tolerance)
            grouped_levels[i].touches++;
         else if(grouped_levels[i].level_type == SUPPORT && MathAbs(low[k] - grouped_levels[i].price) <= tolerance)
            grouped_levels[i].touches++;
        }
     }

   int validated_count = 0;
   for(int i = 0; i < grouped_count; i++)
     {
      string type_str = (grouped_levels[i].level_type == SUPPORT) ? "Soporte" : "Resistencia";
      PrintFormat("Nivel Candidato (%s): %.5f, Toques: %d", type_str, grouped_levels[i].price, grouped_levels[i].touches);
      if(grouped_levels[i].touches >= InpMinTouches)
        {
         ArrayResize(g_validated_levels, validated_count + 1);
         g_validated_levels[validated_count] = grouped_levels[i];
         validated_count++;
        }
     }
   DrawValidatedLevels();
  }
//+------------------------------------------------------------------+
//| Dibuja las líneas de los niveles validados                       |
//+------------------------------------------------------------------+
void DrawValidatedLevels()
  {
   for(int i = 0; i < ArraySize(g_validated_levels); i++)
     {
      string name = "SR_Level_" + IntegerToString(i);
      int width = (g_validated_levels[i].touches >= 5) ? 3 : 1;
      color line_color = (g_validated_levels[i].level_type == RESISTANCE) ? clrBlue : clrRed;
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_validated_levels[i].price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, line_color);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, "Toques: " + IntegerToString(g_validated_levels[i].touches));
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
  }
//+------------------------------------------------------------------+
//| Lógica de Breakout con Filtros Anti-Fakeout                      |
//+------------------------------------------------------------------+
void CheckForBreakouts()
  {
   if(ArraySize(g_validated_levels) == 0) return;

   //--- 1. Obtener todos los datos necesarios al inicio
   MqlRates rates[];
   if(CopyRates(_Symbol, _Period, 1, 2, rates) < 2) return;

   double atr_buffer[];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, atr_buffer) < 1) return;
   double atr_value = atr_buffer[0];

   //--- Datos de la vela de ruptura (índice 1 del historial, pero 0 en nuestro array 'rates')
   double open1  = rates[0].open;
   double high1  = rates[0].high;
   double low1   = rates[0].low;
   double close1 = rates[0].close;

   //--- Datos de la vela anterior (índice 2 del historial, pero 1 en nuestro array 'rates')
   double close2 = rates[1].close;

   //--- 2. Aplicar Filtros de Calidad de Vela
   double total_size = high1 - low1;
   double body_size = MathAbs(close1 - open1);

   //--- Filtro de Rechazo de Mecha: si el cuerpo es menor al 50% del total, es una vela débil.
   if(total_size > 0 && body_size < (total_size * 0.5))
     {
      // Print("Señal de breakout ignorada por vela de indecisión (mecha larga).");
      return; // Ignorar esta vela para cualquier breakout
     }

   //--- 3. Iterar sobre los niveles y aplicar filtros de cruce y margen
   for(int i = 0; i < ArraySize(g_validated_levels); i++)
     {
      PriceLevel level = g_validated_levels[i];
      double margin = atr_value * InpBreakoutMargin;

      //--- Validación para COMPRA (Ruptura de Resistencia)
      if(level.level_type == RESISTANCE)
        {
         // Filtro 1: Cruce Estricto
         bool is_crossover = (close1 > level.price && close2 < level.price);
         // Filtro 2: Margen de Ruptura ATR
         bool has_margin = (close1 > (level.price + margin));

         if(is_crossover && has_margin)
           {
            string name = "SR_Arrow_Buy_" + TimeToString(rates[0].time, TIME_MINUTES) + "_" + DoubleToString(level.price);
            ObjectCreate(0, name, OBJ_ARROW_BUY, 0, rates[0].time, low1 - atr_value * 0.2);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
            Alert("Alerta de Compra: Ruptura confirmada de Resistencia en " + DoubleToString(level.price, _Digits));
           }
        }
      //--- Validación para VENTA (Ruptura de Soporte)
      else if(level.level_type == SUPPORT)
        {
         // Filtro 1: Cruce Estricto
         bool is_crossover = (close1 < level.price && close2 > level.price);
         // Filtro 2: Margen de Ruptura ATR
         bool has_margin = (close1 < (level.price - margin));

         if(is_crossover && has_margin)
           {
            string name = "SR_Arrow_Sell_" + TimeToString(rates[0].time, TIME_MINUTES) + "_" + DoubleToString(level.price);
            ObjectCreate(0, name, OBJ_ARROW_SELL, 0, rates[0].time, high1 + atr_value * 0.2);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
            Alert("Alerta de Venta: Ruptura confirmada de Soporte en " + DoubleToString(level.price, _Digits));
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Crea los elementos estáticos de la GUI                           |
//+------------------------------------------------------------------+
void CreateInteractiveDashboard()
  {
   //--- Fondo
   ObjectCreate(0, "SR_GUI_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "SR_GUI_BG", OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, "SR_GUI_BG", OBJPROP_YDISTANCE, 15);
   ObjectSetInteger(0, "SR_GUI_BG", OBJPROP_XSIZE, 220);
   ObjectSetInteger(0, "SR_GUI_BG", OBJPROP_YSIZE, 100);
   ObjectSetInteger(0, "SR_GUI_BG", OBJPROP_BGCOLOR, C'40,40,40');
   ObjectSetInteger(0, "SR_GUI_BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "SR_GUI_BG", OBJPROP_BACK, true);

   //--- Labels Estáticos
   string labels[] = {"Soportes:", "Resistencias:", "ATR Multiplier:"};
   for(int i = 0; i < ArraySize(labels); i++)
     {
      string name = "SR_GUI_Label_" + labels[i];
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetString(0, name, OBJPROP_TEXT, labels[i]);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 25 + i * 20);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrLightGray);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }

   //--- Labels Dinámicos (solo se crean, se actualizan en UpdateDashboardText)
   ObjectCreate(0, "SR_GUI_Val_Supports", OBJ_LABEL, 0, 0, 0);
   ObjectCreate(0, "SR_GUI_Val_Resistances", OBJ_LABEL, 0, 0, 0);
   ObjectCreate(0, "SR_GUI_Val_Multiplier", OBJ_LABEL, 0, 0, 0);

   //--- Botones
   int y_pos = 90;
   ObjectCreate(0, "SR_GUI_Btn_Minus", OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, "SR_GUI_Btn_Minus", OBJPROP_TEXT, "- 0.1");
   ObjectSetInteger(0, "SR_GUI_Btn_Minus", OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, "SR_GUI_Btn_Minus", OBJPROP_YDISTANCE, y_pos);
   ObjectSetInteger(0, "SR_GUI_Btn_Minus", OBJPROP_XSIZE, 50);
   ObjectSetInteger(0, "SR_GUI_Btn_Minus", OBJPROP_YSIZE, 20);

   ObjectCreate(0, "SR_GUI_Btn_Plus", OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, "SR_GUI_Btn_Plus", OBJPROP_TEXT, "+ 0.1");
   ObjectSetInteger(0, "SR_GUI_Btn_Plus", OBJPROP_XDISTANCE, 80);
   ObjectSetInteger(0, "SR_GUI_Btn_Plus", OBJPROP_YDISTANCE, y_pos);
   ObjectSetInteger(0, "SR_GUI_Btn_Plus", OBJPROP_XSIZE, 50);
   ObjectSetInteger(0, "SR_GUI_Btn_Plus", OBJPROP_YSIZE, 20);

   ObjectCreate(0, "SR_GUI_Btn_Reset", OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, "SR_GUI_Btn_Reset", OBJPROP_TEXT, "RESET");
   ObjectSetInteger(0, "SR_GUI_Btn_Reset", OBJPROP_XDISTANCE, 140);
   ObjectSetInteger(0, "SR_GUI_Btn_Reset", OBJPROP_YDISTANCE, y_pos);
   ObjectSetInteger(0, "SR_GUI_Btn_Reset", OBJPROP_XSIZE, 80);
   ObjectSetInteger(0, "SR_GUI_Btn_Reset", OBJPROP_YSIZE, 20);
  }
//+------------------------------------------------------------------+
//| Actualiza el texto de los elementos dinámicos de la GUI          |
//+------------------------------------------------------------------+
void UpdateDashboardText()
  {
   int support_count = 0, resistance_count = 0;
   for(int i = 0; i < ArraySize(g_validated_levels); i++)
     {
      if(g_validated_levels[i].level_type == SUPPORT) support_count++;
      else resistance_count++;
     }

   string names[] = {"SR_GUI_Val_Supports", "SR_GUI_Val_Resistances", "SR_GUI_Val_Multiplier"};
   string values[] = {(string)support_count, (string)resistance_count, DoubleToString(g_current_atr_multiplier, 2)};

   for(int i=0; i < ArraySize(names); i++)
     {
      ObjectSetString(0, names[i], OBJPROP_TEXT, values[i]);
      ObjectSetInteger(0, names[i], OBJPROP_XDISTANCE, 150);
      ObjectSetInteger(0, names[i], OBJPROP_YDISTANCE, 25 + i * 20);
      ObjectSetInteger(0, names[i], OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, names[i], OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, names[i], OBJPROP_BACK, false);
     }
  }
//+------------------------------------------------------------------+
// Legacy UpdateDashboard function is no longer needed and has been replaced by Create and UpdateText
