# GROMACS Automated Simulation Runner

## Descripción General

Este script de Bash automatiza la ejecución de simulaciones de dinámica molecular usando GROMACS. Organiza y ejecuta múltiples simulaciones en un orden específico basado en un sistema de numeración de archivos de parámetros (.mdp).

## Características Principales

- **Detección automática** de archivos de topología y coordenadas
- **Sistema de numeración** para control de orden de ejecución
- **Verificación de integridad** de simulaciones previas
- **Logging completo** con banners informativos
- **Continuación automática** de simulaciones interrumpidas
- **Manejo de errores** robusto

## Estructura de Archivos Requerida

```
project/
├── Base/
│   ├── sistema.top          # Archivo de topología
│   └── sistema.gro          # Archivo de coordenadas inicial
├── MDPs/                    # Archivos de parámetros de simulación
│   ├── 01-150-Base-MIN.mdp
│   ├── 02-150-MIN-ANE.mdp
│   ├── 03-150-ANE-NPT.mdp
│   ├── 04-150-NPT-NVT.mdp
│   ├── 05-160-150_NVT-NVT.mdp
│   └── ...
└── run.sh                   # Script principal
```

## Sistema de Nomenclatura de Archivos MDP

Los archivos .mdp siguen el formato: `numero-carpeta-referencia-simulacion.mdp`

- **numero**: Orden de ejecución (ej: 01, 02, 03...)
- **carpeta**: Directorio donde se ejecutará la simulación (ej: 150, 160)
- **referencia**: Coordenadas de entrada (Base, MIN, ANE, NPT, NVT)
- **simulacion**: Tipo de simulación (MIN, ANE, NPT, NVT)

### Ejemplos:
- `01-150-Base-MIN.mdp` → Primera simulación, carpeta 150, coordenadas de Base, tipo MIN
- `05-160-150_NVT-NVT.mdp` → Quinta simulación, carpeta 160, coordenadas de 150/NVT, tipo NVT

## Estructura de Carpetas Generada

Al ejecutar el script, se crea la siguiente estructura:

```
project/
├── 150/
│   ├── MIN/
│   │   ├── MIN.tpr
│   │   ├── MIN.gro
│   │   ├── MIN.edr
│   │   ├── potential.xvg
│   │   └── ...
│   ├── ANE/
│   │   ├── ANE.tpr
│   │   ├── ANE.gro
│   │   ├── ANE.edr
│   │   ├── temp-press.xvg
│   │   └── ...
│   ├── NPT/
│   │   ├── NPT.tpr
│   │   ├── NPT.gro
│   │   ├── NPT.edr
│   │   ├── temp-press.xvg
│   │   ├── Volumen.xvg
│   │   └── ...
│   └── NVT/
│       ├── NVT.tpr
│       ├── NVT.gro
│       ├── NVT.edr
│       ├── temp-press.xvg
│       └── ...
├── 160/
│   └── NVT/
│       ├── NVT.tpr
│       ├── NVT.gro
│       ├── NVT.edr
│       ├── temp-press.xvg
│       └── ...
└── ...
```

## Funciones Principales

### 1. Detección de Archivos Base

```bash
# Verifica la existencia de la carpeta Base y archivos necesarios
base_dir="Base"
top_file=$(find "$base_dir" -maxdepth 1 -name "*.top" -type f | head -n1)
init_gro_file=$(find "$base_dir" -maxdepth 1 -name "*.gro" -type f | head -n1)
```

### 2. Funciones de Logging y Visualización

**`show_simulation_start_banner()`**
- Inicializa el sistema de logging
- Muestra banner de inicio con información del sistema
- Crea archivo de log con timestamp

**`show_individual_simulation_start()`**
- Muestra banner para cada simulación individual
- Incluye tipo de simulación, carpeta y timestamp

**`log_message()`**
- Sistema de logging unificado
- Soporta diferentes niveles: INFO, SUCCESS, ERROR, WARNING, PROGRESS
- Escribe tanto en consola como en archivo de log

### 3. Procesamiento de Archivos MDP

**`parse_mdp_filename()`**
```bash
# Parsea: 01-150-Base-MIN.mdp → 01|150|Base|MIN
parse_mdp_filename "01-150-Base-MIN.mdp"
```

**`find_and_sort_mdps()`**
- Encuentra todos los archivos .mdp en la carpeta MDPs
- Los ordena numéricamente según el primer campo

### 4. Gestión de Rutas y Referencias

**`get_coordinate_file_path()`**
- Determina la ruta correcta para archivos de coordenadas de entrada
- Maneja referencias a otras carpetas (ej: 150/NVT desde 160)

**`get_mdp_file_path()`**
- Resuelve rutas absolutas para archivos .mdp

### 5. Verificación de Estado de Simulaciones

**`is_simulation_complete()`**
```bash
# Verifica si una simulación está completa verificando:
# - Existencia de .tpr (simulación iniciada)
# - Existencia de .gro (simulación completada)
# - Archivos .xvg de energía según tipo de simulación
```

**`check_and_continue_simulation()`**
- Detecta simulaciones incompletas
- Continúa desde checkpoint si existe
- Reinicia si es necesario

### 6. Ejecución de Comandos GROMACS

**`run_grompp()`**
- Ejecuta `gmx grompp` con parámetros estandarizados
- Maneja errores y logging

**`run_mdrun()`**
- Ejecuta `gmx mdrun` con opciones de paralelización
- Muestra output en tiempo real

**`run_energy()`**
- Extrae datos de energía de archivos .edr
- Selecciones automáticas según tipo de simulación

### 7. Función Principal de Simulación

**`run_simulation_from_mdp()`**
- Función principal que orquesta cada simulación
- Crea directorios necesarios
- Ejecuta en orden: grompp → mdrun → energy
- Maneja cambios de directorio y retornos

## Flujo de Ejecución

1. **Inicialización**
   - Verifica archivos base (.top, .gro)
   - Inicia sistema de logging
   - Busca y ordena archivos .mdp

2. **Procesamiento por Orden Numérico**
   - Para cada archivo .mdp en orden:
     - Verifica si la simulación ya está completa
     - Si está incompleta, la continúa o reinicia
     - Si no existe, ejecuta nueva simulación

3. **Ejecución de Simulación Individual**
   - Crea directorio de simulación
   - Determina coordenadas de entrada
   - Ejecuta grompp → mdrun → energy
   - Registra resultados y tiempos

4. **Finalización**
   - Genera resumen de ejecución
   - Muestra estadísticas finales

## Ejemplo de Simulación Completa

### Archivos MDP de Ejemplo:

1. `01-150-Base-MIN.mdp` - Minimización desde coordenadas base
2. `02-150-MIN-ANE.mdp` - Annealing desde minimización
3. `03-150-ANE-NPT.mdp` - Equilibrio NPT desde annealing
4. `04-150-NPT-NVT.mdp` - Producción NVT desde NPT
5. `05-160-150_NVT-NVT.mdp` - Producción en 160 desde 150/NVT

### Ejecución:
```bash
./run.sh
```

### Salida Esperada:
```
╔════════════════════════════════════════════╗
          INICIO DE SIMULACIÓN              
╠════════════════════════════════════════════╣
  Fecha: 2024-01-15 10:30:00               
  Sistema: GROMACS MD Simulation            
  Archivos base detectados en carpeta 'Base'
  TOP: sistema.top
  GRO: sistema.gro
╚════════════════════════════════════════════╝

[2024-01-15 10:30:01] [PROGRESO] Procesando [01]: 150 - MIN (Referencia: Base)

╔════════════════════════════════════════════╗
          INICIO - MINIMIZACIÓN            
╠════════════════════════════════════════════╣
  Fecha: 2024-01-15 10:30:01               
  Carpeta: 150                          
  Simulación: MIN                            
╚════════════════════════════════════════════╝
```

## Manejo de Errores y Reinicios

El script detecta automáticamente simulaciones interrumpidas:

- **Si existe .tpr pero no .gro**: Reinicia la simulación
- **Si existe .cpt**: Continúa desde el checkpoint
- **Verifica archivos .xvg**: Confirma extracción de energías

## Archivos de Log

Se genera un archivo de log con timestamp: `simulation_log_YYYYMMDD_HHMMSS.log` que contiene:

- Comandos ejecutados
- Output de GROMACS
- Tiempos de ejecución
- Errores y advertencias

## Dependencias

- **GROMACS** instalado y en PATH
- **Bash** 4.0 o superior
- Permisos de ejecución en el script

## Uso

```bash
# Dar permisos de ejecución
chmod +x run.sh

# Ejecutar todas las simulaciones
./run.sh

# Ver progreso en tiempo real
tail -f simulation_log_20240115_103000.log
```

Este sistema permite organizar y ejecutar complejos protocolos de simulación de manera reproducible y automatizada, con verificación robusta del estado de cada paso.