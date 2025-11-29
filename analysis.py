import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import os

# --- Configuración de Estilo ---
sns.set_theme(style="whitegrid", palette="viridis")
plt.style.use("dark_background")

def analyze_trade_log(file_path):
    """
    Analiza el archivo de log de trading y genera visualizaciones.
    """
    if not os.path.exists(file_path):
        print(f"Error: El archivo '{file_path}' no fue encontrado.")
        print("Asegúrate de que el Expert Advisor ha ejecutado al menos un tick y ha generado el archivo de log.")
        return

    # --- Carga y Preparación de Datos ---
    try:
        df = pd.read_csv(file_path)
        if df.empty:
            print("El archivo de log está vacío. No hay datos para analizar.")
            return

        # Convertir Timestamp a formato de fecha y hora
        df['Timestamp'] = pd.to_datetime(df['Timestamp'])
        # Extraer la hora del día
        df['Hour'] = df['Timestamp'].dt.hour

        # Asegurarse que las columnas numéricas son tratadas como tal
        df['Spread'] = pd.to_numeric(df['Spread'], errors='coerce')
        df['ATR'] = pd.to_numeric(df['ATR'], errors='coerce')

        # Eliminar filas donde la conversión a número falló
        df.dropna(subset=['Spread', 'ATR'], inplace=True)

    except Exception as e:
        print(f"Error al leer o procesar el archivo CSV: {e}")
        return

    print("--- Análisis del Log de Trading Institucional ---")
    print(df.head())
    print("\nEstadísticas Descriptivas:")
    print(df.describe())

    # --- Creación de Gráficas ---
    fig, axes = plt.subplots(3, 1, figsize=(14, 22))
    fig.suptitle('Análisis de Performance del EA Institucional Híbrido', fontsize=20, color='white')

    # 1. Gráfica de Cajas: Spread vs. Resultado de la Operación
    ax1 = axes[0]
    sns.boxplot(x='Result', y='Spread', data=df, ax=ax1, palette="plasma")
    ax1.set_title('Distribución del Spread por Resultado de la Acción', fontsize=16, color='white')
    ax1.set_xlabel('Resultado de la Acción', fontsize=12, color='white')
    ax1.set_ylabel('Spread (en Puntos de Cotización)', fontsize=12, color='white')
    ax1.tick_params(axis='x', colors='white')
    ax1.tick_params(axis='y', colors='white')

    # 2. Histograma: Distribución del Spread
    ax2 = axes[1]
    sns.histplot(df['Spread'], bins=30, kde=True, ax=ax2, color="skyblue")
    ax2.set_title('Distribución General del Spread Durante Intentos de Trading', fontsize=16, color='white')
    ax2.set_xlabel('Spread (en Puntos de Cotización)', fontsize=12, color='white')
    ax2.set_ylabel('Frecuencia', fontsize=12, color='white')
    ax2.axvline(df['Spread'].mean(), color='red', linestyle='--', label=f"Media: {df['Spread'].mean():.4f}")
    ax2.legend()

    # 3. Gráfica de Barras: Actividad de Trading por Hora del Día
    ax3 = axes[2]
    hourly_activity = df['Hour'].value_counts().sort_index()
    sns.barplot(x=hourly_activity.index, y=hourly_activity.values, ax=ax3, palette="magma")
    ax3.set_title('Número de Acciones de Trading por Hora del Servidor', fontsize=16, color='white')
    ax3.set_xlabel('Hora del Día', fontsize=12, color='white')
    ax3.set_ylabel('Número de Acciones Registradas', fontsize=12, color='white')
    ax3.set_xticks(range(24))

    # --- Finalización ---
    plt.tight_layout(rect=[0, 0, 1, 0.96])

    # Guardar la figura
    output_filename = "analisis_de_trading.png"
    plt.savefig(output_filename)
    print(f"\nAnálisis completado. Gráficas guardadas en '{output_filename}'")

    # Opcional: Mostrar la gráfica
    # plt.show()


if __name__ == "__main__":
    # El nombre del archivo debe coincidir exactamente con el generado por el EA en MQL5
    log_file = "TradeLog_Institutional_Hybrid.csv"
    analyze_trade_log(log_file)
