import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os

# --- CONFIGURACIÓN ---
LOG_PREFIX = "TradeLog_Institutional_Hybrid"

def find_latest_log_file():
    """Encuentra el archivo de log más reciente en la carpeta MQL5/Files."""
    try:
        appdata_path = os.getenv('APPDATA')
        terminal_path = os.path.join(appdata_path, 'MetaQuotes', 'Terminal')
        terminal_id_folder = [d for d in os.listdir(terminal_path) if os.path.isdir(os.path.join(terminal_path, d))][0]
        files_path = os.path.join(terminal_path, terminal_id_folder, 'MQL5', 'Files')

        log_files = [f for f in os.listdir(files_path) if f.startswith(LOG_PREFIX) and f.endswith(".csv")]

        if not log_files:
            return None

        # Devuelve la ruta completa al archivo más reciente
        latest_file = max(log_files, key=lambda f: os.path.getmtime(os.path.join(files_path, f)))
        return os.path.join(files_path, latest_file)

    except Exception as e:
        print(f"No se pudo encontrar la ruta de MQL5 automáticamente: {e}")
        return None

def analizar_log_de_trades():
    """
    Lee el archivo CSV generado por el bot, calcula métricas clave
    y genera visualizaciones críticas para el análisis de rendimiento en cualquier activo.
    """
    ruta_archivo = find_latest_log_file()

    if not ruta_archivo or not os.path.exists(ruta_archivo):
        print(f"❌ Error: No se encontró ningún archivo de log que comience con '{LOG_PREFIX}' en la carpeta MQL5/Files.")
        print("Asegúrate de haber ejecutado el bot en MT5 al menos una vez para generar el log.")
        return

    print(f"Analizando el archivo de log más reciente: {os.path.basename(ruta_archivo)}")
    try:
        # --- Carga y Preparación de Datos ---
        df = pd.read_csv(ruta_archivo)
        df['Timestamp'] = pd.to_datetime(df['Timestamp'])

        # Eliminar filas donde ATR es 0 (ej. en cancelaciones) para análisis de volatilidad
        df_volatility = df[df['ATR'] > 0].copy()

        if not df_volatility.empty:
            # Ahora el cálculo es directo, ya que Spread y ATR están en las mismas unidades
            df_volatility['Spread_Relativo_ATR_Pct'] = (df_volatility['Spread_QuoteCurrency'] / df_volatility['ATR']) * 100

        print("\n📊 REPORTE DE ANÁLISIS DEL BOT UNIVERSAL (FOREX, CRIPTO, ETC.)")
        print("----------------------------------------------------------------")
        print(f"Total de eventos registrados: {len(df)}")

        quote_currency = "Divisa" # Valor por defecto
        if not df.empty:
            # Lee la moneda de cotización directamente del CSV
            quote_currency = df['Quote_Currency'].iloc[0] if 'Quote_Currency' in df.columns else "Divisa"
            print(f"Spread Promedio ({quote_currency}): {df['Spread_QuoteCurrency'].mean():.4f}")
        if not df_volatility.empty:
            print(f"Spread Relativo Promedio (vs ATR): {df_volatility['Spread_Relativo_ATR_Pct'].mean():.2f}%")

        # --- Visualización de Datos ---
        sns.set_style("whitegrid")
        plt.figure(figsize=(18, 7))

        # 1. Gráfica Crítica: Spread vs. Resultado (Boxplot)
        plt.subplot(1, 3, 1)
        sns.boxplot(x='Result', y='Spread_QuoteCurrency', data=df, palette="pastel")
        plt.title(f"Spread por Resultado ({quote_currency})")
        plt.xlabel("Resultado")
        plt.ylabel(f"Spread (en {quote_currency})")
        plt.xticks(rotation=45)
        plt.yscale('log') # Usar escala logarítmica para manejar rangos amplios (ej. BTC)

        # 2. Distribución del Spread Relativo al ATR
        if not df_volatility.empty:
            plt.subplot(1, 3, 2)
            sns.histplot(df_volatility['Spread_Relativo_ATR_Pct'], bins=20, kde=True, color='darkcyan')
            plt.title("Distribución del Costo de Spread (Relativo al ATR)")
            plt.xlabel("% del ATR consumido por el Spread")
            plt.ylabel("Frecuencia de Operaciones")
            plt.axvline(x=10.0, color='r', linestyle='--', label='Límite Filtro (10%)')
            plt.legend()

        # 3. Actividad por Hora del Servidor
        df['Hour'] = df['Timestamp'].dt.hour
        plt.subplot(1, 3, 3)
        sns.countplot(x='Hour', data=df, palette="viridis")
        plt.title("Actividad del Bot por Hora (Validación de Killzones)")
        plt.xlabel("Hora del Servidor")
        plt.ylabel("Número de Eventos")

        plt.tight_layout()
        plt.suptitle("Análisis Visual de Métricas de Ejecución del Bot", fontsize=16, y=1.02)
        plt.show()

        print("\n✅ Análisis gráfico generado exitosamente.")

    except Exception as e:
        print(f"❌ Ocurrió un error inesperado durante el análisis: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    analizar_log_de_trades()
