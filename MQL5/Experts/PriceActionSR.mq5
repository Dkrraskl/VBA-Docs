//+------------------------------------------------------------------+
//|                                                PriceActionSR.mq5 |
//|                      Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "3.00"
#property description "EA con GUI interactiva y cruce estricto para S/R en mercados volátiles."

//--- Parámetros de entrada
input group             "Análisis de Zonas"
input int               InpLookBackPeriod = 500;
input int               InpSwingPeriod    = 5;
input int               InpMinTouches     = 3;
input group             "Filtro de Volatilidad (ATR)"
input int               InpATRPeriod      = 14;
input double            InpATRMultiplier  = 1.0;

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

   Print("PriceActionSR EA v3.0 (Interactive) inicializado.");
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
      //--- Botón de disminuir multiplicador
      if(sparam == "SR_GUI_Btn_Minus")
        {
         g_current_atr_multiplier -= 0.1;
         if(g_current_atr_multiplier < 0.1) g_current_atr_multiplier = 0.1;
         Print("ATR Multiplier cambiado a: ", g_current_atr_multiplier);
         DrawSRLevels();
         UpdateDashboardText();
         ChartRedraw();
        }
      //--- Botón de aumentar multiplicador
      if(sparam == "SR_GUI_Btn_Plus")
        {
         g_current_atr_multiplier += 0.1;
         Print("ATR Multiplier cambiado a: ", g_current_atr_multiplier);
         DrawSRLevels();
         UpdateDashboardText();
         ChartRedraw();
        }
      //--- Botón de Reset
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
//| Lógica de Cruce Estricto                                         |
//+------------------------------------------------------------------+
void CheckForBreakouts()
  {
   if(ArraySize(g_validated_levels) == 0) return;

   double close[];
   if(CopyClose(_Symbol, _Period, 1, 2, close) < 2) return;

   for(int i = 0; i < ArraySize(g_validated_levels); i++)
     {
      PriceLevel level = g_validated_levels[i];
      if(level.level_type == RESISTANCE && close[0] > level.price && close[1] < level.price)
        {
         string name = "SR_Arrow_Buy_" + TimeToString(iTime(_Symbol, _Period, 1), TIME_MINUTES) + "_" + DoubleToString(level.price);
         double low[];
         CopyLow(_Symbol, _Period, 1, 1, low);
         ObjectCreate(0, name, OBJ_ARROW_BUY, 0, iTime(_Symbol, _Period, 1), low[0] - _Point * 10);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlue);
        }
      if(level.level_type == SUPPORT && close[0] < level.price && close[1] > level.price)
        {
         string name = "SR_Arrow_Sell_" + TimeToString(iTime(_Symbol, _Period, 1), TIME_MINUTES) + "_" + DoubleToString(level.price);
         double high[];
         CopyHigh(_Symbol, _Period, 1, 1, high);
         ObjectCreate(0, name, OBJ_ARROW_SELL, 0, iTime(_Symbol, _Period, 1), high[0] + _Point * 10);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
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
