#!/data/data/com.termux/files/usr/bin/bash

# Este script se encarga de detener contenedores en ejecución.

# --- Cargar scripts necesarios ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
METADATA_SCRIPT="$SCRIPT_DIR/metadata.sh" # Ruta al script de metadatos.
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh" # Ruta al script de utilidades.

# Cargar utils.sh (para command_exists)
if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. Funcionalidad de detención podría ser imprecisa." >&2
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
    local containers_dir_path="$HOME/.termux-container/containers" 
    local rootfs_path_escaped=$(echo "$containers_dir_path/$container_name/rootfs" | sed 's/\//\\\//g')
    if pgrep -f "proot.*-r $rootfs_path_escaped" >/dev/null; then
        echo "Running"
    else
        echo "Exited"
    fi
}

# Obtiene el PID(s) del proceso proot asociado a un contenedor.
get_proot_pids() {
    local container_name="$1"
    local containers_dir_path="$HOME/.termux-container/containers" 
    local rootfs_path_escaped=$(echo "$containers_dir_path/$container_name/rootfs" | sed 's/\//\\\//g')
    pgrep -f "proot.*-r $rootfs_path_escaped"
}

# --- Lógica Principal del Script stop.sh ---
main_stop_logic() {
  local STOP_TIMEOUT=10 # Tiempo de espera predeterminado antes de SIGKILL
  local SIGNAL_TO_SEND="SIGTERM" # Señal predeterminada para detención suave
  local FORCE_REMOVE=false # NUEVO: Variable para la opción -f
  local TARGET_CONTAINER_ID_OR_NAME="" # Aquí se almacenará el nombre/ID del contenedor

  show_stop_help() {
    echo "Uso: stop.sh [opciones] <nombre_o_id_del_contenedor>"
    echo ""
    echo "Detiene un contenedor en ejecución."
    echo ""
    echo "Opciones:"
    echo "  -f, --force            Fuerza la detención y eliminación (usado por 'rm -f')." # Añadido a help
    echo "  -t, --time <segundos>  Tiempo de espera antes de enviar SIGKILL (por defecto: 10)."
    echo "  -s, --signal <señal>   Señal a enviar al contenedor (ej: SIGTERM, SIGKILL). (por defecto: SIGTERM)."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container stop my_app"
    echo "  ./termux-container stop -t 5 my_app"
    echo "  ./termux-container stop -s SIGKILL my_app"
    echo "  ./termux-container rm -f my_app (usa -f para stop internamente)"
  }

  # Parseo de opciones
  local ARGS_LEFT_OVER=() # Para capturar el nombre del contenedor y cualquier argumento extra.
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -f|--force) # NUEVO: Maneja la opción -f
        FORCE_REMOVE=true
        shift
        ;;
      -t|--time)
        if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
          STOP_TIMEOUT="$2"
          shift 2
        else
          echo "Error: Se requiere un número de segundos para la opción -t/--time."
          show_stop_help
          return 1
        fi
        ;;
      -s|--signal)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          SIGNAL_TO_SEND="$2"
          shift 2
        else
          echo "Error: Se requiere una señal para la opción -s/--signal."
          show_stop_help
          return 1
        fi
        ;;
      -h|--help)
        show_stop_help
        return 0
        ;;
      *) # Cualquier otro argumento no es una opción, es un argumento posicional.
        # Solo deberíamos tener uno: el nombre del contenedor.
        ARGS_LEFT_OVER+=("$1")
        shift
        ;;
    esac
  done

  # Después de procesar todas las opciones, el nombre/ID del contenedor debe ser el primer elemento en ARGS_LEFT_OVER.
  if [ ${#ARGS_LEFT_OVER[@]} -eq 0 ]; then
    echo "Error: Se debe especificar el nombre o ID del contenedor a detener."
    show_stop_help
    return 1
  fi
  if [ ${#ARGS_LEFT_OVER[@]} -gt 1 ]; then
    echo "Error: Demasiados argumentos. Solo se puede detener un contenedor a la vez."
    show_stop_help
    return 1
  fi
  TARGET_CONTAINER_ID_OR_NAME="${ARGS_LEFT_OVER[0]}" # Capturamos el nombre/ID del contenedor.


  # 1. Buscar el contenedor por nombre completo o por ID corto.
  local containers_dir_path="$HOME/.termux-container/containers"
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
  local METADATA_FILE="$container_found_path/metadata.json"

  echo "Intentando detener contenedor: '$container_name'"

  if [ "$current_status" == "Exited" ]; then
    echo "Advertencia: El contenedor '$container_name' ya está detenido."
    return 0
  fi

  # 2. Obtener el PID(s) del proceso proot y enviar la señal.
  local proot_pids=$(get_proot_pids "$container_name")

  if [ -z "$proot_pids" ]; then
    echo "Advertencia: No se encontró un proceso proot en ejecución para '$container_name'. El contenedor ya podría estar detenido o no se lanzó correctamente."
    # Si el JSON dice Running, lo actualizamos a Exited.
    if [ -f "$METADATA_FILE" ] && command_exists jq; then
        local json_status=$(jq -r '.State.Status' "$METADATA_FILE")
        if [ "$json_status" == "running" ]; then
            echo "Actualizando estado en metadatos a 'exited'."
            update_container_state_metadata "$container_name" "exited" "false" "null" # Código de salida null si no se pudo determinar.
        fi
    fi
    return 0
  fi

  echo "Enviando señal $SIGNAL_TO_SEND a los procesos proot (PIDs: $proot_pids)..."
  kill -$SIGNAL_TO_SEND $proot_pids 2>/dev/null # Envía la señal especificada

  # Dar un tiempo para que el proceso termine suavemente.
  echo "Esperando hasta $STOP_TIMEOUT segundos..."
  sleep "$STOP_TIMEOUT"

  # 3. Verificar si el proceso terminó, si no, forzar la terminación con SIGKILL.
  current_status=$(is_running "$container_name")
  if [ "$current_status" == "Running" ]; then
    echo "El contenedor '$container_name' no se detuvo después de $STOP_TIMEOUT segundos. Forzando terminación con SIGKILL..."
    kill -9 $proot_pids 2>/dev/null
    sleep 1 # Dar un poco más de tiempo.
    current_status=$(is_running "$container_name")
  fi

  if [ "$current_status" == "Exited" ]; then
    echo "Contenedor '$container_name' detenido correctamente."
    # Actualizar metadatos del contenedor a estado "exited".
    update_container_state_metadata "$container_name" "exited" "false" "0" # Asumimos 0 si se detuvo por kill.
  else
    echo "Error: No se pudo detener el contenedor '$container_name'. Puede que haya procesos huérfanos."
    return 1
  fi

  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
main_stop_logic "$@"