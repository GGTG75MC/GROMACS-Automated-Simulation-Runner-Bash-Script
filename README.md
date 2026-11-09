# GROMACS Automated Simulation Runner

<p align="center">
  <img src="assets/GROMACS_Automated_Simulation_Banner.png" width="100%" alt="GROMACS_Automated_Simulation_Banner.png">
</p>

## Descripción General

Script de Bash que automatiza la ejecución de una cola de simulaciones de dinámica molecular con GROMACS. El orden, la carpeta de trabajo y las coordenadas de entrada de cada simulación se definen únicamente con el **nombre de los archivos `.mdp`**. Mientras corre, muestra una **barra de progreso en tiempo real** del paso actual de `mdrun`, indica **en qué posición de la cola** va el proceso y, al terminar cada simulación, reporta el **estado global de la cola**.

## Características Principales

- **Barra de progreso en vivo** del paso de `mdrun` (`paso actual / nsteps`), con porcentaje y posición en la cola (`Sim 2/6`)
- **Estado de la cola** al iniciar y al terminar cada simulación (`Cola: 2/6 procesadas (33%)`), con contador de éxitos y errores
- **Detección automática** de archivos de topología y coordenadas en `Base/`
- **Detección y selección de GROMACS**: busca todos los ejecutables `gmx*` del `PATH` (`gmx`, `gmx_mpi`, `gmx-2025`, ...) y, si hay más de uno, **pregunta cuál usar** mostrando versión, tipo de MPI, GPU y precisión
- **Flags de `mdrun` desde la línea de comandos**: `./run.sh -ntmpi 1 -ntomp 8 -nb gpu -pme gpu -pin on -v` pasa esos parámetros a `mdrun` en todas las simulaciones de la cola
- **Validación temprana de flags**: los flags se comprueban contra tu versión de GROMACS antes de lanzar nada, y se rechazan los que romperían la cola (`-maxh`, `-nsteps`, `-noappend`...)
- **Orden de ejecución por numeración** de los archivos `.mdp`
- **Reanudación segura** de simulaciones interrumpidas (checkpoint `.cpt`): si la reanudación falla, **no** se relanza desde cero ni se sobrescribe el `.tpr`
- **Extracción de energías por nombre de término** (no por índice fijo), compatible con cualquier campo de fuerza o ensamble
- **Salvaguarda de energías**: si `mdrun` ya terminó pero faltan los `.xvg`, solo se re-extraen las energías
- **Contador de advertencias real**: el resumen final cuenta cada `WARNING` registrado
- **Logging completo** con banners y archivo de log con timestamp
- **Barra adaptable** al ancho de la consola, incluso si se redimensiona durante la ejecución
- **Modo no interactivo**: si la salida se redirige (cron, `nohup`, `> archivo`), las barras se desactivan; el estado de la cola igual queda en consola y log

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

Formato: `numero-carpeta-referencia-simulacion.mdp`

| Campo | Significado | Ejemplo |
|---|---|---|
| `numero` | Orden de ejecución | `01`, `02`, `03`... |
| `carpeta` | Directorio donde se ejecuta la simulación | `150`, `160` |
| `referencia` | Origen de las coordenadas de entrada (`Base` o una simulación previa) | `Base`, `MIN`, `150_NVT` |
| `simulacion` | Nombre/tipo de la simulación | `MIN`, `ANE`, `NPT`, `NVT` |

### Ejemplos

- `01-150-Base-MIN.mdp` → Primera simulación, carpeta `150`, parte de las coordenadas de `Base`, tipo `MIN`
- `05-160-150_NVT-NVT.mdp` → Quinta simulación, carpeta `160`, parte de `150/NVT/NVT.gro`, tipo `NVT`

### Reglas del parseo

- El nombre se divide por `-`: primer campo = número, segundo = carpeta, último = nombre de simulación, y lo que queda en medio = referencia.
- En la referencia, el guion bajo `_` se convierte en `/` (por eso `150_NVT` apunta a `150/NVT`).
- El nombre de la simulación (último campo) determina qué energías se extraen. Admite sufijos, por ejemplo `NPT.Berendsen` o `NPT.Parrinello`, y se trata igual que `NPT`.
- Como `-` es el separador, **no debe usarse dentro de ningún campo**.

## Estructura de Carpetas Generada

```
project/
├── 150/
│   ├── MIN/
│   │   ├── MIN.tpr, MIN.gro, MIN.edr
│   │   ├── potential.xvg
│   │   └── ...
│   ├── ANE/
│   │   ├── ANE.tpr, ANE.gro, ANE.edr
│   │   ├── temp-press.xvg
│   │   └── ...
│   ├── NPT/
│   │   ├── NPT.tpr, NPT.gro, NPT.edr
│   │   ├── temp-press.xvg
│   │   ├── Volumen.xvg
│   │   └── ...
│   └── NVT/
│       └── ...
├── 160/
│   └── NVT/
│       └── ...
└── simulation_log_YYYYMMDD_HHMMSS.log
```

## Progreso y Estado de la Cola

Hay tres elementos, todos con la misma convención: **el porcentaje de la cola cuenta simulaciones ya terminadas** (con éxito o con error), nunca la que está en curso.

### 1. Línea de inicio (solo en terminal)

Se imprime bajo el banner de inicio de cada simulación:

```
Sim 2/6 en curso · 1/6 procesadas (16%)
```

### 2. Barra de pasos de `mdrun` (solo en terminal)

Se repinta cada segundo en una sola línea e incluye la posición en la cola:

```
██████████████░░░░░░░░░░░░░░░░  46%  Paso 4600/10000 · Sim 2/6
```

Al terminar:

```
██████████████████████████████ 100%  ✓ Paso 10000/10000 · Sim 2/6
```

En minimizaciones (`steep`, `cg`, `l-bfgs`), que pueden converger antes de llegar a `nsteps`:

```
██████████████████████████████ 100%  ✓ Terminó en paso 312 (máx. 5000) · Sim 1/6
```

Si el `.mdp` no define `nsteps`, se muestra solo el contador de pasos, sin barra.

### 3. Estado de la cola al terminar cada simulación (consola y log)

Se registra después de **cada** simulación, ya sea ejecutada, saltada por estar completa, reanudada o fallida:

```
[2026-01-15 11:02:40] [PROGRESO] Cola: 2/6 procesadas (33%) · ✓ 2  ✗ 0
...
[2026-01-15 14:30:05] [PROGRESO] Cola: 6/6 procesadas (100%) · ✓ 6  ✗ 0 · cola finalizada
```

Como `✓` cuenta las exitosas y `✗` las fallidas, un `6/6` con errores no se confunde con un éxito total.

### Cómo se calcula el paso actual

1. `nsteps` e `integrator` se leen del `.mdp` (se ignoran comentarios, mayúsculas y la diferencia entre `-` y `_` en las claves).
2. `gmx mdrun -v` se lanza **en segundo plano** y su salida va al archivo de log.
3. Cada segundo se determina el paso actual combinando dos fuentes y tomando la mayor:
   - la salida `-v` de `mdrun` en el log del script (formatos `step N, will finish...`, líneas con prefijo de descomposición de dominios, y `Step= N, Dmax=` en minimización);
   - la tabla `Step Time` del `.log` propio de GROMACS (se actualiza cada `nstlog` pasos).
4. La barra se redibuja ocupando el ancho disponible. Si se redimensiona la ventana (`SIGWINCH`), se borra y redibuja de inmediato.

## Selección de GROMACS

Al iniciar, el script recorre el `PATH` buscando ejecutables `gmx*` y comprueba que **realmente son GROMACS** ejecutando `--version` (así se descartan archivos ajenos con nombre parecido). Los enlaces al mismo binario (por ejemplo `/bin` → `/usr/bin`) se cuentan una sola vez.

| Situación | Comportamiento |
|---|---|
| Se indica `--gmx <nombre\|ruta>` o la variable `GMX_BIN` | Se usa ese ejecutable (tiene prioridad sobre la búsqueda automática) |
| Se encuentra **uno** | Se usa directamente |
| Se encuentran **varios** y hay terminal | Se muestra un menú para elegir |
| Se encuentran **varios** y no hay terminal (`nohup`, `cron`) | Error: no se puede preguntar; hay que indicar `--gmx` |
| No se encuentra ninguno | Error con instrucciones (cargar `GMXRC` o usar `--gmx`) |

```
¿Qué GROMACS quieres usar? (se detectaron 2)

  (1) gmx_mpi
      2025.1 · MPI: MPI · GPU: CUDA · mixed
      /usr/local/gromacs-2025/bin/gmx_mpi
  (2) gmx
      2024.3 · MPI: thread_mpi · GPU: CUDA · mixed
      /usr/local/gromacs-2024/bin/gmx

Selecciona [1-2]:
```

El ejecutable elegido se usa en **todos** los comandos del script (`grompp`, `mdrun` y `energy`) y queda registrado en el log junto con su versión.

> Si tienes dos instalaciones con el mismo nombre (`gmx` en dos directorios), el menú las lista por separado con su ruta. Para elegir una sin menú, pasa la ruta completa: `--gmx /opt/gromacs-2025/bin/gmx`.

### Builds MPI

- Un build con **thread-MPI** (el `gmx` habitual) usa `-ntmpi` / `-nt` para repartir los ranks.
- Un build con **MPI real** (`gmx_mpi`) no admite `-ntmpi` ni `-nt`; los ranks se fijan al lanzar con `mpirun`. Para eso existe `--launcher`:

```bash
./run.sh --gmx gmx_mpi --launcher "mpirun -np 4" -ntomp 2
```

Si seleccionas un build MPI real sin `--launcher`, `mdrun` corre con 1 rank (el script lo avisa). Si pasas `-ntmpi` o `-nt` con un build MPI real, también avisa.

## Flags de `mdrun`

Todo lo que se escriba al lanzar el script y **no** sea una opción del propio script se pasa tal cual a `gmx mdrun`, en **todas** las simulaciones de la cola (incluida la reanudación desde checkpoint):

```bash
./run.sh -ntmpi 1 -ntomp 8 -nb gpu -pme gpu -pin on -v -stepout 250000
```

equivale, en cada simulación, a:

```bash
gmx mdrun -s <SIM>.tpr -deffnm <SIM> -ntmpi 1 -ntomp 8 -nb gpu -pme gpu -pin on -v -stepout 250000 > log
```

donde `-s`, `-deffnm`, el log y las rutas ya los resuelve el script.

### Reglas

- **Valores por defecto**: sin flags, el script sigue usando `-v -pin o` como antes. Si pasas `-v`/`-nov` o `-pin ...`, el valor del usuario reemplaza al del script (no se duplica).
- **Opciones del script** llevan doble guion (`--gmx`, `--launcher`, `--allow-risky`, `--help`); **los flags de `mdrun` llevan un solo guion**. Se puede usar `--` para separar explícitamente: `./run.sh --gmx gmx -- -ntomp 8`.
- **Validación con el propio GROMACS**: antes de la primera simulación, el script ejecuta `mdrun <tus flags> -s <inexistente>` en un directorio temporal. El parser de GROMACS rechaza flags desconocidos o con valores inválidos antes de buscar el `.tpr`, así un error tipográfico se detecta en segundos y no al llegar a la etapa 3 de la cola. Como usa tu GROMACS real, respeta los flags que cambian entre versiones y los flags ocultos.
- **Rutas relativas**: `mdrun` se ejecuta dentro de `<carpeta>/<SIM>/`, por lo que una ruta relativa en un flag (por ejemplo `-table`) se resuelve desde ahí. Usa rutas absolutas.
- **Los flags son globales**: se aplican igual a minimización, annealing, NPT y NVT. No hay flags por etapa.

### Flags que el script no permite

| Flag | Estado | Motivo |
|---|---|---|
| `-s`, `-deffnm`, `-cpi`, `-cpo`, `-o`, `-x`, `-c`, `-e`, `-g` | Rechazado siempre | El script gestiona los archivos de cada simulación y la reanudación (`-cpi` lo añade solo al continuar) |
| `-maxh` | Rechazado (salvo `--allow-risky`) | `mdrun` termina antes de tiempo con código 0: el script lo daría por completado y la siguiente etapa usaría un `.gro` a medias |
| `-nsteps` | Rechazado (salvo `--allow-risky`) | Sobrescribe el `nsteps` del `.mdp`; la barra de progreso y el control de completitud dejan de ser fiables |
| `-noappend` | Rechazado (salvo `--allow-risky`) | Separa la salida en `.partNNNN` y rompe la reanudación y la detección de simulaciones completas |
| `-rerun` | Rechazado (salvo `--allow-risky`) | No ejecuta dinámica: solo recalcula energías de una trayectoria |
| `-multidir`, `-replex`, `-nex`, `-reseed` | Rechazado (salvo `--allow-risky`) | Multi-simulación / replica exchange: el flujo en cola no lo soporta |
| `-nov` | Permitido con aviso | Sin `-v` la barra solo se actualiza con el `.log` de GROMACS (cada `nstlog` pasos) |

### Referencia de flags de `mdrun`

Lista basada en `gmx mdrun -h` de GROMACS 2023, contrastada con la documentación de versiones recientes (2024-2026). **Los flags disponibles dependen de la versión**; la lista exacta de la tuya se ve con `gmx mdrun -h`, y el script la aplica automáticamente al validar.

Leyenda: ✓ se puede pasar · ⛔ lo gestiona el script · ⚠ solo con `--allow-risky`.

#### Hilos, ranks y afinidad

| Flag | Valores (por defecto) | Descripción | |
|---|---|---|---|
| `-nt` | int (0 = automático) | Total de hilos a iniciar | ✓ |
| `-ntmpi` | int (0) | Número de ranks thread-MPI (solo builds thread-MPI) | ✓ |
| `-ntomp` | int (0) | Hilos OpenMP por rank | ✓ |
| `-ntomp_pme` | int (0 = igual a `-ntomp`) | Hilos OpenMP por rank de PME | ✓ |
| `-npme` | int (-1 = automático) | Ranks dedicados a PME | ✓ |
| `-pin` | `auto` / `on` / `off` | Fijar hilos a núcleos (afinidad) | ✓ |
| `-pinoffset` | int (0) | Primer núcleo lógico al que fijar el primer hilo | ✓ |
| `-pinstride` | int (0 = minimizar hilos por núcleo físico) | Distancia entre hilos fijados | ✓ |

> Si lanzas varias simulaciones a la vez en la misma máquina, usa `-pin off` o reparte con `-pinoffset`, para que no compitan por los mismos núcleos.

#### Reparto de cálculo CPU / GPU

| Flag | Valores (por defecto) | Descripción | |
|---|---|---|---|
| `-nb` | `auto` / `cpu` / `gpu` | Interacciones no enlazantes | ✓ |
| `-pme` | `auto` / `cpu` / `gpu` | Cálculo de PME | ✓ |
| `-pmefft` | `auto` / `cpu` / `gpu` | FFT de PME | ✓ |
| `-bonded` | `auto` / `cpu` / `gpu` | Interacciones enlazantes | ✓ |
| `-update` | `auto` / `cpu` / `gpu` | Integración y constraints | ✓ |
| `-nbfe` | `auto` / `cpu` / `gpu` | Interacciones no enlazantes perturbadas (energía libre). Solo versiones recientes | ✓ |
| `-gpu_id` | string | IDs de las GPU disponibles para usar (ej: `01`) | ✓ |
| `-gputasks` | string | Asignación explícita de cada tarea (PP y PME) a una GPU | ✓ |

> Como los flags se aplican a **todas** las etapas, ten cuidado con `-update gpu`: no está soportado en minimizadores (`steep`, `cg`, `l-bfgs`) y haría fallar la etapa de minimización de la cola. `-nb gpu` y `-pme gpu` son los que se usan habitualmente en toda la cola.

#### Descomposición de dominios y balanceo

| Flag | Valores (por defecto) | Descripción | |
|---|---|---|---|
| `-dd` | 3 enteros (`0 0 0` = optimizar) | Malla de descomposición de dominios, ej: `-dd 2 2 1` | ✓ |
| `-ddorder` | `interleave` / `pp_pme` / `cartesian` | Orden de ranks en DD | ✓ |
| `-[no]ddcheck` | (sí) | Comprobar todas las interacciones enlazantes con DD | ✓ |
| `-rdd` | real (0) | Distancia máxima para interacciones enlazantes con DD (nm) | ✓ |
| `-rcon` | real (0) | Distancia máxima de P-LINCS (nm) | ✓ |
| `-dlb` | `auto` / `no` / `yes` | Balanceo dinámico de carga | ✓ |
| `-dds` | real (0.8) | Margen inicial de las celdas DD para el balanceo | ✓ |

#### Rendimiento y reproducibilidad

| Flag | Valores (por defecto) | Descripción | |
|---|---|---|---|
| `-nstlist` | int (0 = automático) | Fija `nstlist` cuando se usa Verlet buffer | ✓ |
| `-[no]tunepme` | (sí) | Optimizar el reparto de carga PME entre PP/PME o GPU/CPU | ✓ |
| `-[no]reprod` | (no) | Evitar optimizaciones que afectan la reproducibilidad binaria | ✓ |

#### Salida en pantalla, checkpoints y control

| Flag | Valores (por defecto) | Descripción | |
|---|---|---|---|
| `-[no]v` | (no) | Mostrar el avance por paso. El script lo activa por defecto (lo usa la barra de progreso) | ✓ |
| `-pforce` | real (-1) | Imprimir fuerzas mayores a este valor (kJ/mol·nm) | ✓ |
| `-cpt` | real (15) | Intervalo de checkpoint (minutos) | ✓ |
| `-[no]cpnum` | (no) | Conservar y numerar los checkpoints | ✓ |
| `-xvg` | `xmgrace` / `xmgr` / `none` | Formato de los `.xvg` | ✓ |
| `-[no]append` | (sí) | Anexar a los archivos previos al continuar desde checkpoint | ✓ |
| `-nsteps` | int (-2 = el del `.mdp`) | Número de pasos (sobrescribe el `.mdp`) | ⚠ |
| `-maxh` | real (-1) | Terminar tras 0.99 × este tiempo (horas) | ⚠ |
| `-replex`, `-nex`, `-reseed` | int | Replica exchange | ⚠ |

#### Archivos opcionales de entrada

| Flag | Descripción | |
|---|---|---|
| `-s` | Archivo `.tpr` | ⛔ |
| `-cpi` | Checkpoint de entrada (el script lo añade al reanudar) | ⛔ |
| `-table`, `-tablep`, `-tableb` | Tablas de potenciales (no enlazantes, pares y enlazantes) | ✓ |
| `-ei` | Essential dynamics (`.edi`) | ✓ |
| `-awh` | Parámetros iniciales de AWH | ✓ |
| `-plumed` | Archivo de PLUMED (solo builds con PLUMED) | ✓ |
| `-membed`, `-mp`, `-mn` | Inserción de proteína en membrana | ✓ |
| `-rerun` | Trayectoria a reprocesar | ⚠ |
| `-multidir` | Directorios de multi-simulación | ⚠ |

#### Archivos de salida

| Flag | Descripción | |
|---|---|---|
| `-o`, `-x`, `-c`, `-e`, `-g`, `-cpo` | Trayectoria `.trr`, `.xtc`, estructura final, energías, log y checkpoint | ⛔ |
| `-deffnm` | Nombre base de todos los archivos | ⛔ |
| `-dhdl`, `-field`, `-tpi`, `-tpid`, `-eo`, `-px`, `-pf`, `-ro`, `-ra`, `-rs`, `-rt`, `-mtx`, `-if`, `-swap` | Salidas especializadas (energía libre, campo eléctrico, pulling, rotación, Hessiano, IMD, swapping de iones) | ✓ |

#### Flags ocultos (aceptados aunque no salgan en `-h`)

Se ven con `gmx -hidden mdrun -h`. Los más útiles:

| Flag | Descripción | |
|---|---|---|
| `-stepout` | Cada cuántos pasos `-v` imprime el tiempo restante estimado (por defecto 100) | ✓ |
| `-resetstep`, `-[no]resethway` | Reiniciar los contadores de rendimiento (útil para benchmarks) | ✓ |
| `-ddcsx`, `-ddcsy`, `-ddcsz` | Posiciones de las celdas DD por dimensión | ✓ |
| `-imdport`, `-[no]imdwait`, `-[no]imdterm`, `-[no]imdpull` | Interactive Molecular Dynamics | ✓ |

> En GROMACS 2023 `-stepout` está oculto pero se acepta. Si en una versión posterior se elimina, la validación del script lo reportará como flag desconocido antes de empezar.

### Ejemplos

```bash
# Un solo build de GROMACS, GPU completa, 8 hilos OpenMP
./run.sh -ntmpi 1 -ntomp 8 -nb gpu -pme gpu -pin on -v

# Elegir el ejecutable sin menú
./run.sh --gmx gmx_mpi --launcher "mpirun -np 4" -ntomp 2

# Dos GPU: un rank PP en la GPU 0 y un rank PME en la GPU 1
./run.sh -ntmpi 2 -ntomp 4 -nb gpu -pme gpu -npme 1 -gputasks 01

# Ejecución desatendida (con varios GROMACS instalados hay que indicar --gmx)
nohup ./run.sh --gmx gmx -ntmpi 1 -ntomp 8 -nb gpu -pme gpu > salida.txt 2>&1 &

# Checkpoint más frecuente (cada 5 min) y sin pinning (varias simulaciones en el mismo nodo)
./run.sh -cpt 5 -pin off
```

### Opciones del propio script

| Opción | Descripción |
|---|---|
| `--gmx <nombre\|ruta>` | Ejecutable de GROMACS a usar (alternativa: variable `GMX_BIN`) |
| `--launcher "<cmd>"` | Prefijo para lanzar `mdrun` (ej: `"mpirun -np 4"`) |
| `--allow-risky` | Permite flags marcados con ⚠ (no recomendado) |
| `-h`, `--help` | Muestra la ayuda |
| `--` | Fin de las opciones del script |

## Funciones Principales

### 1. Detección de archivos base

```bash
base_dir="Base"
top_file=$(find "$base_dir" -maxdepth 1 -name "*.top" -type f | head -n1)
init_gro_file=$(find "$base_dir" -maxdepth 1 -name "*.gro" -type f | head -n1)
```

Si falta la carpeta `Base`, el `.top` o el `.gro`, el script termina con un error.

### 2. Logging y banners

- `show_simulation_start_banner()` / `show_simulation_end_banner()`: banners globales (el final incluye el tiempo total). Crea `simulation_log_YYYYMMDD_HHMMSS.log`.
- `show_individual_simulation_start()` / `show_individual_simulation_end()`: banners por simulación (tipo, carpeta, estado y tiempo).
- `log_section_separator()`: separadores de sección en el log.
- `log_message()`: logging unificado con niveles `INFO`, `SUCCESS`, `ERROR`, `WARNING` y `PROGRESS`. **Cada `WARNING` incrementa `warning_count`**.
- `log_summary()`: resumen final. El estado es `✓ Éxito` si no hubo errores ni advertencias, `✓ Éxito (advertencias: N)` si solo hubo advertencias, y `✗ Con errores (N)` si hubo errores.

### 3. Progreso

- `render_global_bar()`: línea de inicio de simulación (`Sim N/T en curso · X/T procesadas`).
- `report_queue_status()`: estado de la cola tras cada simulación (consola + log).
- `queue_tag()`: etiqueta `· Sim N/T` que se añade a la barra de pasos.
- `render_step_bar()` / `render_bar()`: barra de pasos con `█` y `░`, ajustada al ancho de la terminal.
- `draw_line()`: repinta la línea actual y gestiona los cambios de tamaño de la consola.
- `get_mdp_value()`: lee valores (`nsteps`, `integrator`) de un `.mdp`.
- `get_current_step_from_log()`: obtiene el paso actual desde el log.
- `run_mdrun_with_progress()`: ejecuta `mdrun` en segundo plano y mantiene la barra viva. Si la salida no es una terminal, delega en `run_mdrun()`.

### 4. Procesamiento de archivos MDP

- `parse_mdp_filename()`: `01-150-Base-MIN.mdp` → `01|150|Base|MIN`
- `find_and_sort_mdps()`: encuentra los `.mdp` en `MDPs/` y los ordena numéricamente. La lista se lee **una sola vez** al inicio para conocer el total de la cola.

### 5. Gestión de rutas

- `get_coordinate_file_path()`: resuelve el `.gro` de entrada (`Base`, otra simulación de la misma carpeta, o de otra carpeta como `150/NVT` desde `160`).
- `get_mdp_file_path()`: resuelve la ruta del `.mdp` dentro de `MDPs/`.

### 6. Ejecución de comandos GROMACS

- `execute_gromacs_command()`: ejecuta un comando registrando encabezado, resultado y código de salida en el log.
- `run_grompp()`: `$GMX_EXE grompp ... -maxwarn 1`
- `run_mdrun()`: ejecuta la línea construida por `build_mdrun_cmd()` (modo sin barras)
- `run_energy()`: `$GMX_EXE energy` con las selecciones por `printf`.

### 7. Extracción de energías por nombre de término

Los índices del menú de `gmx energy` cambian según el campo de fuerza, el termostato/barostato y el ensamble, por lo que **el script no usa números fijos**. En su lugar:

1. `probe_energy_terms()` ejecuta `gmx energy` sobre el `.edr` enviando solo `0`, lo que hace que GROMACS imprima el menú de términos y salga (el `.xvg` de prueba va a un directorio temporal que se borra).
2. Se parsea el menú a una tabla `índice|nombre`.
3. `find_energy_term_index()` busca cada término por **nombre**, sin distinguir mayúsculas y sin la unidad final (`Pressure (bar)` equivale a `Pressure`). La coincidencia es exacta, de modo que `Pressure` no se confunde con `Pres.-DC-(bar)`.
4. `extract_energy_terms()` arma la selección con los índices encontrados y llama a `gmx energy`.

Qué se extrae según el patrón del nombre de la simulación:

| Patrón | Términos | Archivos generados |
|---|---|---|
| `MIN*` | `Potential` | `potential.xvg` |
| `NPT*` | `Temperature`, `Pressure` y `Volume` | `temp-press.xvg`, `Volumen.xvg` |
| cualquier otro (`ANE`, `NVT`...) | `Temperature`, `Pressure` | `temp-press.xvg` |

**Si un término no existe en el `.edr`**, el script **no adivina un índice**: registra una advertencia con los términos faltantes y extrae solo los disponibles. Si no hay ninguno disponible, no genera ese `.xvg` y lo registra también como advertencia.

> Para comprobar qué términos ve el script en tu sistema: `echo 0 | gmx energy -f NPT.edr`. Las líneas del menú del tipo `11  Potential` son las que se parsean.

### 8. Verificación y reanudación

**`is_simulation_complete()`** considera una simulación completa si existen `.tpr`, `.gro` y los `.xvg` esperados según su patrón.

**`check_and_continue_simulation()`** devuelve tres códigos distintos:

| Código | Significado |
|---|---|
| `0` | Lista: ya estaba completa, solo se re-extrajeron energías, o se reanudó con éxito |
| `1` | No hay nada que reanudar: se ejecuta desde el principio |
| `2` | Intentó reanudar/completar y **falló** |

Comportamiento por situación:

| Situación | Acción |
|---|---|
| Simulación completa | Se salta |
| Existen `.gro` y `.edr` pero faltan `.xvg` | Solo se re-extraen las energías (no se repite `mdrun`) |
| Existe `.tpr` pero no terminó, con `.cpt` | `mdrun -cpi` continúa desde el checkpoint (con barra de progreso) |
| Existe `.tpr` pero no terminó, sin `.cpt` | Advertencia y reinicio de `mdrun` |
| La reanudación falla (código `2`) | Se cuenta como error y **no se relanza desde `grompp`**: el `.tpr` y el `.cpt` se conservan |

Si una reanudación falla y quieres empezar esa simulación de cero, borra manualmente su carpeta (por ejemplo `rm -r 150/NPT`) y vuelve a ejecutar `./run.sh`.

### 9. Simulación individual

`run_simulation_from_mdp()` orquesta cada simulación nueva: banner → creación de directorio → verificación de `.gro`, `.top` y `.mdp` → `grompp` → `mdrun` con barra → extracción de energías → banner final con el tiempo.

### 10. Argumentos, selección de GROMACS y flags de `mdrun`

- Lectura de argumentos: separa las opciones del script (`--gmx`, `--launcher`, `--allow-risky`, `--help`) de los flags de `mdrun`, que se guardan en el arreglo `MDRUN_USER_ARGS`.
- `check_user_flags()`: rechaza los flags gestionados por el script (`MANAGED_FLAGS`) y los que rompen la cola (`RISKY_FLAGS`, con el motivo en `risky_reason()`).
- `gmx_describe()`: ejecuta `--version` para confirmar que un ejecutable es GROMACS y devuelve versión, tipo de MPI, GPU y precisión.
- `select_gromacs()`: aplica la prioridad `--gmx` > `GMX_BIN` > búsqueda en el `PATH`, elimina duplicados por enlace y pregunta si hay varios. Fija `GMX_EXE`, `GMX_INFO` y `GMX_MPI_KIND`.
- `validate_mdrun_flags()`: comprueba los flags con el parser de la versión de GROMACS elegida (ver arriba).
- `build_mdrun_cmd()`: arma la línea de `mdrun` en este orden: launcher, ejecutable, flags por defecto del script (`-v`, `-pin o`), `-deffnm`, parámetros internos (`-cpi` al reanudar) y flags del usuario (escapados con `printf %q` para que sobrevivan al `eval`).

## Flujo de Ejecución

1. **Inicialización**: lee los argumentos, detecta/selecciona GROMACS y valida los flags de `mdrun`; luego verifica `Base/`, inicia el log (que registra el GROMACS y los flags usados), lista y ordena los `.mdp` y calcula el total de la cola.
2. **Bucle por orden numérico**: para cada `.mdp` calcula su posición en la cola y decide si saltar, reanudar o ejecutar.
3. **Cada simulación**: `grompp` → `mdrun` (barra de pasos + posición en la cola) → extracción de energías por nombre.
4. **Tras cada simulación**: se registra el estado de la cola (`Cola: N/T procesadas`).
5. **Finalización**: resumen con simulaciones procesadas, errores y advertencias, y banner final con el tiempo total.

## Ejemplo de Ejecución

### Archivos MDP

1. `01-150-Base-MIN.mdp` – Minimización desde coordenadas base
2. `02-150-MIN-ANE.mdp` – Annealing desde la minimización
3. `03-150-ANE-NPT.mdp` – Equilibrio NPT desde el annealing
4. `04-150-NPT-NVT.mdp` – Producción NVT desde NPT
5. `05-160-150_NVT-NVT.mdp` – Producción en `160` desde `150/NVT`

### Ejecución

```bash
chmod +x run.sh
./run.sh
```

### Salida esperada (durante la 2.ª simulación)

```
[2026-01-15 10:44:50] [PROGRESO] Cola: 1/5 procesadas (20%) · ✓ 1  ✗ 0
[2026-01-15 10:44:50] [PROGRESO] Procesando [02] (2/5): 150 - ANE (Referencia: MIN)

╔════════════════════════════════════════════╗
          INICIO - ANNEALING
╠════════════════════════════════════════════╣
  Fecha: 2026-01-15 10:44:50
  Carpeta: 150
  Simulación: ANE
╚════════════════════════════════════════════╝
Sim 2/5 en curso · 1/5 procesadas (20%)
██████████████░░░░░░░░░░░░░░░░  46%  Paso 4600/10000 · Sim 2/5
```

## Archivos de Log

`simulation_log_YYYYMMDD_HHMMSS.log` contiene banners, comandos ejecutados, la salida completa de GROMACS (incluida la de `mdrun -v`), tiempos, errores, advertencias, el estado de la cola tras cada simulación y el resumen final.

```bash
tail -f simulation_log_20260115_104500.log
```

## Dependencias

- **GROMACS** instalado y accesible en el `PATH` (`gmx`, `gmx_mpi`, `gmx-2025`, ...) o indicado con `--gmx`. Si lo cargas con `GMXRC`, hazlo antes de ejecutar el script
- **Bash 4.3** o superior (`mapfile` e índices negativos de arrays)
- `awk`, `find`, `sed`, `tput`, `mktemp`, `timeout`, `readlink` (disponibles por defecto en WSL2/Ubuntu)
- Solo para builds MPI con varios ranks: `mpirun` (o el lanzador de tu clúster) y `--launcher`

## Uso

```bash
chmod +x run.sh

# Básico (pregunta qué GROMACS usar si hay varios)
./run.sh

# Con flags de mdrun
./run.sh -ntmpi 1 -ntomp 8 -nb gpu -pme gpu -pin on -v

# Ejecución desatendida (sin barras; el avance queda en el log).
# Sin terminal no se puede preguntar, así que con varios GROMACS hay que usar --gmx
nohup ./run.sh --gmx gmx -ntomp 8 -nb gpu > salida.txt 2>&1 &
tail -f simulation_log_*.log
```

Ayuda completa: `./run.sh --help`

## Cambios respecto a la versión anterior

### Esta versión

- **Detección y selección de GROMACS**: ya no se asume `gmx`. Se buscan todos los `gmx*` del `PATH`, se verifican con `--version` y, si hay varios, se pregunta cuál usar (o se indica con `--gmx` / `GMX_BIN`). El ejecutable elegido se usa en `grompp`, `mdrun` y `energy`.
- **Flags de `mdrun` por línea de comandos**: cualquier flag de un solo guion se pasa a `mdrun` en todas las simulaciones, incluida la reanudación desde checkpoint. Los valores por defecto `-v -pin o` solo se aplican si el usuario no los fija.
- **Validación de flags** con el propio GROMACS antes de lanzar la cola, y rechazo de los flags que el script gestiona (`-s`, `-deffnm`, `-cpi`, ...) o que romperían el flujo (`-maxh`, `-nsteps`, `-noappend`, multi-simulación). `--allow-risky` permite los segundos.
- **Soporte para builds MPI** con `--launcher "mpirun -np N"` y avisos cuando los flags no corresponden al tipo de build.
- **Ayuda integrada** con `--help`.
- El log registra el GROMACS elegido, su versión y los flags usados.

### Versión anterior

- **Cola global**: el porcentaje ahora se reporta al terminar cada simulación (`Cola: N/T procesadas`), con contador de éxitos y errores. La barra de pasos incluye `· Sim N/T`, y la línea de inicio aclara que cuenta simulaciones ya procesadas.
- **Advertencias**: `warning_count` se incrementa en cada `log_message "WARNING"`, por lo que el resumen final ya no marca siempre 0.
- **Reanudación**: si falla, ya no se relanza desde `grompp`; se cuenta como error y se conservan `.tpr` y `.cpt`.
- **Energías**: los términos se buscan por nombre en el `.edr` en lugar de usar índices fijos (10, 15, 17, 22).
- **Resumen**: el banner final indica `✓ Éxito (advertencias: N)` cuando hubo advertencias sin errores.

Este sistema permite organizar y ejecutar protocolos de simulación complejos de forma reproducible y automatizada, con seguimiento visual del avance y verificación del estado de cada paso.
