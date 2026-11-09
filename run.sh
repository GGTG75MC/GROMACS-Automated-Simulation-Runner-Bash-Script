#!/bin/bash

# ==========================================
#       ARGUMENTOS DE LÍNEA DE COMANDOS
# ==========================================
# Uso:  ./run.sh [opciones del script] [flags de mdrun ...]
#
# Todo lo que NO sea una opción del script (--gmx, --launcher, ...) se pasa
# tal cual a "gmx mdrun" en TODAS las simulaciones de la cola.
# El script ya gestiona por su cuenta -s, -deffnm, -cpi y los nombres de salida.

GMX_REQUESTED="${GMX_BIN:-}"   # --gmx o variable de entorno GMX_BIN
MDRUN_LAUNCHER=""              # --launcher "mpirun -np 4"
ALLOW_RISKY=false              # --allow-risky
MDRUN_USER_ARGS=()             # flags de mdrun escritos por el usuario

cli_error() {
    echo "ERROR: $*" >&2
    exit 1
}

cli_warn() {
    echo "ADVERTENCIA: $*" >&2
}

show_usage() {
    cat <<'EOF'
GROMACS Automated Simulation Runner

USO
  ./run.sh [opciones del script] [flags de mdrun]

OPCIONES DEL SCRIPT (doble guion)
  --gmx <nombre|ruta>   Ejecutable de GROMACS a usar (ej: gmx_mpi, /opt/gromacs/bin/gmx).
                        También se puede fijar con la variable de entorno GMX_BIN.
                        Si no se indica y hay más de uno en el PATH, se pregunta cuál.
  --launcher "<cmd>"    Prefijo para lanzar mdrun (ej: "mpirun -np 4"). Solo para builds MPI.
  --allow-risky         Permite flags que pueden romper el flujo de la cola
                        (-maxh, -nsteps, -noappend, ...). No recomendado.
  -h, --help            Muestra esta ayuda.
  --                    Fin de opciones del script; lo que sigue va a mdrun.

FLAGS DE MDRUN (un guion; se pasan tal cual)
  Hilos / ranks    -nt  -ntmpi  -ntomp  -ntomp_pme  -npme
  Afinidad         -pin <auto|on|off>  -pinoffset  -pinstride
  GPU              -nb <auto|cpu|gpu>  -pme <auto|cpu|gpu>  -pmefft  -bonded  -update
                   -gpu_id  -gputasks
  Dominios (DD)    -dd  -ddorder  -dlb <auto|no|yes>  -dds  -rdd  -rcon  -[no]ddcheck
  Rendimiento      -nstlist  -[no]tunepme  -[no]reprod
  Salida/control   -v | -nov  -pforce  -cpt <min>  -[no]cpnum  -xvg  -stepout
  (la lista completa y su descripción está en el README; para la versión
   que tengas instalada:  gmx mdrun -h)

GESTIONADOS POR EL SCRIPT (rechazados si se pasan)
  -s  -deffnm  -cpi  -cpo  -o  -x  -c  -e  -g

EJEMPLOS
  ./run.sh
  ./run.sh -ntmpi 1 -ntomp 8 -nb gpu -pme gpu -pin on -v
  ./run.sh --gmx gmx_mpi --launcher "mpirun -np 4" -ntomp 2
  nohup ./run.sh --gmx gmx -ntmpi 1 -ntomp 8 -nb gpu -pme gpu > salida.txt 2>&1 &
EOF
}

# ---- Lectura de argumentos ----
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        --gmx)
            [ $# -ge 2 ] || cli_error "--gmx requiere un valor (nombre o ruta del ejecutable)"
            GMX_REQUESTED="$2"
            shift 2
            ;;
        --gmx=*)
            GMX_REQUESTED="${1#--gmx=}"
            shift
            ;;
        --launcher)
            [ $# -ge 2 ] || cli_error "--launcher requiere un valor (ej: \"mpirun -np 4\")"
            MDRUN_LAUNCHER="$2"
            shift 2
            ;;
        --launcher=*)
            MDRUN_LAUNCHER="${1#--launcher=}"
            shift
            ;;
        --allow-risky)
            ALLOW_RISKY=true
            shift
            ;;
        --)
            shift
            MDRUN_USER_ARGS+=("$@")
            break
            ;;
        --*)
            cli_error "Opción desconocida del script: $1 (usa --help). Los flags de mdrun llevan un solo guion."
            ;;
        *)
            MDRUN_USER_ARGS+=("$1")
            shift
            ;;
    esac
done

# ---- Flags que el script no permite pasar a mdrun ----
# Gestionados por el script: rutas y nombres de archivos de cada simulación
MANAGED_FLAGS=(s deffnm cpi cpo o x c e g)
# Rompen la lógica de cola/reanudación (ver motivo en risky_reason)
RISKY_FLAGS=(maxh nsteps rerun noappend multidir replex nex reseed)

risky_reason() {
    case "$1" in
        maxh)      echo "mdrun termina antes de tiempo con código 0 y el script lo daría por completado (la siguiente etapa usaría un .gro a medias)" ;;
        nsteps)    echo "sobrescribe el nsteps del .mdp: la barra de progreso y el control de completitud dejan de ser fiables" ;;
        rerun)     echo "no ejecuta dinámica, solo recalcula energías de una trayectoria" ;;
        noappend)  echo "separa la salida en archivos .partNNNN y rompe la reanudación y la detección de simulaciones completas" ;;
        *)         echo "multi-simulación / replica exchange: el flujo en cola no lo soporta" ;;
    esac
}

check_user_flags() {
    local tok name m
    for tok in "${MDRUN_USER_ARGS[@]}"; do
        # Un flag empieza con "-" + letra (así "-1" o "0,1" se tratan como valores)
        [[ "$tok" =~ ^-[A-Za-z] ]] || continue
        name="${tok#-}"

        for m in "${MANAGED_FLAGS[@]}"; do
            if [ "$name" = "$m" ]; then
                cli_error "El flag '-$m' lo gestiona el script (archivos de cada simulación) y no puede pasarse a mdrun."
            fi
        done

        for m in "${RISKY_FLAGS[@]}"; do
            if [ "$name" = "$m" ]; then
                if $ALLOW_RISKY; then
                    cli_warn "-$m permitido con --allow-risky: $(risky_reason "$m")."
                else
                    cli_error "El flag '-$m' no está permitido: $(risky_reason "$m"). Si sabes lo que haces, usa --allow-risky."
                fi
            fi
        done
    done
}

check_user_flags

if [ -n "$MDRUN_LAUNCHER" ]; then
    command -v "${MDRUN_LAUNCHER%% *}" >/dev/null 2>&1 \
        || cli_error "El launcher '${MDRUN_LAUNCHER%% *}' no existe en el PATH"
fi

# ==========================================
#       DETECCIÓN Y SELECCIÓN DE GROMACS
# ==========================================
GMX_EXE=""        # ejecutable elegido (ruta absoluta)
GMX_INFO=""       # descripción legible de la versión
GMX_MPI_KIND=""   # "MPI" (MPI real), "thread_mpi" o similar

# Extrae el valor de una clave de la salida de "gmx --version"
#   $1 = clave (ej: "GROMACS version"), $2 = texto
gmx_field() {
    awk -v k="$1" '
        index($0, k ":") == 1 {
            v = substr($0, length(k) + 2)
            gsub(/^[ \t]+|[ \t]+$/, "", v)
            print v; exit
        }' <<< "$2"
}

# Comprueba que $1 es realmente GROMACS y devuelve "version|mpi|gpu|precision".
# Falla (código 1) si no lo es: así se descartan archivos "gmx*" ajenos.
gmx_describe() {
    local exe="$1" out ver mpi gpu prec
    out=$(timeout 20 "$exe" --version 2>&1 < /dev/null) || return 1
    ver=$(gmx_field "GROMACS version" "$out")
    [ -n "$ver" ] || return 1
    mpi=$(gmx_field "MPI library" "$out");   : "${mpi:=?}"
    gpu=$(gmx_field "GPU support" "$out");   : "${gpu:=?}"
    prec=$(gmx_field "Precision" "$out");    : "${prec:=?}"
    printf '%s|%s|%s|%s' "$ver" "$mpi" "$gpu" "$prec"
}

# Hace absoluta una ruta (el script hace "cd" a subcarpetas)
gmx_abs_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *)  printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")" ;;
    esac
}

# Fija GMX_EXE / GMX_INFO / GMX_MPI_KIND a partir de una ruta y su descripción
gmx_set_selected() {
    local exe="$1" desc="$2" ver mpi gpu prec
    IFS='|' read -r ver mpi gpu prec <<< "$desc"
    GMX_EXE="$exe"
    GMX_MPI_KIND="$mpi"
    GMX_INFO="GROMACS $ver · MPI: $mpi · GPU: $gpu · precisión: $prec"
}

select_gromacs() {
    local desc exe

    # 1) Elección explícita: --gmx o GMX_BIN
    if [ -n "$GMX_REQUESTED" ]; then
        exe=$(command -v -- "$GMX_REQUESTED" 2>/dev/null) \
            || cli_error "No se encuentra el ejecutable de GROMACS '$GMX_REQUESTED'"
        exe=$(gmx_abs_path "$exe")
        desc=$(gmx_describe "$exe") \
            || cli_error "'$exe' no responde como GROMACS (falló '--version')"
        gmx_set_selected "$exe" "$desc"
        return 0
    fi

    # 2) Búsqueda automática: todo ejecutable "gmx*" del PATH que sea GROMACS
    local -a cand_paths=() cand_descs=()
    local -A seen=()
    local -a path_dirs=()
    local dir f real
    IFS=: read -ra path_dirs <<< "$PATH"
    for dir in "${path_dirs[@]}"; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        for f in "$dir"/gmx*; do
            [ -f "$f" ] && [ -x "$f" ] || continue
            real=$(readlink -f "$f" 2>/dev/null || echo "$f")
            [ -n "${seen[$real]:-}" ] && continue       # mismo binario por otro enlace (/bin -> /usr/bin)
            desc=$(gmx_describe "$f") || continue
            seen[$real]=1
            cand_paths+=("$f")
            cand_descs+=("$desc")
        done
    done

    local n=${#cand_paths[@]}
    if [ "$n" -eq 0 ]; then
        cli_error "No se encontró ningún GROMACS (gmx*) en el PATH.
       Carga tu instalación (ej: source /usr/local/gromacs/bin/GMXRC) o usa --gmx /ruta/a/gmx"
    fi

    if [ "$n" -eq 1 ]; then
        gmx_set_selected "${cand_paths[0]}" "${cand_descs[0]}"
        return 0
    fi

    # 3) Hay varios: preguntar (solo posible con terminal)
    local i ver mpi gpu prec
    echo "¿Qué GROMACS quieres usar? (se detectaron $n)"
    echo ""
    for i in "${!cand_paths[@]}"; do
        IFS='|' read -r ver mpi gpu prec <<< "${cand_descs[$i]}"
        printf '  (%d) %s\n' "$((i + 1))" "$(basename "${cand_paths[$i]}")"
        printf '      %s · MPI: %s · GPU: %s · %s\n' "$ver" "$mpi" "$gpu" "$prec"
        printf '      %s\n' "${cand_paths[$i]}"
    done
    echo ""

    if [ ! -t 0 ]; then
        cli_error "Hay varios GROMACS y no hay terminal para preguntar. Indica uno con --gmx <nombre|ruta> (o GMX_BIN)."
    fi

    local choice
    while true; do
        read -r -p "Selecciona [1-$n]: " choice || cli_error "Selección cancelada"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ]; then
            gmx_set_selected "${cand_paths[$((choice - 1))]}" "${cand_descs[$((choice - 1))]}"
            echo ""
            return 0
        fi
        echo "Opción no válida."
    done
}

select_gromacs
echo "GROMACS seleccionado: $GMX_EXE"
echo "  $GMX_INFO"
echo ""

# ---- Validación de los flags contra ESTA versión de GROMACS ----
# Se lanza "mdrun <flags> -s <inexistente>" en un directorio temporal: el
# parser de GROMACS rechaza flags desconocidos o con valores inválidos antes
# de buscar el .tpr, así se detectan los errores de inmediato y no horas después.
# (Usar el propio GROMACS también cubre flags ocultos y los que cambian entre versiones.)
validate_mdrun_flags() {
    [ "${#MDRUN_USER_ARGS[@]}" -gt 0 ] || return 0
    local tmp out bad
    tmp=$(mktemp -d)
    out=$(cd "$tmp" && timeout 60 "$GMX_EXE" mdrun "${MDRUN_USER_ARGS[@]}" -s "$tmp/__probe__.tpr" 2>&1 < /dev/null)
    rm -rf "$tmp"

    bad=$(awk '
        /Unknown command-line option/ { print "  flag desconocido: " $NF; next }
        /^  In command-line option /   { opt = $NF; next }
        /Invalid value:/ && opt != ""  { print "  valor inválido para " opt ": " $NF }
    ' <<< "$out")

    if [ -n "$bad" ]; then
        echo "ERROR: GROMACS rechaza los flags de mdrun indicados:" >&2
        echo "$bad" >&2
        echo "Flags válidos para esta versión: $GMX_EXE mdrun -h" >&2
        exit 1
    fi
}

validate_mdrun_flags

# ---- Construcción de la línea de mdrun ----
user_has_flag() {
    local a
    for a in "${MDRUN_USER_ARGS[@]}"; do
        [ "$a" = "-$1" ] && return 0
    done
    return 1
}

# Valores por defecto del script (los del script original), salvo que el usuario los fije
MDRUN_DEFAULT_STR=""
if ! user_has_flag v && ! user_has_flag nov; then
    MDRUN_DEFAULT_STR+="-v "
fi
if user_has_flag nov; then
    cli_warn "Con -nov la barra de progreso solo se actualiza con el .log de GROMACS (cada nstlog pasos)."
fi
if ! user_has_flag pin; then
    MDRUN_DEFAULT_STR+="-pin o "
fi

# Flags del usuario, escapados para que sobrevivan al "eval" de execute_gromacs_command
MDRUN_USER_STR=""
if [ "${#MDRUN_USER_ARGS[@]}" -gt 0 ]; then
    MDRUN_USER_STR=$(printf '%q ' "${MDRUN_USER_ARGS[@]}")
    MDRUN_USER_STR="${MDRUN_USER_STR% }"
fi

# Avisos según el tipo de build
if [ "$GMX_MPI_KIND" = "MPI" ]; then
    if user_has_flag ntmpi || user_has_flag nt; then
        cli_warn "Este GROMACS usa MPI real: -ntmpi / -nt no se aplican; usa --launcher \"mpirun -np N\" para fijar los ranks."
    fi
    if [ -z "$MDRUN_LAUNCHER" ]; then
        echo "Nota: build MPI sin --launcher; mdrun se ejecutará con 1 rank. Para más: --launcher \"mpirun -np N\"" >&2
    fi
elif [ -n "$MDRUN_LAUNCHER" ]; then
    cli_warn "--launcher indicado, pero este GROMACS no es MPI real; el launcher se usará de todos modos."
fi

# Línea de comando de mdrun: $1 = deffnm, $2 = parámetros internos (ej: -cpi x.cpt)
build_mdrun_cmd() {
    local deffnm="$1" extra="${2:-}" cmd=""
    [ -n "$MDRUN_LAUNCHER" ] && cmd="$MDRUN_LAUNCHER "
    cmd+="\"$GMX_EXE\" mdrun ${MDRUN_DEFAULT_STR}-deffnm \"$deffnm\""
    [ -n "$extra" ] && cmd+=" $extra"
    [ -n "$MDRUN_USER_STR" ] && cmd+=" $MDRUN_USER_STR"
    printf '%s' "$cmd"
}

# ==========================================
#       DETECCIÓN AUTOMÁTICA DE ARCHIVOS
# ==========================================

base_dir="Base"

# Verificar que la carpeta Base existe
if [ ! -d "$base_dir" ]; then
    echo "ERROR: No se encuentra la carpeta '$base_dir'" >&2
    exit 1
fi

# Buscar archivo .top en la carpeta Base
top_file=$(find "$base_dir" -maxdepth 1 -name "*.top" -type f | head -n1)
if [ -z "$top_file" ]; then
    echo "ERROR: No se encontró archivo .top en la carpeta '$base_dir'" >&2
    exit 1
fi

# Buscar archivo .gro en la carpeta Base
init_gro_file=$(find "$base_dir" -maxdepth 1 -name "*.gro" -type f | head -n1)
if [ -z "$init_gro_file" ]; then
    echo "ERROR: No se encontró archivo .gro en la carpeta '$base_dir'" >&2
    exit 1
fi

# Mostrar archivos detectados
echo "Archivos detectados en $base_dir:"
echo "  TOP: $(basename "$top_file")"
echo "  GRO: $(basename "$init_gro_file")"
echo ""

# Configuración de variables
top="$top_file"
init_gro="$init_gro_file"

# ==========================================
#       FUNCIONES AUXILIARES EXISTENTES
# ==========================================

# Configuración de logging
SIMULATION_START_TIME=""
LOG_FILE=""

# Contadores globales (los usan log_message y el resumen final)
warning_count=0     # se incrementa automáticamente en cada log_message "WARNING"
error_count=0
processed_count=0

# Función para mostrar banner de inicio de simulación general
show_simulation_start_banner() {
    SIMULATION_START_TIME=$(date +%s)
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')
    local system_name="GROMACS MD Simulation"

    # Crear nombre del archivo de log
    LOG_FILE="simulation_log_$(date +%Y%m%d_%H%M%S).log"

    # Banner para consola
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "          INICIO DE SIMULACIÓN              "
    echo "╠════════════════════════════════════════════╣"
    echo "  Fecha: $current_date               "
    echo "  Sistema: $system_name            "
    echo "  Archivos base detectados en carpeta 'Base'"
    echo "  TOP: $(basename "$top")"
    echo "  GRO: $(basename "$init_gro")"
    echo "╚════════════════════════════════════════════╝"
    echo ""

    # Escribir al archivo de log
    {
        echo "╔════════════════════════════════════════════╗"
        echo "           INICIO DE SIMULACIÓN              "
        echo "╠════════════════════════════════════════════╣"
        echo "  Fecha: $current_date               "
        echo "  Sistema: $system_name            "
        echo "  Archivos base: $(basename "$top"), $(basename "$init_gro")"
        echo "╚════════════════════════════════════════════╝"
        echo ""
    } > "$LOG_FILE"
}

# Función para mostrar banner de final de simulación general
show_simulation_end_banner() {
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')
    local end_time=$(date +%s)
    local execution_time=$((end_time - SIMULATION_START_TIME))
    local hours=$((execution_time / 3600))
    local minutes=$(((execution_time % 3600) / 60))
    local seconds=$((execution_time % 60))
    local formatted_time=$(printf "%02d:%02d:%02d" $hours $minutes $seconds)
    local status="${1:-Completado}"  # Estado por defecto

    # Banner para consola
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "           FINAL DE SIMULACIÓN               "
    echo "╠════════════════════════════════════════════╣"
    echo "  Fecha: $current_date               "
    echo "  Estado: $status                       "
    echo "  Tiempo ejecución: $formatted_time                "
    echo "╚════════════════════════════════════════════╝"
    echo ""

    # Escribir al archivo de log
    {
        echo ""
        echo "╔════════════════════════════════════════════╗"
        echo "           FINAL DE SIMULACIÓN               "
        echo "╠════════════════════════════════════════════╣"
        echo "  Fecha: $current_date               "
        echo "  Estado: $status                       "
        echo "  Tiempo ejecución: $formatted_time                "
        echo "╚════════════════════════════════════════════╝"
        echo ""
    } >> "$LOG_FILE"
}

# Función para mostrar banner de inicio de simulación individual
show_individual_simulation_start() {
    local sim_type="$1"      # MIN, ANE, NPT, NVT
    local folder="$2"        # Carpeta actual
    local step="$3"          # Paso de la simulación
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')

    # Mapear códigos a nombres completos
    case $sim_type in
        "MIN") sim_name="MINIMIZACIÓN" ;;
        "ANE") sim_name="ANNEALING" ;;
        "NPT") sim_name="EQUILIBRIO NPT" ;;
        "NVT") sim_name="PRODUCCIÓN NVT" ;;
        *) sim_name="$sim_type" ;;
    esac

    # Banner para consola
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "          INICIO - $sim_name            "
    echo "╠════════════════════════════════════════════╣"
    echo "  Fecha: $current_date               "
    echo "  Carpeta: $folder                          "
    echo "  Simulación: $sim_type                            "
    echo "╚════════════════════════════════════════════╝"
    # Barra global (justo debajo del mensaje de inicio); la barra de pasos
    # se dibuja en la línea siguiente cuando arranca mdrun
    render_global_bar

    # Escribir al archivo de log
    {
        echo ""
        echo "╔════════════════════════════════════════════╗"
        echo "          INICIO - $sim_name            "
        echo "╠════════════════════════════════════════════╣"
        echo "  Fecha: $current_date               "
        echo "  Carpeta: $folder                          "
        echo "  Simulación: $sim_type                            "
        echo "╚════════════════════════════════════════════╝"
        echo ""
    } >> "$LOG_FILE"
}

# Función para mostrar banner de final de simulación individual
show_individual_simulation_end() {
    local sim_type="$1"      # MIN, ANE, NPT, NVT
    local folder="$2"        # Carpeta actual
    local step="$3"          # Paso de la simulación
    local status="$4"        # Éxito/Error
    local execution_time="$5" # Tiempo de ejecución (opcional)
    local current_date=$(date '+%Y-%m-%d %H:%M:%S')

    # Mapear códigos a nombres completos
    case $sim_type in
        "MIN") sim_name="MINIMIZACIÓN" ;;
        "ANE") sim_name="ANNEALING" ;;
        "NPT") sim_name="EQUILIBRIO NPT" ;;
        "NVT") sim_name="PRODUCCIÓN NVT" ;;
        *) sim_name="$sim_type" ;;
    esac

    # Si no se proporciona tiempo, usar valor por defecto
    if [ -z "$execution_time" ]; then
        execution_time="--:--:--"
    fi

    # Banner para consola
    echo ""
    echo "╔════════════════════════════════════════════╗"
    echo "          FINAL - $sim_name                "
    echo "╠════════════════════════════════════════════╣"
    echo "  Fecha: $current_date               "
    echo "  Carpeta: $folder                          "
    echo "  Estado: $status                          "
    echo "  Tiempo: $execution_time                    "
    echo "╚════════════════════════════════════════════╝"
    echo ""

    # Escribir al archivo de log
    {
        echo ""
        echo "╔════════════════════════════════════════════╗"
        echo "          FINAL - $sim_name                "
        echo "╠════════════════════════════════════════════╣"
        echo "  Fecha: $current_date               "
        echo "  Carpeta: $folder                          "
        echo "  Estado: $status                       "
        echo "  Tiempo: $execution_time                    "
        echo "╚════════════════════════════════════════════╝"
        echo ""
    } >> "$LOG_FILE"
}

# Función para crear separadores de secciones en el log
log_section_separator() {
    local section_name="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "                    $section_name"
        echo "                    [$timestamp]"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
    } >> "$LOG_FILE"
}

# Función de logging autónoma
log_message() {
    local log_type="$1"    # Tipo de mensaje: INFO, SUCCESS, ERROR, WARNING, PROGRESS
    local message="$2"     # Mensaje a registrar
    local folder="$3"      # Carpeta actual (opcional)

    # Si no se ha inicializado el archivo de log, usar nombre por defecto
    if [ -z "$LOG_FILE" ]; then
        LOG_FILE="simulation_log_$(date +%Y%m%d_%H%M%S).log"
    fi

    # Formatear timestamp
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Formatear mensaje según el tipo
    case $log_type in
        "INFO")
            if [ -n "$folder" ]; then
                echo "[$timestamp] [INFO] Carpeta $folder: $message" >> "$LOG_FILE"
                echo "[$timestamp] [INFO] Carpeta $folder: $message"
            else
                echo "[$timestamp] [INFO] $message" >> "$LOG_FILE"
                echo "[$timestamp] [INFO] $message"
            fi
            ;;
        "SUCCESS")
            if [ -n "$folder" ]; then
                echo "[$timestamp] [✓] Carpeta $folder: $message" >> "$LOG_FILE"
                echo "[$timestamp] [✓] Carpeta $folder: $message"
            else
                echo "[$timestamp] [✓] $message" >> "$LOG_FILE"
                echo "[$timestamp] [✓] $message"
            fi
            ;;
        "ERROR")
            if [ -n "$folder" ]; then
                echo "[$timestamp] [✗] Carpeta $folder: ERROR - $message" >> "$LOG_FILE"
                echo "[$timestamp] [✗] Carpeta $folder: ERROR - $message"
            else
                echo "[$timestamp] [✗] ERROR - $message" >> "$LOG_FILE"
                echo "[$timestamp] [✗] ERROR - $message"
            fi
            ;;
        "WARNING")
            warning_count=$((warning_count + 1))
            if [ -n "$folder" ]; then
                echo "[$timestamp] [⚠ ] Carpeta $folder: ADVERTENCIA - $message" >> "$LOG_FILE"
                echo "[$timestamp] [⚠ ] Carpeta $folder: ADVERTENCIA - $message"
            else
                echo "[$timestamp] [⚠ ] ADVERTENCIA - $message" >> "$LOG_FILE"
                echo "[$timestamp] [⚠ ] ADVERTENCIA - $message"
            fi
            ;;
        "PROGRESS")
            echo "[$timestamp] [PROGRESO] $message" >> "$LOG_FILE"
            echo "[$timestamp] [PROGRESO] $message"
            ;;
    esac
}

# Función para registrar resumen final
log_summary() {
    local total_processed="$1"
    local errors="$2"
    local warnings="$3"
    local status="$4"

    {
        echo ""
        echo "========== RESUMEN FINAL =========="
        echo "Total de simulaciones procesadas: $total_processed"
        echo "Errores encontrados: $errors"
        echo "Advertencias: $warnings"
        echo "Estado final: $status"
        echo "==================================="
        echo ""
    } >> "$LOG_FILE"

    # Mostrar banner de finalización
    if [ "$errors" -eq 0 ] && [ "$warnings" -eq 0 ]; then
        show_simulation_end_banner "✓ Éxito"
    elif [ "$errors" -eq 0 ]; then
        show_simulation_end_banner "✓ Éxito (advertencias: $warnings)"
    else
        show_simulation_end_banner "✗ Con errores ($errors)"
    fi
}

# Función para ejecutar comandos GROMACS
execute_gromacs_command() {
    local command_description="$1"
    local command_to_run="$2"
    local show_output="${3:-false}"

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Escribir encabezado del comando en el log
    {
        echo ""
        echo "────────────────────────────────────────────"
        echo "[$timestamp] EJECUTANDO: $command_description"
        echo "COMANDO: $command_to_run"
        echo "DIRECTORIO ACTUAL: $(pwd)"
        echo "────────────────────────────────────────────"
    } >> "$LOG_FILE"

    # Mostrar en consola qué comando se está ejecutando
    if [ "$show_output" = "true" ]; then
        echo "[$timestamp] Ejecutando: $command_description"
    fi

    # Ejecutar el comando y capturar salida en tiempo real
    local exit_code=0

    if [ "$show_output" = "true" ]; then
        # Mostrar en consola Y guardar en log
        eval "$command_to_run" 2>&1 | tee -a "$LOG_FILE"
        exit_code=${PIPESTATUS[0]}
    else
        # Solo guardar en log
        eval "$command_to_run" >> "$LOG_FILE" 2>&1
        exit_code=$?
    fi

    # Esperar un momento para que GROMACS termine de escribir logs
    sleep 1

    # Escribir resultado del comando
    {
        echo "────────────────────────────────────────────"
        if [ $exit_code -eq 0 ]; then
            echo "[$timestamp] ✓ COMPLETADO: $command_description (Exit code: $exit_code)"
        else
            echo "[$timestamp] ✗ ERROR: $command_description (Exit code: $exit_code)"
        fi
        echo "────────────────────────────────────────────"
        echo ""
    } >> "$LOG_FILE"

    return $exit_code
}

# Función para ejecutar grompp
run_grompp() {
    local mdp_file="$1"
    local coord_file="$2"
    local topology_file="$3"
    local output_file="$4"
    local description="${5:-GROMPP}"

    local grompp_cmd="\"$GMX_EXE\" grompp -f \"$mdp_file\" -c \"$coord_file\" -p \"$topology_file\" -o \"$output_file\" -maxwarn 1"

    execute_gromacs_command "$description" "$grompp_cmd" false
    return $?
}

# Función para ejecutar mdrun
run_mdrun() {
    local deffnm="$1"
    local additional_params="${2:-}"
    local description="${3:-MDRUN}"

    local mdrun_cmd
    mdrun_cmd=$(build_mdrun_cmd "$deffnm" "$additional_params")

    execute_gromacs_command "$description" "$mdrun_cmd" true
    return $?
}

# ==========================================
#       BARRAS DE PROGRESO
# ==========================================
TOTAL_SIMULATIONS=0   # se calcula antes del bucle principal
attempted_count=0     # simulaciones ya procesadas (completadas, saltadas o fallidas)
CURRENT_SIM=0         # posición (1..TOTAL) de la simulación en curso

BAR_LAST_LEN=0    # largo visible de la última línea de barra dibujada (0 = no hay)
BAR_LAST_COLS=0   # ancho de la consola cuando se dibujó

# Dibuja la línea de progreso borrando antes la anterior.
#   $1 = texto, $2 = largo visible del texto, $3 = ancho actual de la consola
# Si la consola cambió de tamaño desde el último dibujo, la terminal pudo haber
# partido la barra vieja en varias filas: se sube hasta su primera fila y se
# borra todo hacia abajo antes de redibujar con el ancho nuevo.
draw_line() {
    local text="$1" len="$2" cols="$3"
    if (( BAR_LAST_LEN > 0 && cols != BAR_LAST_COLS )); then
        local rows=$(( (BAR_LAST_LEN + cols - 1) / cols ))
        (( rows > 1 )) && printf '\033[%dA' $(( rows - 1 ))
    fi
    printf '\r\033[J%s' "$text"
    BAR_LAST_LEN=$len
    BAR_LAST_COLS=$cols
}

# Dibuja una barra en la línea actual (se repinta con \r)
#   $1 = valor actual, $2 = total, $3 = texto que va tras el porcentaje
render_bar() {
    local current="$1" total="$2" suffix_text="$3"

    # Si stdout no es terminal, no ensuciamos la salida
    [ -t 1 ] || return 0

    # Ancho actual de la consola (se relee en cada repintado)
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)

    (( total <= 0 )) && total=1
    (( current < 0 )) && current=0
    (( current > total )) && current=$total

    local pct=$(( 100 * current / total ))
    local sufijo
    sufijo=$(printf " %3d%%  %s" "$pct" "$suffix_text")

    # cols - corchetes (2) - sufijo - 1 de margen para evitar el salto de línea
    local ancho=$(( cols - 2 - ${#sufijo} - 1 ))
    (( ancho < 5 )) && ancho=5

    local llenos=$(( ancho * current / total ))
    local vacios=$(( ancho - llenos ))

    local barra_llena barra_vacia
    printf -v barra_llena '%*s' "$llenos" ''
    printf -v barra_vacia '%*s' "$vacios" ''
    barra_llena=${barra_llena// /█}
    barra_vacia=${barra_vacia// /░}

    draw_line "${barra_llena}${barra_vacia}${sufijo}" "$(( 2 + ancho + ${#sufijo} ))" "$cols"
}

# Etiqueta de posición en la cola, para añadir a la barra de pasos: "  · Sim 2/6"
queue_tag() {
    (( TOTAL_SIMULATIONS > 0 && CURRENT_SIM > 0 )) || return 0
    printf ' · Sim %d/%d' "$CURRENT_SIM" "$TOTAL_SIMULATIONS"
}

# Línea de cola al INICIAR una simulación (solo en terminal). Deja claro que el
# porcentaje cuenta simulaciones ya terminadas, sin incluir la que arranca:
#   "Sim 2/6 en curso · 1/6 procesadas (16%)"
render_global_bar() {
    [ -t 1 ] || return 0
    (( TOTAL_SIMULATIONS > 0 )) || return 0
    local pct=$(( 100 * attempted_count / TOTAL_SIMULATIONS ))
    printf "Sim %d/%d en curso · %d/%d procesadas (%d%%)\n" \
        "$CURRENT_SIM" "$TOTAL_SIMULATIONS" "$attempted_count" "$TOTAL_SIMULATIONS" "$pct"
}

# Estado de la cola al TERMINAR cada simulación (también va al log):
#   "Cola: 2/6 procesadas (33%) · ✓ 2  ✗ 0"
# Al procesar la última simulación marca 6/6 (100%) y "cola finalizada".
report_queue_status() {
    (( TOTAL_SIMULATIONS > 0 )) || return 0
    local pct=$(( 100 * attempted_count / TOTAL_SIMULATIONS ))
    local msg="Cola: $attempted_count/$TOTAL_SIMULATIONS procesadas ($pct%) · ✓ $processed_count  ✗ $error_count"
    if (( attempted_count >= TOTAL_SIMULATIONS )); then
        msg="$msg · cola finalizada"
    fi
    log_message "PROGRESS" "$msg"
}

# Barra de pasos de la simulación en curso (sin salto de línea)
#   $1 = paso actual, $2 = nsteps, $3 = prefijo (opcional)
render_step_bar() {
    local step="$1" total="$2" prefix="${3:-Paso}"
    [ -t 1 ] || return 0
    local tag
    tag=$(queue_tag)
    if (( total > 0 )); then
        render_bar "$step" "$total" "$prefix $step/$total$tag"
    else
        local texto="$prefix $step (nsteps no definido)$tag"
        draw_line "$texto" "${#texto}" "$(tput cols 2>/dev/null || echo 80)"
    fi
}

# Lee un valor de un .mdp (ignora comentarios, mayúsculas y guiones/guiones bajos)
#   $1 = archivo .mdp, $2 = clave en minúsculas con guiones (ej: nsteps, integrator)
get_mdp_value() {
    awk -v key="$2" '
        { sub(/;.*/, "") }
        index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1)
            v = substr($0, index($0, "=") + 1)
            gsub(/[ \t\r]/, "", k); gsub(/[ \t\r]/, "", v)
            k = tolower(k); gsub(/_/, "-", k)
            if (k == key) val = v
        }
        END { print val }
    ' "$1" 2>/dev/null
}

# Paso actual de mdrun. Se usan dos fuentes y se toma el mayor:
#  (1) la salida de "mdrun -v" que queda en $LOG_FILE (solo desde el byte $1,
#      donde empezó este mdrun). Con descomposición de dominios la línea trae
#      un prefijo, por eso "step N" se busca en cualquier parte de la línea:
#        "step 1200, will finish ..."
#        "vol 0.80  imb F  2% pme/F 0.9 step 1200, will finish ..."
#        "Step=   12, Dmax= ..."   (minimización)
#  (2) la tabla "Step Time" del ${deffnm}.log de GROMACS ($2), cada nstlog pasos
get_current_step_from_log() {
    local start_off="$1" mdlog="${2:-}"
    local size from s1 s2=0
    size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    from=$(( size - 16384 ))
    (( from < start_off )) && from=$start_off

    s1=$(tail -c +"$(( from + 1 ))" "$LOG_FILE" 2>/dev/null | tr '\r' '\n' | awk '
        match($0, /(^|[^A-Za-z0-9])[Ss]tep[= \t]+[0-9]+/) {
            s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); step = s + 0
        }
        /converge/ && match($0, /in [0-9]+ steps/) {
            s = substr($0, RSTART + 3, RLENGTH - 9); step = s + 0
        }
        END { print step + 0 }
    ')

    if [ -n "$mdlog" ] && [ -f "$mdlog" ]; then
        s2=$(tail -n 400 "$mdlog" 2>/dev/null | awk '
            /^[ \t]*Step[ \t]+Time/ { found = 1; next }
            found && /^[ \t]*[0-9]+[ \t]+[-0-9.eE+]+[ \t]*$/ { step = $1 + 0; found = 0 }
            END { print step + 0 }
        ')
    fi
    (( s2 > s1 )) && s1=$s2
    echo "$s1"
}

# mdrun en segundo plano con barra de pasos en tiempo real
#   $1 = deffnm, $2 = parámetros extra, $3 = descripción, $4 = ruta al .mdp
#   (la ruta debe ser válida desde el directorio actual)
run_mdrun_with_progress() {
    local deffnm="$1"
    local additional_params="${2:-}"
    local description="${3:-MDRUN}"
    local mdp_file="${4:-}"

    # Sin terminal (salida redirigida): comportamiento original, sin barras
    if [ ! -t 1 ]; then
        run_mdrun "$deffnm" "$additional_params" "$description"
        return $?
    fi

    local mdrun_cmd
    mdrun_cmd=$(build_mdrun_cmd "$deffnm" "$additional_params")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Encabezado en el log (mismo estilo que execute_gromacs_command)
    {
        echo ""
        echo "────────────────────────────────────────────"
        echo "[$timestamp] EJECUTANDO: $description"
        echo "COMANDO: $mdrun_cmd"
        echo "DIRECTORIO ACTUAL: $(pwd)"
        echo "────────────────────────────────────────────"
    } >> "$LOG_FILE"

    # TOTAL de pasos e integrador, leídos del .mdp
    local nsteps=0 integrator=""
    if [ -n "$mdp_file" ] && [ -f "$mdp_file" ]; then
        nsteps=$(get_mdp_value "$mdp_file" "nsteps")
        integrator=$(get_mdp_value "$mdp_file" "integrator")
    fi
    [[ "$nsteps" =~ ^[0-9]+$ ]] || nsteps=0

    # mdrun en segundo plano; su salida (-v) va al log
    local start_off
    start_off=$(wc -c < "$LOG_FILE")
    eval "$mdrun_cmd" < /dev/null >> "$LOG_FILE" 2>&1 &
    local mdrun_pid=$!

    # Repintado de la barra cada segundo. Si se redimensiona la consola
    # (SIGWINCH), la espera se interrumpe y la barra se borra y redibuja ya.
    BAR_LAST_LEN=0
    trap ':' WINCH
    local step=0
    while kill -0 "$mdrun_pid" 2>/dev/null; do
        step=$(get_current_step_from_log "$start_off" "${deffnm}.log")
        render_step_bar "$step" "$nsteps"
        sleep 1 &
        wait $! 2>/dev/null
    done
    wait "$mdrun_pid"
    local exit_code=$?

    # Barra final
    step=$(get_current_step_from_log "$start_off" "${deffnm}.log")
    local tag
    tag=$(queue_tag)
    if [ $exit_code -eq 0 ]; then
        if (( nsteps > 0 )); then
            case "$integrator" in
                steep|cg|l-bfgs)
                    # Minimización: puede converger antes de nsteps
                    render_bar "$nsteps" "$nsteps" "✓ Terminó en paso $step (máx. $nsteps)$tag" ;;
                *)
                    render_bar "$nsteps" "$nsteps" "✓ Paso $nsteps/$nsteps$tag" ;;
            esac
        else
            local texto="✓ Terminó en paso $step$tag"
            draw_line "$texto" "${#texto}" "$(tput cols 2>/dev/null || echo 80)"
        fi
    else
        render_step_bar "$step" "$nsteps" "✗ Paso"
    fi
    echo ""
    trap - WINCH
    BAR_LAST_LEN=0

    # Cierre en el log
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    {
        echo "────────────────────────────────────────────"
        if [ $exit_code -eq 0 ]; then
            echo "[$timestamp] ✓ COMPLETADO: $description (Exit code: $exit_code)"
        else
            echo "[$timestamp] ✗ ERROR: $description (Exit code: $exit_code)"
        fi
        echo "────────────────────────────────────────────"
        echo ""
    } >> "$LOG_FILE"

    return $exit_code
}

# Función para ejecutar energy
run_energy() {
    local input_selections="$1"
    local edr_file="$2"
    local output_file="$3"
    local description="${4:-ENERGY}"

    local energy_cmd="printf \"$input_selections\" | \"$GMX_EXE\" energy -f \"$edr_file\" -o \"$output_file\""

    execute_gromacs_command "$description" "$energy_cmd" false
    return $?
}

# ==========================================
#       NUEVO SISTEMA DE PARSING MDP CON NUMERACIÓN
# ==========================================

# Función para parsear nombres de archivos MDP con numeración
parse_mdp_filename() {
    local filename="$1"
    local basename=$(basename "$filename" .mdp)

    # Dividir por guiones: formato "numero-carpeta-referencia-simulacion"
    IFS='-' read -ra parts <<< "$basename"

    if [ ${#parts[@]} -lt 4 ]; then
        echo "ERROR: Formato de archivo MDP incorrecto: $filename" >&2
        return 1
    fi

    # Primera parte es el número de orden
    local order_number="${parts[0]}"

    # Segunda parte es la carpeta de simulación
    local simulation_folder="${parts[1]}"

    # El resto excepto la última parte es la referencia
    local reference_parts=("${parts[@]:2:${#parts[@]}-3}")
    local reference=$(IFS='-'; echo "${reference_parts[*]}")

    # Última parte es el nombre de simulación
    local simulation_name="${parts[-1]}"

    # Convertir referencias con guiones bajos a rutas
    reference=$(echo "$reference" | sed 's/_/\//g')

    echo "$order_number|$simulation_folder|$reference|$simulation_name"
}

# Función para encontrar y ordenar archivos MDP por número
find_and_sort_mdps() {
    local mdps_dir="$1"
    find "$mdps_dir" -name "*.mdp" -type f | while read -r mdp_file; do
        if result=$(parse_mdp_filename "$mdp_file"); then
            echo "$result|$mdp_file"
        fi
    done | sort -t'|' -k1,1n
}

# Función para determinar la ruta correcta del archivo de coordenadas
get_coordinate_file_path() {
    local reference_path="$1"
    local simulation_folder="$2"
    local simulation_name="$3"

    if [ "$reference_path" = "Base" ]; then
        # Usar archivos iniciales de la carpeta base - ruta absoluta desde directorio raíz
        echo "$init_gro"
    else
        # Si la referencia contiene una carpeta diferente a la actual, es una referencia externa
        if [[ "$reference_path" == */* ]] && [[ "$reference_path" != "$simulation_folder"* ]]; then
            # Referencia a otra carpeta (ej: 150/NVT desde 160)
            echo "${reference_path}/${reference_path##*/}.gro"
        else
            # Referencia dentro de la misma carpeta (ej: MIN -> 150/MIN/MIN.gro)
            local ref_name="$reference_path"
            if [[ "$reference_path" == */* ]]; then
                ref_name="${reference_path##*/}"
            fi
            echo "${simulation_folder}/${ref_name}/${ref_name}.gro"
        fi
    fi
}

# Función para obtener la ruta correcta del archivo MDP
get_mdp_file_path() {
    local mdp_file="$1"

    # Si el archivo MDP ya tiene ruta completa, usarla
    if [[ "$mdp_file" == MDPs/* ]]; then
        echo "$mdp_file"
    else
        echo "MDPs/$mdp_file"
    fi
}

# ==========================================
#  EXTRACCIÓN DE ENERGÍAS (por nombre de término, no por índice fijo)
#  Los índices de "gmx energy" cambian según el campo de fuerza, el
#  termostato/barostato y el ensamble, así que se lee la tabla de términos
#  del .edr y se busca cada término por su nombre.
#  Soporta NPT.Berendsen, NPT.Crescale, NPT.Parrinello…
# ==========================================
ENERGY_TERMS=""   # tabla "indice|nombre" del .edr consultado

# Lee la lista de términos de un .edr (el menú que imprime "gmx energy")
#   $1 = archivo .edr
probe_energy_terms() {
    local edr="$1"
    ENERGY_TERMS=""
    [ -f "$edr" ] || return 1

    local tmpdir
    tmpdir=$(mktemp -d 2>/dev/null) || return 1

    # Se envía solo "0" (terminar selección): gmx imprime el menú y sale.
    # El .xvg de prueba va a un directorio temporal que se borra después.
    ENERGY_TERMS=$(printf '0\n' | "$GMX_EXE" energy -f "$PWD/$edr" -o "$tmpdir/probe.xvg" 2>&1 | awk '
        # Líneas del menú: empiezan con un número y siguen con un nombre
        $1 ~ /^[0-9]+$/ && NF >= 2 && $2 !~ /^[0-9.]+$/ {
            idx = ""; name = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+$/) {
                    if (idx != "") print idx "|" name
                    idx = $i; name = ""
                } else {
                    name = (name == "" ? $i : name " " $i)
                }
            }
            if (idx != "") print idx "|" name
        }')
    rm -rf "$tmpdir"

    [ -n "$ENERGY_TERMS" ]
}

# Devuelve el índice del término $1 en ENERGY_TERMS (vacío si no existe).
# Compara sin distinguir mayúsculas y sin la unidad final: "Pressure (bar)" -> "pressure"
find_energy_term_index() {
    local wanted="$1"
    printf '%s\n' "$ENERGY_TERMS" | awk -F'|' -v w="$wanted" '
        {
            n = tolower($2)
            sub(/[- ]?\([^)]*\)$/, "", n)
            if (n == tolower(w)) { print $1; exit }
        }'
}

# Extrae uno o varios términos a un .xvg
#   $1 = .edr, $2 = .xvg de salida, $3 = descripción, $4... = nombres de términos
extract_energy_terms() {
    local edr="$1" out_file="$2" description="$3"
    shift 3

    local term idx selection="" found=0 missing=""
    for term in "$@"; do
        idx=$(find_energy_term_index "$term")
        if [ -n "$idx" ]; then
            selection="${selection}${idx}\\n"
            found=$((found + 1))
        else
            missing="$missing $term"
        fi
    done

    if [ -n "$missing" ]; then
        log_message "WARNING" "Términos no encontrados en $edr:$missing"
    fi
    if [ "$found" -eq 0 ]; then
        log_message "WARNING" "No se genera $out_file (ningún término disponible en $edr)"
        return 1
    fi

    run_energy "${selection}0" "$edr" "$out_file" "$description"
}

extract_energy_files() {
    local simulation_name="$1"
    local edr="${simulation_name}.edr"
    local rc=0

    if ! probe_energy_terms "$edr"; then
        log_message "WARNING" "No se pudo leer la lista de términos de $edr; no se extraen energías"
        return 1
    fi

    case "$simulation_name" in
        MIN*)
            extract_energy_terms "$edr" "potential.xvg" "ENERGY-${simulation_name}" Potential || rc=1
            ;;
        NPT*)
            extract_energy_terms "$edr" "temp-press.xvg" "ENERGY-${simulation_name}" Temperature Pressure || rc=1
            extract_energy_terms "$edr" "Volumen.xvg"    "VOLUMEN-${simulation_name}" Volume || rc=1
            ;;
        *)
            extract_energy_terms "$edr" "temp-press.xvg" "ENERGY-${simulation_name}" Temperature Pressure || rc=1
            ;;
    esac
    return $rc
}

# ==========================================
#  VERIFICACIÓN DE COMPLETITUD (con patrones)
# ==========================================
is_simulation_complete() {
    local sim_path="$1"
    local simulation_name="$2"

    # Verificar que existe el directorio
    if [ ! -d "$sim_path" ]; then
        return 1
    fi

    # Verificar que existe el archivo .tpr (simulación iniciada)
    if [ ! -f "$sim_path/${simulation_name}.tpr" ]; then
        return 1
    fi

    # Verificar que existe el archivo .gro de salida (simulación completada)
    if [ ! -f "$sim_path/${simulation_name}.gro" ]; then
        return 1
    fi

    # Verificar que existen los archivos .xvg de energía según el tipo de simulación
    case "$simulation_name" in
        MIN*)
            if [ ! -f "$sim_path/potential.xvg" ]; then
                return 1
            fi
            ;;
        NPT*)
            if [ ! -f "$sim_path/temp-press.xvg" ] || [ ! -f "$sim_path/Volumen.xvg" ]; then
                return 1
            fi
            ;;
        *)
            if [ ! -f "$sim_path/temp-press.xvg" ]; then
                return 1
            fi
            ;;
    esac

    # Si pasó todas las verificaciones, la simulación está completa
    return 0
}

# Función para verificar y continuar simulaciones existentes
# Códigos de retorno:
#   0 = simulación lista (ya completa, solo se re-extrajeron energías, o se reanudó con éxito)
#   1 = no hay nada que reanudar: hay que ejecutarla desde el principio
#   2 = intentó reanudar y FALLÓ. El bucle principal NO la relanza desde grompp,
#       para no sobrescribir el .tpr ni el checkpoint.
check_and_continue_simulation() {
    local simulation_folder="$1"
    local simulation_name="$2"
    local mdp_file="$3"

    local current_dir=$(pwd)
    local sim_path="$simulation_folder/$simulation_name"

    # Verificar si la simulación está completa
    if is_simulation_complete "$sim_path" "$simulation_name"; then
        log_message "SUCCESS" "Simulación $simulation_name ya completada" "$simulation_folder"
        return 0
    fi

    # Si el directorio existe pero la simulación no está completa
    if [ -d "$sim_path" ]; then
        if [ -f "$sim_path/${simulation_name}.tpr" ]; then

            # Salvaguarda: si mdrun YA terminó (.gro y .edr existen) pero faltan
            # solo los .xvg, NO se re-ejecuta mdrun: solo se re-extraen energías.
            if [ -f "$sim_path/${simulation_name}.gro" ] && [ -f "$sim_path/${simulation_name}.edr" ]; then
                log_message "INFO" "mdrun ya completó para $simulation_name; re-extrayendo energías faltantes" "$simulation_folder"
                if ! cd "$sim_path"; then
                    log_message "ERROR" "No se puede cambiar al directorio: $sim_path" "$simulation_folder"
                    return 2
                fi
                extract_energy_files "$simulation_name"
                local extract_rc=$?
                cd "$current_dir"
                if [ $extract_rc -ne 0 ]; then
                    log_message "ERROR" "No se pudieron re-extraer las energías de $simulation_name" "$simulation_folder"
                    return 2
                fi
                return 0
            fi

            # La simulación ya inició pero no completó
            log_message "INFO" "Reiniciando simulación incompleta: $simulation_name" "$simulation_folder"

            if ! cd "$sim_path"; then
                log_message "ERROR" "No se puede cambiar al directorio: $sim_path" "$simulation_folder"
                return 2
            fi

            # Continuar desde checkpoint si existe
            local mdrun_params=""
            if [ -f "${simulation_name}.cpt" ]; then
                mdrun_params="-cpi ${simulation_name}.cpt"
                log_message "INFO" "Continuando desde checkpoint existente" "$simulation_folder"
            else
                log_message "WARNING" "No se encontró checkpoint, reiniciando simulación" "$simulation_folder"
            fi

            # Banner de inicio (con línea de cola) justo antes de mdrun
            local continue_start_time=$(date +%s)
            show_individual_simulation_start "$simulation_name" "$simulation_folder" "-"
            log_section_separator "REINICIO - $simulation_name - CARPETA $simulation_folder"

            # Ejecutar mdrun (el .mdp se lee desde la raíz: estamos dentro de $sim_path)
            run_mdrun_with_progress "$simulation_name" "$mdrun_params" \
                "MDRUN-CONTINUE-${simulation_name}" "../../$(get_mdp_file_path "$mdp_file")"
            local mdrun_exit_code=$?

            local c_elapsed c_time
            if [ $mdrun_exit_code -eq 0 ]; then
                # Extraer energías si mdrun fue exitoso
                extract_energy_files "$simulation_name"
                log_message "SUCCESS" "Simulación $simulation_name completada exitosamente después de reinicio" "$simulation_folder"

                c_elapsed=$(( $(date +%s) - continue_start_time ))
                c_time=$(printf "%02d:%02d:%02d" $((c_elapsed / 3600)) $(((c_elapsed % 3600) / 60)) $((c_elapsed % 60)))
                show_individual_simulation_end "$simulation_name" "$simulation_folder" "-" "✓ Éxito" "$c_time"

                cd "$current_dir"
                return 0
            fi

            log_message "ERROR" "Falló MDRUN al continuar $simulation_name" "$simulation_folder"
            c_elapsed=$(( $(date +%s) - continue_start_time ))
            c_time=$(printf "%02d:%02d:%02d" $((c_elapsed / 3600)) $(((c_elapsed % 3600) / 60)) $((c_elapsed % 60)))
            show_individual_simulation_end "$simulation_name" "$simulation_folder" "-" "✗ Error" "$c_time"

            cd "$current_dir"
            return 2
        fi
    fi

    # Si llegamos aquí, necesitamos ejecutar la simulación desde el principio
    return 1
}

# Función para ejecutar una simulación individual
run_simulation_from_mdp() {
    local order_number="$1"
    local simulation_folder="$2"
    local reference_path="$3"
    local simulation_name="$4"
    local mdp_file="$5"

    # Guardar directorio actual para regresar después
    local current_dir=$(pwd)

    # MOSTRAR BANNER DE INICIO
    show_individual_simulation_start "$simulation_name" "$simulation_folder" "$order_number"

    # Crear separador de sección en el log
    log_section_separator "SIMULACIÓN $order_number - $simulation_name - CARPETA $simulation_folder"

    local sim_start_time=$(date +%s)

    # Crear directorio de simulación si no existe
    local sim_dir="$simulation_folder/$simulation_name"
    mkdir -p "$sim_dir"

    # Cambiar al directorio de simulación
    if ! cd "$sim_dir"; then
        log_message "ERROR" "No se puede cambiar al directorio: $sim_dir" "$simulation_folder"
        return 1
    fi

    # Determinar archivo de coordenadas de entrada - usar rutas absolutas desde directorio raíz
    local input_coord=$(get_coordinate_file_path "$reference_path" "$simulation_folder" "$simulation_name")
    local input_top="$top"  # El top siempre es el mismo

    # Verificar que el archivo de coordenadas existe (desde directorio raíz)
    if [ ! -f "../../$input_coord" ]; then
        log_message "ERROR" "No se encuentra archivo de coordenadas: $input_coord" "$simulation_folder"
        log_message "INFO" "Buscando desde directorio: $(pwd)" "$simulation_folder"
        log_message "INFO" "Intentando encontrar: ../../$input_coord" "$simulation_folder"
        log_message "INFO" "Contenido del directorio raíz:" "$simulation_folder"
        ls -la ../../ 2>/dev/null | head -10 >> "$LOG_FILE"
        cd "$current_dir"
        return 1
    fi

    # Verificar que el archivo de topología existe
    if [ ! -f "../../$input_top" ]; then
        log_message "ERROR" "No se encuentra archivo de topología: $input_top" "$simulation_folder"
        cd "$current_dir"
        return 1
    fi

    # Obtener la ruta correcta al archivo MDP
    local mdp_path=$(get_mdp_file_path "$mdp_file")

    # Verificar que el archivo MDP existe
    if [ ! -f "../../$mdp_path" ]; then
        log_message "ERROR" "No se encuentra archivo MDP: $mdp_path" "$simulation_folder"
        cd "$current_dir"
        return 1
    fi

    # Ejecutar grompp - usar rutas absolutas desde el directorio de simulación
    run_grompp "../../$mdp_path" "../../$input_coord" "../../$input_top" "${simulation_name}.tpr" "GROMPP-${simulation_name}"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Falló GROMPP para $simulation_name" "$simulation_folder"
        cd "$current_dir"
        return 1
    fi

    # Ejecutar mdrun
    run_mdrun_with_progress "$simulation_name" "" "MDRUN-${simulation_name}" "../../$mdp_path"
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Falló MDRUN para $simulation_name" "$simulation_folder"
        cd "$current_dir"
        return 1
    fi

    # Extraer energías según el tipo de simulación
    extract_energy_files "$simulation_name"

    # Volver al directorio original
    cd "$current_dir"

    # CALCULAR TIEMPO Y MOSTRAR BANNER DE FINAL
    local sim_end_time=$(date +%s)
    local sim_execution_time=$((sim_end_time - sim_start_time))
    local sim_hours=$((sim_execution_time / 3600))
    local sim_minutes=$(((sim_execution_time % 3600) / 60))
    local sim_seconds=$((sim_execution_time % 60))
    local sim_formatted_time=$(printf "%02d:%02d:%02d" $sim_hours $sim_minutes $sim_seconds)

    show_individual_simulation_end "$simulation_name" "$simulation_folder" "$order_number" "✓ Éxito" "$sim_formatted_time"
    return 0
}

# ==========================================
#              BUCLE PRINCIPAL
# ==========================================

# Iniciar logging
show_simulation_start_banner

# Mostrar información de archivos base detectados
log_message "INFO" "Usando archivos base:"
log_message "INFO" "  TOP: $(basename "$top")"
log_message "INFO" "  GRO: $(basename "$init_gro")"
log_message "INFO" "GROMACS: $GMX_EXE ($GMX_INFO)"
[ -n "$MDRUN_LAUNCHER" ] && log_message "INFO" "Launcher mdrun: $MDRUN_LAUNCHER"
log_message "INFO" "Flags mdrun: ${MDRUN_DEFAULT_STR}${MDRUN_USER_STR:-(sin flags adicionales)}"

# Buscar y procesar todos los archivos MDP
log_message "INFO" "Buscando archivos MDP en carpeta MDPs"

# Verificar que existe la carpeta MDPs
if [ ! -d "MDPs" ]; then
    log_message "ERROR" "No se encuentra la carpeta MDPs"
    exit 1
fi

# Leer la lista de MDPs UNA sola vez (para conocer el total y no depender de stdin)
mapfile -t MDP_LIST < <(find_and_sort_mdps "MDPs")
TOTAL_SIMULATIONS=${#MDP_LIST[@]}
log_message "INFO" "Total de simulaciones detectadas: $TOTAL_SIMULATIONS"

# Procesar archivos MDP en el orden correcto según numeración
for entry in "${MDP_LIST[@]}"; do
    IFS='|' read -r order_number simulation_folder reference simulation_name mdp_file <<< "$entry"

    CURRENT_SIM=$((attempted_count + 1))

    # Registrar progreso
    log_message "PROGRESS" "Procesando [$order_number] ($CURRENT_SIM/$TOTAL_SIMULATIONS): $simulation_folder - $simulation_name (Referencia: $reference)"

    # Verificar si ya existe (completa o reanudable)
    check_and_continue_simulation "$simulation_folder" "$simulation_name" "$mdp_file"
    check_rc=$?

    case $check_rc in
        0)  # Ya completa, o reanudada con éxito
            processed_count=$((processed_count + 1))
            ;;
        2)  # La reanudación falló: no se relanza desde cero para conservar .tpr y .cpt
            log_message "ERROR" "No se pudo reanudar/completar $simulation_name; no se relanza desde cero para no sobrescribir .tpr/.cpt. Revisa el log; para empezar de cero borra la carpeta $simulation_folder/$simulation_name" "$simulation_folder"
            error_count=$((error_count + 1))
            ;;
        *)  # No existía: ejecutar nueva simulación
            if run_simulation_from_mdp "$order_number" "$simulation_folder" "$reference" "$simulation_name" "$mdp_file"; then
                log_message "SUCCESS" "Simulación $simulation_name completada exitosamente" "$simulation_folder"
                processed_count=$((processed_count + 1))
            else
                log_message "ERROR" "Falló la simulación $simulation_name" "$simulation_folder"
                error_count=$((error_count + 1))
            fi
            ;;
    esac

    attempted_count=$((attempted_count + 1))
    report_queue_status
done

# Registrar resumen final
log_summary "$processed_count" "$error_count" "$warning_count" "Completado"
