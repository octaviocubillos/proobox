#!/data/data/com.termux/files/usr/bin/bash

# Este script se encarga de reiniciar contenedores existentes.

# --- Cargar scripts necesarios ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STOP_SCRIPT="$SCRIPT_DIR/stop.sh"
START_SCRIPT="$SCRIPT_DIR/start.sh"
METADATA_SCRIPT="$SCRIPT_DIR/metadata.sh" 
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh" 

# Cargar utils.sh (para command_exists)
if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. Funcionalidad limitada." >&2
  exit 1
fi

# Cargar metadata.sh (para update_container_state_metadata)
if [ -f "$METADATA_SCRIPT" ]; then
  . "$METADATA_SCRIPT" 
  if ! command_exists update_container_state_metadata; then 
      echo "Error: La función 'update_container_state_metadata' no se cargó correctamente desde '$METADATA_SCRIPT'." >&2
      echo "Asegúrate de que 'metadata.sh' sea un script de Bash válido y tenga permisos." >&2
      exit 1
  fi
else
  echo "Error: No se encontró el script de metadatos '$METADATA_SCRIPT'. La gestión del estado puede ser imprecisa." >&2
  exit 1
fi

# Determina si un proceso proot está en ejecución para un contenedor dado.
is_running() { 
    local container_name="$1"
    local containers_dir_path="$HOME/.proobox/containers" 
    local rootfs_path_escaped=$(echo "$containers_dir_path/$container_name/rootfs" | sed 's/\//\\\//g')
    if pgrep -f "proot.*-r $rootfs_path_escaped" >/dev/null; then
        echo "Running"
    else
        echo "Exited"
    fi
}

# --- Lógica Principal del Script restart.sh ---
main_restart_logic() {
  local RESTART_TIMEOUT=10 # Tiempo de espera predeterminado antes de SIGKILL
  local TARGET_CONTAINER_ID_OR_NAME=""

  show_restart_help() {
    echo "Uso: restart.sh [opciones] <nombre_o_id_del_contenedor>"
    echo ""
    echo "Reinicia uno o más contenedores en ejecución."
    echo ""
    echo "Opciones:"
    echo "  -t, --time <segundos>  Tiempo de espera para la detención antes de forzar (por defecto: 10)."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container restart my_app"
    echo "  ./termux-container restart -t 5 my_app"
  }

  # Parseo de opciones
  local RESTART_OPTIONS_FOR_STOP=() # Opciones para pasar a stop.sh
  local ARGS_LEFT_OVER=() # Para capturar el nombre del contenedor

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -t|--time)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then 
          RESTART_TIMEOUT="$2"
          RESTART_OPTIONS_FOR_STOP+=("-t" "$RESTART_TIMEOUT") # Pasa -t a stop.sh
          shift 2
        else
          echo "Error: Se requiere un número de segundos para la opción -t/--time."
          show_restart_help
          return 1
        fi
        ;;
      -h|--help)
        show_restart_help
        return 0
        ;;
      *) # Cualquier otro argumento es el nombre/ID del contenedor
        ARGS_LEFT_OVER+=("$1")
        shift
        ;;
    esac
  done

  # Después de procesar todas las opciones, el nombre del contenedor debe ser el primer elemento en ARGS_LEFT_OVER.
  if [ ${#ARGS_LEFT_OVER[@]} -eq 0 ]; then
    echo "Error: Se debe especificar el nombre o ID del contenedor a reiniciar."
    show_restart_help
    return 1
  fi
  if [ ${#ARGS_LEFT_OVER[@]} -gt 1 ]; then
    echo "Error: Demasiados argumentos. Solo se puede reiniciar un contenedor a la vez."
    show_restart_help
    return 1
  fi
  TARGET_CONTAINER_ID_OR_NAME="${ARGS_LEFT_OVER[0]}" # Capturamos el nombre/ID del contenedor.


  # 1. Buscar el contenedor.
  local containers_dir_path="$HOME/.proobox/containers"
  local container_found_path=""
  if [ -d "$containers_dir_path/$TARGET_CONTAINER_ID_OR_NAME" ]; then
    container_found_path="$containers_dir_path/$TARGET_CONTAINER_ID_OR_NAME"
  else
    local full_name_match=$(find "$containers_dir_path" -maxdepth 1 -mindepth 1 -type d -name "${TARGET_CONTAINER_ID_OR_NAME}*" -print -quit 2>/dev/null)
    if [ -n "$full_name_match" ]; then
      container_found_path="$full_name_match"
    fi
  fi

  if [ -z "$container_found_path" ]; then
    echo "Error: Contenedor '$TARGET_CONTAINER_ID_OR_NAME' no encontrado."
    return 1
  fi

  local container_name=$(basename "$container_found_path")
  local current_status=$(is_running "$container_name")

  echo "--- Reiniciando contenedor: '$container_name' ---"

  if [ "$current_status" == "Exited" ]; then
    echo "Advertencia: El contenedor '$container_name' ya está detenido. Iniciando directamente..."
  else
    echo "Contenedor '$container_name' está en ejecución. Deteniendo..."
    # Construir el comando 'stop' correctamente: "$STOP_SCRIPT" [OPCIONES] [NOMBRE_CONTENEDOR]
    local stop_command_array=("$STOP_SCRIPT")
    stop_command_array+=("-f") # Siempre forzar la detención para restart
    stop_command_array+=("${RESTART_OPTIONS_FOR_STOP[@]}") # Añadir opciones -t o -s (si vienen de restart)
    stop_command_array+=("$container_name") # Nombre del contenedor al final

    echo "  (Llamando a: ${stop_command_array[*]})" # Depuración
    if ! "${stop_command_array[@]}"; then # Ejecutar como array
      echo "Error: Falló la detención del contenedor '$container_name'. No se puede reiniciar."
      return 1
    fi
    sleep 1 # Pequeña pausa para asegurar la detención.
  fi


  # 3. Iniciar el contenedor.
  # La clave es pasarle a start.sh ÚNICAMENTE el nombre del contenedor.
  local start_command_array=("$START_SCRIPT" "$container_name") # ¡NUEVO: Solo el nombre del contenedor!

  echo "Iniciando contenedor '$container_name' nuevamente..."
  # Ejecutamos el comando start.sh con solo el nombre del contenedor.
  echo "  (Llamando a: ${start_command_array[*]})" # Depuración
  if "${start_command_array[@]}"; then 
    echo "¡Contenedor '$container_name' reiniciado con éxito!"
  else
    echo "Error: Falló el inicio del contenedor '$container_name'."
    return 1
  fi

  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
main_restart_logic "$@"