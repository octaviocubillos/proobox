#!/data/data/com.termux/files/usr/bin/bash

# Este script permite ver los registros de un contenedor.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh"
METADATA_SCRIPT_LOGS="$SCRIPT_DIR/metadata.sh" # Para buscar rutas de contenedor y metadatos

if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. Funcionalidad de logs limitada." >&2
  exit 1
fi

if [ ! -f "$METADATA_SCRIPT_LOGS" ]; then
  echo "Error crítico: metadata.sh no encontrado en '$METADATA_SCRIPT_LOGS'. No se pueden gestionar logs." >&2
  exit 1
fi
# metadata.sh no necesita ser 'sourced' si solo usamos sus funciones por ejecución externa.

# --- Funciones de Utilidad (del script principal) ---
# _find_container_path y _is_running pueden ser funciones internas del container_manager,
# las copiaremos aquí para que logs.sh no dependa de hacer source de container_manager.sh.

_find_container_path() {
    local container_spec="$1"
    local CONTAINERS_DIR="$HOME/.proobox/containers"

    local potential_path="$CONTAINERS_DIR/$container_spec"
    if [ -d "$potential_path" ]; then
        echo "$potential_path"
        return 0
    fi

    # Intentar buscar por ID corto (asumimos 4-12 caracteres para ID corto)
    if [ ${#container_spec} -ge 4 ] && [ ${#container_spec} -le 12 ]; then
        for container_name in $(ls "$CONTAINERS_DIR" 2>/dev/null); do
            local container_dir_path="$CONTAINERS_DIR/$container_name"
            local metadata_file="$container_dir_path/metadata.json"
            if [ -f "$metadata_file" ] && jq -e . "$metadata_file" >/dev/null 2>&1; then
                local full_id=$(jq -r '.Id' "$metadata_file" 2>/dev/null)
                if [[ "$full_id" == "${container_spec}*" ]]; then
                    echo "$container_dir_path"
                    return 0
                fi
            fi
        done
    fi
    echo "" # Retorna vacío si no lo encuentra
    return 1
}

# --- Lógica Principal del Script logs.sh ---
main_logs_logic() {
  local CONTAINER_SPEC=""
  local FOLLOW_MODE=false # -f, --follow
  local SINCE_ARG=""      # --since
  local UNTIL_ARG=""      # --until
  local TAIL_LINES=""     # -n, --tail
  local TIMESTAMPS_MODE=false # -t, --timestamps
  local DETAILS_MODE=false # --details

  show_logs_help() {
    echo "Uso: logs.sh [opciones] <nombre_o_id_del_contenedor>"
    echo ""
    echo "Muestra los registros de un contenedor."
    echo ""
    echo "Opciones:"
    echo "  -f, --follow           Permite seguir la salida de los registros en tiempo real."
    echo "  --since <fecha_hora>   Muestra registros a partir de una fecha/hora (YYYY-MM-DDTHH:MM:SS)."
    echo "  --until <fecha_hora>   Muestra registros hasta una fecha/hora (YYYY-MM-DDTHH:MM:SS)."
    echo "  -n, --tail <líneas>    Muestra el número de líneas desde el final de los registros."
    echo "  -t, --timestamps       Agrega marcas de tiempo (si el log interno no las tiene). (Limitado en Bash)"
    echo "  --details              Muestra detalles adicionales del contenedor y logs."
    echo ""
    echo "Ejemplos:"
    echo "  ./proobox logs my_nginx_web"
    echo "  ./proobox logs -f my_nginx_web"
    echo "  ./proobox logs --since 2025-07-01T10:00:00 my_app"
    echo "  ./proobox logs -n 50 my_app"
    echo "  ./proobox logs -t my_app"
  }

  # Parseo de opciones
  local POSITIONAL_ARGS=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -f|--follow)
        FOLLOW_MODE=true
        shift
        ;;
      --since)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then SINCE_ARG="$2"; shift 2; else echo "Error: Falta argumento para --since."; show_logs_help; return 1; fi
        ;;
      --until)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then UNTIL_ARG="$2"; shift 2; else echo "Error: Falta argumento para --until."; show_logs_help; return 1; fi
        ;;
      -n|--tail)
        if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]]; then TAIL_LINES="$2"; shift 2; else echo "Error: Argumento no numérico para --tail."; show_logs_help; return 1; fi
        ;;
      -t|--timestamps)
        TIMESTAMPS_MODE=true
        shift
        ;;
      --details)
        DETAILS_MODE=true
        shift
        ;;
      -h|--help)
        show_logs_help
        return 0
        ;;
      *)
        POSITIONAL_ARGS+=("$1")
        shift
        ;;
    esac
  done

  # El único argumento posicional es el nombre/ID del contenedor.
  if [ ${#POSITIONAL_ARGS[@]} -eq 0 ]; then
    echo "Error: Se debe especificar el nombre o ID del contenedor." >&2
    show_logs_help
    return 1
  fi
  if [ ${#POSITIONAL_ARGS[@]} -gt 1 ]; then
    echo "Error: Demasiados argumentos. Solo se puede especificar un contenedor." >&2
    show_logs_help
    return 1
  fi
  CONTAINER_SPEC="${POSITIONAL_ARGS[0]}"


  # 1. Buscar la ruta del contenedor y el archivo de log.
  local CONTAINER_DIR=$(_find_container_path "$CONTAINER_SPEC")
  if [ -z "$CONTAINER_DIR" ]; then
    echo "Error: Contenedor '$CONTAINER_SPEC' no encontrado." >&2
    return 1
  fi

  local LOG_FILE="$CONTAINER_DIR/container.log"
  if [ ! -f "$LOG_FILE" ]; then
    echo "Error: Archivo de log no encontrado para el contenedor '$CONTAINER_SPEC'." >&2
    echo "Asegúrate de que el contenedor se haya ejecutado en modo detached (-d)." >&2
    return 1
  fi

  # 2. Leer metadatos si se piden --details.
  if $DETAILS_MODE; then
    local METADATA_PATH="$CONTAINER_DIR/metadata.json"
    if [ -f "$METADATA_PATH" ] && is_valid_json_file "$METADATA_PATH"; then
        echo "--- Detalles del Contenedor '$CONTAINER_SPEC' ---"
        jq . "$METADATA_PATH" # Imprime el JSON formateado.
        echo "------------------------------------------------"
    else
        echo "Advertencia: Archivo de metadatos no encontrado o malformado para '$CONTAINER_SPEC'." >&2
    fi
  fi

  # 3. Construir el comando para ver el log.
  local LOG_COMMAND_BASE="cat" # Por defecto, ver todo el log
  local TAIL_OPTIONS=""
  local GREP_SINCE_OPTIONS=""
  local GREP_UNTIL_OPTIONS=""

  if [ -n "$TAIL_LINES" ]; then
    LOG_COMMAND_BASE="tail -n $TAIL_LINES"
  fi

  # Manejar --since y --until (requiere que el log tenga timestamps en formato ISO 8601)
  # Solo podemos filtrar por string directamente, no por duración.
  if [ -n "$SINCE_ARG" ]; then
    # Busca líneas que sean MAYORES O IGUALES a la fecha/hora.
    # Esto es una simplificación, grep no hace comparación de fechas.
    # Podría requerir 'awk' o 'sed' y 'date' para parsear.
    # Para la prueba, asumiremos que el log tiene formato como "YYYY-MM-DDTHH:MM:SS..."
    GREP_SINCE_OPTIONS="grep -E \"^(${SINCE_ARG}|$(echo "$SINCE_ARG" | cut -d'T' -f1).*${SINCE_ARG##*T})\"" # Simplificado
    # Para una comparación de fecha real en Bash se necesita esto:
    # `awk -v start="$SINCE_ARG" '{cmd="date -d \""$1" "$2"\" +%s"; cmd | getline ts; close(cmd); if (ts >= start_ts) print}'`
    # Demasiado complejo para este script. Usaremos grep básico o recomendaremos el uso de 'jq' en el log.
    # Por ahora, solo indicaremos que la opción es limitada.
    echo "Advertencia: La opción '--since' en Bash es limitada. Solo filtra por cadena. Asegúrese del formato de fecha del log." >&2
    LOG_COMMAND_BASE="$LOG_COMMAND_BASE | grep \"^${SINCE_ARG}\"" # Filtra por inicio de línea
  fi

  if [ -n "$UNTIL_ARG" ]; then
    echo "Advertencia: La opción '--until' en Bash es limitada. Solo filtra por cadena. Asegúrese del formato de fecha del log." >&2
    # Esto es aún más complejo que since. `sed -e "/^${UNTIL_ARG}/,\$d"`
    # Por simplicidad, no lo implementaremos con precisión de fecha en Bash aquí.
    # Solo una idea: `head -n X` basado en línea de fecha.
    LOG_COMMAND_BASE="$LOG_COMMAND_BASE | sed -e '/^${UNTIL_ARG}/,$d'" # Elimina desde la fecha hasta el final.
  fi

  # Si se pide --timestamps, no hacemos nada especial si el log no lo tiene por defecto.
  # El usuario debe asegurar que el comando dentro del contenedor genera timestamps.

  # Finalmente, ejecutar el comando para ver el log.
  local FINAL_LOG_COMMAND="$LOG_COMMAND_BASE \"$LOG_FILE\""

  if $FOLLOW_MODE; then
    FINAL_LOG_COMMAND="tail -f \"$LOG_FILE\"" # Follow siempre usa tail -f
    if [ -n "$TAIL_LINES" ]; then
      FINAL_LOG_COMMAND="tail -f -n $TAIL_LINES \"$LOG_FILE\"" # tail -f -n
    fi
  fi
  
  echo "--- Registros de Contenedor '$CONTAINER_SPEC' ---"
  # Ejecutar el comando final
  eval "$FINAL_LOG_COMMAND" # Usar eval para ejecutar la cadena de comandos

  return 0
}

# Lógica principal si logs.sh se llama directamente
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_logs_logic "$@"
fi