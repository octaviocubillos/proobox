#!/data/data/com.termux/files/usr/bin/bash

# Este script gestiona la visualización del estado de los contenedores.

# --- Variables de Configuración Global ---
CONTAINERS_DIR="$HOME/.termux-container/containers"

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh" # Ruta al script de utilidades.
METADATA_SCRIPT="$SCRIPT_DIR/metadata.sh" # Ruta al script de metadatos.

# Cargar utils.sh (para command_exists)
if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. Funcionalidad limitada." >&2
  exit 1
fi

# Cargar metadata.sh (para is_running y para jq)
if [ -f "$METADATA_SCRIPT" ]; then
  . "$METADATA_SCRIPT" 
  # No necesitamos verificar funciones específicas aquí si ya lo hace el run.sh al cargar.
  # Solo asegurar que el script se cargó.
else
  echo "Error: No se encontró el script de metadatos '$METADATA_SCRIPT'. La visualización puede ser imprecisa." >&2
  exit 1
fi

# Determina si un proceso proot está en ejecución para un contenedor dado.
# Esta función DEBE existir para ps.sh
is_running() {
    local container_name="$1"
    local rootfs_path_escaped=$(echo "$CONTAINERS_DIR/$container_name/rootfs" | sed 's/\//\\\//g')
    if pgrep -f "proot.*-r $rootfs_path_escaped" >/dev/null; then
        echo "Running"
    else
        echo "Exited"
    fi
}

# Obtiene el tamaño del rootfs de un contenedor.
get_container_size() {
    local container_name="$1"
    local rootfs_path="$CONTAINERS_DIR/$container_name/rootfs"
    if [ -d "$rootfs_path" ]; then
        du -sh "$rootfs_path" 2>/dev/null | awk '{print $1}'
    else
        echo "0B"
    fi
}

# --- Lógica Principal del Script ps.sh ---
main_ps_logic() {
  local SHOW_ALL=false
  local SHOW_QUIET=false
  local SHOW_LATEST=false
  local SHOW_SIZE=false
  local NUM_TO_SHOW="" # Para ps -n <num>

  # Parseo de opciones
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -a|--all)
        SHOW_ALL=true
        shift
        ;;
      -q|--quiet)
        SHOW_QUIET=true
        shift
        ;;
      -l|--latest)
        SHOW_LATEST=true
        shift
        ;;
      -n|--last)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          NUM_TO_SHOW="$2"
          shift 2
        else
          echo "Error: Se requiere un número para la opción -n/--last."
          show_ps_help
          return 1
        fi
        ;;
      -s|--size)
        SHOW_SIZE=true
        shift
        ;;
      -h|--help)
        show_ps_help
        return 0
        ;;
      *)
        echo "Error: Opción desconocida: $1"
        show_ps_help
        return 1
        ;;
    esac
  done

  show_ps_help() {
    echo "Uso: ps.sh [opciones]"
    echo ""
    echo "Muestra los contenedores."
    echo ""
    echo "Opciones:"
    echo "  -a, --all              Muestra todos los contenedores (incluyendo los detenidos)."
    echo "  -q, --quiet            Muestra solo los IDs de los contenedores."
    echo "  -l, --latest           Muestra el último contenedor creado."
    echo "  -n, --last <num>       Muestra los últimos <num> contenedores creados."
    echo "  -s, --size             Muestra el tamaño total del sistema de archivos de cada contenedor."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container ps"
    echo "  ./termux-container ps -a"
    echo "  ./termux-container ps -q"
    echo "  ./termux-container ps -l"
    echo "  ./termux-container ps -n 3"
    echo "  ./termux-container ps -s"
  }

  if ! command_exists jq; then
    echo "Error: 'jq' no está instalado. Necesario para leer metadatos del contenedor. Por favor, instálalo con 'pkg install jq'."
    return 1
  fi

  echo "--- Contenedores ---"
  if [ ! -d "$CONTAINERS_DIR" ] || [ -z "$(ls -A "$CONTAINERS_DIR" 2>/dev/null)" ]; then
    echo "No hay contenedores creados aún."
    echo "Usa 'termux-container run <imagen>' para crear y ejecutar uno."
    return 0
  fi

  local container_list=()
  # Obtener los directorios de contenedores y ordenarlos por tiempo de creación (usando StartedAt del JSON)
  while IFS= read -r -d $'\0' container_dir; do
      if [ -f "$container_dir/metadata.json" ]; then
          local created_at=$(jq -r '.State.StartedAt' "$container_dir/metadata.json" 2>/dev/null)
          # Convertir fecha ISO 8601 a timestamp Unix para ordenar.
          local timestamp=$(date -d "$created_at" +%s 2>/dev/null)
          if [ -z "$timestamp" ]; then
              # Fallback a mtime del directorio si StartedAt no es un formato válido para date.
              timestamp=$(stat -c %Y "$container_dir")
          fi
          container_list+=("$timestamp|$container_dir")
      fi
  done < <(find "$CONTAINERS_DIR" -maxdepth 1 -mindepth 1 -type d -print0)

  # Ordenar por timestamp (más reciente primero)
  IFS=$'\n' sorted_containers=($(sort -r -t'|' -k1 <<<"${container_list[*]}"))
  unset IFS

  local header_printed=false
  local count=0

  if [ "${#sorted_containers[@]}" -eq 0 ]; then
    echo "No hay contenedores válidos para mostrar."
    return 0
  fi

  if ! $SHOW_QUIET; then
    printf "%-14s %-25s %-20s %-10s %-25s %s\n" "CONTAINER ID" "NAMES" "IMAGE" "STATUS" "COMMAND" "SIZE"
    echo "--------------------------------------------------------------------------------------------------------------------------------------------"
    header_printed=true
  fi

  for info_line in "${sorted_containers[@]}"; do
    local container_dir=$(echo "$info_line" | cut -d'|' -f2)
    local metadata_file="$container_dir/metadata.json"

    # Leer datos del JSON
    local container_id=$(jq -r '.Id' "$metadata_file" | head -c 12) # ID corto
    local container_name=$(jq -r '.Name' "$metadata_file")
    local image_name=$(jq -r '.Image.Name' "$metadata_file")
    local state_status_from_json=$(jq -r '.State.Status' "$metadata_file") # Estado del JSON
    local full_command_array_json=$(jq -c '.Config.Cmd' "$metadata_file" 2>/dev/null) # Comando completo como array JSON
    
    # Determinar el estado actual del contenedor (Running/Exited)
    local current_runtime_status=$(is_running "$container_name")

    local display_command="<unknown>" # Default
    # Construir el comando para mostrar, similar a docker ps
    if [ "$full_command_array_json" != "null" ] && [ "$full_command_array_json" != "[]" ]; then 
        local first_cmd_arg=$(echo "$full_command_array_json" | jq -r '.[0]')
        
        local remaining_args_json=$(echo "$full_command_array_json" | jq -c 'del(.[0])')
        local remaining_args_string=$(echo "$remaining_args_json" | jq -r 'join(" ")' | head -c 15) 
        
        display_command="${first_cmd_arg} ${remaining_args_string}..."
        if [ "${#display_command}" -gt 25 ]; then 
             display_command=$(echo "$display_command" | head -c 22)...
        fi
    fi
    
    local container_size=$(get_container_size "$container_name")

    # Aplicar filtros
    if ! $SHOW_ALL && [ "$current_runtime_status" == "Exited" ]; then
      continue # Saltar si no se pide --all y el contenedor está detenido
    fi
    
    if $SHOW_LATEST; then 
        if [ "$count" -ge 1 ]; then break; fi
    elif [ -n "$NUM_TO_SHOW" ]; then 
        if [ "$count" -ge "$NUM_TO_SHOW" ]; then break; fi
    fi

    # Mostrar según el formato
    if $SHOW_QUIET; then
      echo "$container_id"
    else
      local display_size_col=""
      if $SHOW_SIZE; then display_size_col="$container_size"; fi
      
      printf "%-14s %-25s %-20s %-10s %-25s %s\n" "$container_id" "$container_name" "$image_name" "$current_runtime_status" "$display_command" "$display_size_col"
    fi
    count=$((count + 1))
  done
  echo "--------------------------------------------------------------------------------------------------------------------------------------------"
}

# Llama a la función principal con todos los argumentos pasados al script.
main_ps_logic "$@"