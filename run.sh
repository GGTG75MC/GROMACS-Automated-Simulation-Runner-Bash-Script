#!/bin/bash

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
    echo ""
    
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
    if [ "$errors" -eq 0 ]; then
        show_simulation_end_banner "✓ Éxito"
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
    
    local grompp_cmd="gmx grompp -f \"$mdp_file\" -c \"$coord_file\" -p \"$topology_file\" -o \"$output_file\" -maxwarn 1"
    
    execute_gromacs_command "$description" "$grompp_cmd" false
    return $?
}

# Función para ejecutar mdrun
run_mdrun() {
    local deffnm="$1"
    local additional_params="${2:-}"
    local description="${3:-MDRUN}"
    
    local mdrun_cmd="gmx mdrun -v -pin o -deffnm \"$deffnm\" $additional_params"
    
    execute_gromacs_command "$description" "$mdrun_cmd" true
    return $?
}

# Función para ejecutar energy
run_energy() {
    local input_selections="$1"
    local edr_file="$2"
    local output_file="$3"
    local description="${4:-ENERGY}"
    
    local energy_cmd="printf \"$input_selections\" | gmx energy -f \"$edr_file\" -o \"$output_file\""
    
    execute_gromacs_command "$description" "$energy_cmd" false
    return $?
}

# ====================================================
#       NUEVO SISTEMA DE PARSING MDP CON NUMERACIÓN
# ===================================================

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
            # Si la referencia no tiene path, asumimos que está en la misma carpeta
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
        # Si no, asumir que está en MDPs/
        echo "MDPs/$mdp_file"
    fi
}

# Función para extraer archivos de energía según el tipo de simulación
extract_energy_files() {
    local simulation_name="$1"
    
    case "$simulation_name" in
        "MIN")
            run_energy "10\\n0" "${simulation_name}.edr" "potential.xvg" "ENERGY-${simulation_name}"
            ;;
        "NPT")
            run_energy "15\\n17\\n0" "${simulation_name}.edr" "temp-press.xvg" "ENERGY-${simulation_name}"
            run_energy "22\\n0" "${simulation_name}.edr" "Volumen.xvg" "VOLUMEN-${simulation_name}"
            ;;
        *)
            run_energy "15\\n17\\n0" "${simulation_name}.edr" "temp-press.xvg" "ENERGY-${simulation_name}"
            ;;
    esac
}

# Función para verificar si una simulación está completa
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
        "MIN")
            if [ ! -f "$sim_path/potential.xvg" ]; then
                return 1
            fi
            ;;
        "NPT")
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
            # La simulación ya inició pero no completó
            log_message "INFO" "Reiniciando simulación incompleta: $simulation_name" "$simulation_folder"
            
            if ! cd "$sim_path"; then
                log_message "ERROR" "No se puede cambiar al directorio: $sim_path" "$simulation_folder"
                return 1
            fi
            
            # Continuar desde checkpoint si existe
            local mdrun_params=""
            if [ -f "${simulation_name}.cpt" ]; then
                mdrun_params="-cpi ${simulation_name}.cpt"
                log_message "INFO" "Continuando desde checkpoint existente" "$simulation_folder"
            else
                log_message "WARNING" "No se encontró checkpoint, reiniciando simulación" "$simulation_folder"
            fi
            
            # Ejecutar mdrun
            run_mdrun "$simulation_name" "$mdrun_params" "MDRUN-CONTINUE-${simulation_name}"
            local mdrun_exit_code=$?
            
            if [ $mdrun_exit_code -eq 0 ]; then
                # Extraer energías si mdrun fue exitoso
                extract_energy_files "$simulation_name"
                log_message "SUCCESS" "Simulación $simulation_name completada exitosamente después de reinicio" "$simulation_folder"
            else
                log_message "ERROR" "Falló MDRUN al continuar $simulation_name" "$simulation_folder"
            fi
            
            cd "$current_dir"
            return $mdrun_exit_code
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
    run_mdrun "$simulation_name" "" "MDRUN-${simulation_name}"
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

# Contadores para el resumen
error_count=0
warning_count=0
processed_count=0

# Mostrar información de archivos base detectados
log_message "INFO" "Usando archivos base:"
log_message "INFO" "  TOP: $(basename "$top")"
log_message "INFO" "  GRO: $(basename "$init_gro")"

# Buscar y procesar todos los archivos MDP
log_message "INFO" "Buscando archivos MDP en carpeta MDPs"

# Verificar que existe la carpeta MDPs
if [ ! -d "MDPs" ]; then
    log_message "ERROR" "No se encuentra la carpeta MDPs"
    exit 1
fi

# Procesar archivos MDP en el orden correcto según numeración
while IFS='|' read -r order_number simulation_folder reference simulation_name mdp_file; do
    # Registrar progreso
    log_message "PROGRESS" "Procesando [$order_number]: $simulation_folder - $simulation_name (Referencia: $reference)"
    
    # Verificar si ya existe y está completa
    if check_and_continue_simulation "$simulation_folder" "$simulation_name" "$mdp_file"; then
        ((processed_count++))
        continue
    fi
    
    # Ejecutar nueva simulación
    if run_simulation_from_mdp "$order_number" "$simulation_folder" "$reference" "$simulation_name" "$mdp_file"; then
        log_message "SUCCESS" "Simulación $simulation_name completada exitosamente" "$simulation_folder"
        ((processed_count++))
    else
        log_message "ERROR" "Falló la simulación $simulation_name" "$simulation_folder"
        ((error_count++))
    fi
    
done < <(find_and_sort_mdps "MDPs")

# Registrar resumen final
log_summary "$processed_count" "$error_count" "$warning_count" "Completado"
