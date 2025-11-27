//+------------------------------------------------------------------+
//|                                                PriceActionSR.mq5 |
//|                      Copyright 2023, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property strict
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Asesor Experto para detectar Soportes y Resistencias basado en Price Action (Swing High/Low)"

//--- Parámetros de entrada del Asesor Experto
input int InpSwingPeriod    = 5;      // Período para definir un Swing High/Low (velas a cada lado)
input int InpLookBackPeriod = 500;    // Número de velas hacia atrás para analizar
input int InpTolerancePips  = 20;     // Tolerancia en Pips para fusionar niveles cercanos

//--- Variables Globales
datetime g_lastBarTime; // Almacena el tiempo de la última barra para controlar la ejecución

//+------------------------------------------------------------------+
//| Función de inicialización del Asesor Experto                     |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- Inicializar el contador de tiempo de la barra
   g_lastBarTime=0;

//--- Mensaje de inicialización exitosa
   Print("PriceActionSR EA inicializado correctamente.");

//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Función de desinicialización del Asesor Experto                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//--- Limpiar objetos del gráfico al quitar el EA
   ObjectsDeleteAll(0, "SR_Level_");
   Print("PriceActionSR EA desinicializado y objetos limpiados.");
//---
  }
//+------------------------------------------------------------------+
//| Función de tick del Asesor Experto                               |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- Lógica para ejecutar el cálculo solo en una nueva vela
   // Usamos iTime para obtener el tiempo de apertura de la vela actual (índice 0)
   // Es el método más fiable y eficiente para detectar una nueva vela.
   datetime currentBarTime = iTime(_Symbol, _Period, 0);

   if(currentBarTime > g_lastBarTime)
     {
      //--- Si es una nueva vela, actualizamos el tiempo y ejecutamos la lógica principal
      g_lastBarTime = currentBarTime;
      DrawSRLevels();
     }
  }
//+------------------------------------------------------------------+
//| Función principal para calcular y dibujar los niveles de S/R     |
//+------------------------------------------------------------------+
void DrawSRLevels()
  {
//--- 1. Limpiar objetos antiguos antes de dibujar los nuevos
   ObjectsDeleteAll(0, "SR_Level_");

//--- 2. Obtener los datos de precios (High y Low)
   double high[], low[];
   if(CopyHigh(_Symbol, _Period, 0, InpLookBackPeriod, high) < InpLookBackPeriod ||
      CopyLow(_Symbol, _Period, 0, InpLookBackPeriod, low) < InpLookBackPeriod)
     {
      Print("Error al copiar los datos de precios históricos.");
      return;
     }

//--- Invertir el orden de los arrays para que el índice 0 sea la vela más reciente
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

//--- 3. Identificar niveles de Soporte y Resistencia (Swing Points)
   double resistanceLevels[];
   double supportLevels[];
   int resCount = 0;
   int supCount = 0;

   // El bucle empieza en InpSwingPeriod para tener suficientes velas a la izquierda,
   // y termina en InpLookBackPeriod - InpSwingPeriod para tener suficientes a la derecha.
   for(int i = InpSwingPeriod; i < InpLookBackPeriod - InpSwingPeriod; i++)
     {
      bool isSwingHigh = true;
      bool isSwingLow = true;

      // Comprobar si es un Swing High
      for(int j = 1; j <= InpSwingPeriod; j++)
        {
         if(high[i] < high[i-j] || high[i] < high[i+j])
           {
            isSwingHigh = false;
            break;
           }
        }

      // Comprobar si es un Swing Low
      for(int j = 1; j <= InpSwingPeriod; j++)
        {
         if(low[i] > low[i-j] || low[i] > low[i+j])
           {
            isSwingLow = false;
            break;
           }
        }

      // Si es un Swing High, añadirlo a la lista de resistencias
      if(isSwingHigh)
        {
         ArrayResize(resistanceLevels, resCount + 1);
         resistanceLevels[resCount] = high[i];
         resCount++;
        }

      // Si es un Swing Low, añadirlo a la lista de soportes
      if(isSwingLow)
        {
         ArrayResize(supportLevels, supCount + 1);
         supportLevels[supCount] = low[i];
         supCount++;
        }
     }

//--- 4. Filtrar y agrupar niveles cercanos
   double tolerance = InpTolerancePips * _Point;

   // Filtrar Resistencias
   double filteredResistances[];
   int filteredResCount = 0;

   for(int i=0; i < ArraySize(resistanceLevels); i++)
     {
      bool isNear = false;
      for(int j=0; j < filteredResCount; j++)
        {
         if(MathAbs(resistanceLevels[i] - filteredResistances[j]) < tolerance)
           {
            isNear = true;
            // Opcional: promediar o actualizar con el más reciente
            // Aquí simplemente nos quedamos con el primero que encontramos en una zona
            break;
           }
        }

      if(!isNear)
        {
         ArrayResize(filteredResistances, filteredResCount + 1);
         filteredResistances[filteredResCount] = resistanceLevels[i];
         filteredResCount++;
        }
     }

   // Filtrar Soportes
   double filteredSupports[];
   int filteredSupCount = 0;

   for(int i=0; i < ArraySize(supportLevels); i++)
     {
      bool isNear = false;
      for(int j=0; j < filteredSupCount; j++)
        {
         if(MathAbs(supportLevels[i] - filteredSupports[j]) < tolerance)
           {
            isNear = true;
            break;
           }
        }

      if(!isNear)
        {
         ArrayResize(filteredSupports, filteredSupCount + 1);
         filteredSupports[filteredSupCount] = supportLevels[i];
         filteredSupCount++;
        }
     }

//--- 5. Dibujar los niveles filtrados en el gráfico
   for(int i = 0; i < filteredResCount; i++)
     {
      string name = "SR_Level_Res_" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, filteredResistances[i]);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }

   for(int i = 0; i < filteredSupCount; i++)
     {
      string name = "SR_Level_Sup_" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, filteredSupports[i]);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrBlue);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }

   Print(filteredResCount, " resistencias y ", filteredSupCount, " soportes dibujados.");
   ChartRedraw(); // Actualizar el gráfico
  }
//+------------------------------------------------------------------+
//| Función para verificar si un nivel ha sido roto (breakout)       |
//+------------------------------------------------------------------+
bool IsLevelBroken(double level, double closePrice, bool isSupport)
  {
//--- Lógica de Breakout: Comprueba si el precio de cierre cruzó el nivel.
//--- Para un soporte, el precio debe cerrar por debajo.
//--- Para una resistencia, el precio debe cerrar por encima.

   if(isSupport)
     {
      // Si es un nivel de soporte, retorna true si el cierre está por debajo.
      if(closePrice < level)
        {
         return(true);
        }
     }
   else // Es una resistencia
     {
      // Si es un nivel de resistencia, retorna true si el cierre está por encima.
      if(closePrice > level)
        {
         return(true);
        }
     }

   // Si no se cumplen las condiciones de ruptura, retorna false.
   return(false);
  }
//+------------------------------------------------------------------+
