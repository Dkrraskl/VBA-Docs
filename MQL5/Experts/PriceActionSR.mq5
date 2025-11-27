//+------------------------------------------------------------------+
//|                                                PriceActionSR.mq5 |
//|                      Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property description "EA Avanzado para detectar Zonas de Soporte y Resistencia validadas por múltiples toques."

//--- Parámetros de entrada del Asesor Experto
input group             "Análisis de Zonas"
input int               InpLookBackPeriod = 500;    // Número de velas hacia atrás para analizar
input int               InpSwingPeriod    = 5;      // Período para definir un Swing High/Low (velas a cada lado)
input int               InpMinTouches     = 3;      // Número mínimo de toques para validar una zona
input group             "Filtro de Volatilidad (ATR)"
input int               InpATRPeriod      = 14;     // Período para el cálculo del ATR
input double            InpATRMultiplier  = 1.0;    // Multiplicador para la tolerancia basada en ATR

//--- Definición de tipos y estructuras
enum ENUM_LEVEL_TYPE
  {
   SUPPORT,     // Nivel de Soporte
   RESISTANCE   // Nivel de Resistencia
  };

struct PriceLevel
  {
   double            price;      // Precio del nivel
   int               touches;    // Contador de toques
   ENUM_LEVEL_TYPE   level_type; // Tipo de nivel (Soporte/Resistencia)
  };

//--- Variables Globales
datetime   g_lastBarTime;              // Almacena el tiempo de la última barra para controlar la ejecución
PriceLevel g_validated_levels[];       // Array dinámico para almacenar las zonas validadas
int        g_atr_handle;               // Handle para el indicador ATR

//+------------------------------------------------------------------+
//| Función de inicialización del Asesor Experto                     |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Inicializar el contador de tiempo de la barra
   g_lastBarTime=0;

//--- Crear el handle para el indicador ATR
   g_atr_handle = iATR(_Symbol, _Period, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
     {
      Print("Error al crear el handle del indicador ATR. Código de error: ", GetLastError());
      return(INIT_FAILED);
     }

//--- Mensaje de inicialización exitosa
   Print("PriceActionSR EA v2.0 (ATR) inicializado correctamente.");

//--- Ejecutar un cálculo inicial al cargar el EA
   DrawSRLevels();
   UpdateDashboard();

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Función de desinicialización del Asesor Experto                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Limpiar objetos del gráfico al quitar el EA
   ObjectsDeleteAll(0, "SR_"); // Prefijo general para todos los objetos del EA

//--- Liberar el handle del indicador
   IndicatorRelease(g_atr_handle);

   ChartRedraw();
   Print("PriceActionSR EA desinicializado y objetos limpiados.");
  }
//+------------------------------------------------------------------+
//| Función de tick del Asesor Experto                               |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Usamos iTime para obtener el tiempo de apertura de la vela actual (índice 0)
   datetime currentBarTime = iTime(_Symbol, _Period, 0);

   if(currentBarTime > g_lastBarTime)
     {
      //--- Si es una nueva vela, actualizamos el tiempo y ejecutamos la lógica principal
      g_lastBarTime = currentBarTime;

      // 1. Calcular y dibujar los niveles validados
      DrawSRLevels();

      // 2. Comprobar si ha habido una ruptura de algún nivel
      CheckForBreakouts();

      // 3. Actualizar el panel de información
      UpdateDashboard();
     }
  }
//+------------------------------------------------------------------+
//| Función principal para calcular y dibujar los niveles de S/R     |
//+------------------------------------------------------------------+
void DrawSRLevels()
  {
//--- 1. Limpiar objetos de niveles y flechas antiguos antes de recalcular
   ObjectsDeleteAll(0, "SR_Level_");
   ObjectsDeleteAll(0, "SR_Arrow_");
   ArrayFree(g_validated_levels); // Limpiar el array global

//--- 2. Obtener los datos de precios históricos
   double high[], low[];
   if(CopyHigh(_Symbol, _Period, 0, InpLookBackPeriod, high) < InpLookBackPeriod ||
      CopyLow(_Symbol, _Period, 0, InpLookBackPeriod, low) < InpLookBackPeriod)
     {
      Print("Error al copiar los datos de precios históricos.");
      return;
     }
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

//--- 3. Identificar TODOS los posibles fractales (Swing Points)
   PriceLevel potential_levels[];
   int levels_count = 0;

   for(int i = InpSwingPeriod; i < InpLookBackPeriod - InpSwingPeriod; i++)
     {
      bool is_swing_high = true, is_swing_low = true;
      // Comprobar Swing High
      for(int j = 1; j <= InpSwingPeriod; j++)
        {
         if(high[i] < high[i - j] || high[i] < high[i + j])
           {
            is_swing_high = false;
            break;
           }
        }
      // Comprobar Swing Low
      for(int j = 1; j <= InpSwingPeriod; j++)
        {
         if(low[i] > low[i - j] || low[i] > low[i + j])
           {
            is_swing_low = false;
            break;
           }
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

//--- 4. Calcular la tolerancia dinámica basada en el ATR actual
   double atr_buffer[];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buffer) < 1)
     {
      Print("Error al copiar los datos del ATR.");
      return;
     }
   double current_atr = atr_buffer[0];
   double tolerance = current_atr * InpATRMultiplier;

   //--- DEBUG: Imprimir el valor del ATR actual
   PrintFormat("ATR Actual: %.5f | Tolerancia Calculada: %.5f", current_atr, tolerance);

//--- 5. Agrupar fractales cercanos en ZONAS únicas usando la tolerancia ATR
   PriceLevel grouped_levels[];
   int grouped_count = 0;

   for(int i = 0; i < levels_count; i++)
     {
      bool is_grouped = false;
      for(int j = 0; j < grouped_count; j++)
        {
         // Si un nivel potencial está cerca de una zona ya agrupada y es del mismo tipo...
         if(potential_levels[i].level_type == grouped_levels[j].level_type &&
            MathAbs(potential_levels[i].price - grouped_levels[j].price) <= tolerance)
           {
            // Opcional: promediar el precio de la zona. Por simplicidad, nos quedamos con la primera.
            is_grouped = true;
            break;
           }
        }
      // Si no ha sido agrupado, es una nueva zona potencial
      if(!is_grouped)
        {
         ArrayResize(grouped_levels, grouped_count + 1);
         grouped_levels[grouped_count] = potential_levels[i];
         grouped_count++;
        }
     }

//--- 5. Contar los "toques" para cada zona agrupada
   for(int i = 0; i < grouped_count; i++)
     {
      grouped_levels[i].touches = 0;
      // Recorrer todo el historial de velas para contar los toques
      for(int k = 0; k < InpLookBackPeriod; k++)
        {
         if(grouped_levels[i].level_type == RESISTANCE)
           {
            // Una resistencia es "tocada" si el máximo de la vela está dentro de la tolerancia
            if(MathAbs(high[k] - grouped_levels[i].price) <= tolerance)
              {
               grouped_levels[i].touches++;
              }
           }
         else // Es un soporte
           {
            // Un soporte es "tocado" si el mínimo de la vela está dentro de la tolerancia
            if(MathAbs(low[k] - grouped_levels[i].price) <= tolerance)
              {
               grouped_levels[i].touches++;
              }
           }
        }
     }

//--- 6. Filtrar las zonas que cumplen con el mínimo de toques y almacenarlas en la variable global
   int validated_count = 0;
   for(int i = 0; i < grouped_count; i++)
     {
      //--- DEBUG: Imprimir cada nivel candidato y sus toques
      string level_type_str = (grouped_levels[i].level_type == SUPPORT) ? "Soporte" : "Resistencia";
      PrintFormat("Nivel Candidato (%s) encontrado en: %.5f, Toques: %d", level_type_str, grouped_levels[i].price, grouped_levels[i].touches);

      if(grouped_levels[i].touches >= InpMinTouches)
        {
         ArrayResize(g_validated_levels, validated_count + 1);
         g_validated_levels[validated_count] = grouped_levels[i];
         validated_count++;
        }
     }

   // Dibujado movido a una función separada para claridad
   DrawValidatedLevels();
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Dibuja los objetos gráficos para los niveles validados           |
//+------------------------------------------------------------------+
void DrawValidatedLevels()
{
   for(int i=0; i < ArraySize(g_validated_levels); i++)
     {
      string name = "SR_Level_" + IntegerToString(i);
      int width = (g_validated_levels[i].touches >= 5) ? 3 : 1;
      color line_color = (g_validated_levels[i].level_type == RESISTANCE) ? clrBlue : clrRed;

      ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_validated_levels[i].price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, line_color);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, "Toques: " + IntegerToString(g_validated_levels[i].touches));
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
}
//+------------------------------------------------------------------+
//| Comprueba si la última vela cerrada ha roto algún nivel validado |
//+------------------------------------------------------------------+
void CheckForBreakouts()
  {
//--- No hacer nada si no hay niveles validados
   if(ArraySize(g_validated_levels) == 0)
      return;

//--- Obtener el precio de cierre de la vela anterior (índice 1)
   double close_prices[];
   if(CopyClose(_Symbol, _Period, 1, 1, close_prices) < 1)
     {
      Print("Error al copiar el precio de cierre.");
      return;
     }
   double last_close = close_prices[0];

//--- Recorrer todos los niveles validados para buscar rupturas
   for(int i = 0; i < ArraySize(g_validated_levels); i++)
     {
      PriceLevel level = g_validated_levels[i];

      //--- Lógica de Ruptura de Resistencia (Alcista)
      if(level.level_type == RESISTANCE && last_close > level.price)
        {
         // Crear nombre único para la flecha basado en el tiempo de la vela
         string name = "SR_Arrow_Buy_" + TimeToString(iTime(_Symbol, _Period, 1), TIME_MINUTES);

         // Dibujar la flecha debajo del mínimo de la vela que rompió
         double low_prices[];
         CopyLow(_Symbol, _Period, 1, 1, low_prices);
         ObjectCreate(0, name, OBJ_ARROW_BUY, 0, iTime(_Symbol, _Period, 1), low_prices[0] - _Point * 10);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlue);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);

         // Enviar alerta
         string alert_msg = StringFormat("%s Resistencia rota en %.5f", _Symbol, level.price);
         Alert(alert_msg);
         Print(alert_msg);
        }

      //--- Lógica de Ruptura de Soporte (Bajista)
      if(level.level_type == SUPPORT && last_close < level.price)
        {
         string name = "SR_Arrow_Sell_" + TimeToString(iTime(_Symbol, _Period, 1), TIME_MINUTES);

         // Dibujar la flecha encima del máximo de la vela que rompió
         double high_prices[];
         CopyHigh(_Symbol, _Period, 1, 1, high_prices);
         ObjectCreate(0, name, OBJ_ARROW_SELL, 0, iTime(_Symbol, _Period, 1), high_prices[0] + _Point * 10);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);

         // Enviar alerta
         string alert_msg = StringFormat("%s Soporte roto en %.5f", _Symbol, level.price);
         Alert(alert_msg);
         Print(alert_msg);
        }
     }
  }
//+------------------------------------------------------------------+
//| Dibuja y actualiza el panel de información en el gráfico         |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
//--- Contar soportes y resistencias activas
   int support_count = 0;
   int resistance_count = 0;
   for(int i = 0; i < ArraySize(g_validated_levels); i++)
     {
      if(g_validated_levels[i].level_type == SUPPORT)
         support_count++;
      else
         resistance_count++;
     }

//--- Obtener el valor del ATR actual para mostrarlo
   double atr_buffer[];
   string current_atr_str = "Calculating...";
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atr_buffer) > 0)
     {
      current_atr_str = StringFormat("%.5f", atr_buffer[0]);
     }

//--- Crear el texto del panel
   string nl = "\n"; // Nueva línea
   string text = "--- Price Action SR v3.0 (ATR) ---" + nl +
                 "Resistencias Activas: " + IntegerToString(resistance_count) + nl +
                 "Soportes Activos: " + IntegerToString(support_count) + nl +
                 "----------------------------------" + nl +
                 "ATR Actual: " + current_atr_str + nl +
                 "ATR Multiplier: " + DoubleToString(InpATRMultiplier, 2);

//--- Crear o actualizar el objeto de texto en el gráfico
   string name = "SR_Dashboard";
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 15);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }
//+------------------------------------------------------------------+
