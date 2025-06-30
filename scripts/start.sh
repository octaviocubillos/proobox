#!/data/data/com.termux/files/usr/bin/bash

# Este script se encarga de iniciar contenedores existentes.
# Lee el modo de ejecución (detached/interactivo) del metadata.json del contenedor.

# --- Cargar scripts necesarios ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
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
    local containers_dir_path="$HOME/.termux-container/containers" 
    local rootfs_path_escaped=$(echo "$containers_dir_path/$container_name/rootfs" | sed 's/\//\\\//g')
    if pgrep -f "proot.*-r $rootfs_path_escaped" >/dev/null; then
        echo "Running"
    else
        echo "Exited"
    fi
}

# --- Lógica Principal del Script start.sh ---
main_start_logic() {
  local TARGET_CONTAINER_ID_OR_NAME="$1" # El único argumento esperado es el nombre/ID.

  show_start_help() {
    echo "Uso: start.sh <nombre_o_id_del_contenedor>"
    echo ""
    echo "Inicia un contenedor detenido con su configuración original (modo interactivo o detached)."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container start my_app"
    echo "  ./termux-container start <ID_CORTO>"
  }

  # Validar que solo se pasó un argumento (el nombre del contenedor).
  if [ -z "$TARGET_CONTAINER_ID_OR_NAME" ] || [ "$#" -gt 1 ]; then
    echo "Error: Uso incorrecto. El comando 'start' solo acepta el nombre o ID de un contenedor."
    show_start_help
    return 1
  fi

  # 1. Buscar el contenedor.
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
  
  if [ "$current_status" == "Running" ]; then
    echo "Error: El contenedor '$container_name' ya está en ejecución."
    return 1
  fi

  local METADATA_FILE="$container_found_path/metadata.json"
  if [ ! -f "$METADATA_FILE" ]; then
    echo "Error: Archivo de metadatos no encontrado para el contenedor '$container_name'. No se puede iniciar."
    return 1
  fi

  # Leer metadatos del JSON para reconstruir el comando de ejecución
  local image_tag=$(jq -r '.Image.Name' "$METADATA_FILE")
  local parsed_distribution_name=$(jq -r '.Image.Name' "$METADATA_FILE" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  local container_rootfs=$(jq -r '.Paths.RootfsPath' "$METADATA_FILE")
  local env_vars_from_json_array_string=$(jq -c '.Config.Env' "$METADATA_FILE")
  local command_from_json_array_string=$(jq -c '.Config.Cmd' "$METADATA_FILE")
  local image_workdir_from_json=$(jq -r '.ContainerConfig.WorkingDir' "$METADATA_FILE")
  local auto_remove=$(jq -r '.HostConfig.AutoRemove' "$METADATA_FILE") # --rm flag original

  # NUEVO: Leer los modos de ejecución originales del JSON
  local was_detached_original=$(jq -r '.State.DetachedOriginal // "false"' "$METADATA_FILE") # Default a false
  local was_interactive_original=$(jq -r '.State.InteractiveOriginal // "false"' "$METADATA_FILE") # Default a false

  # Asegurarse de que image_workdir_from_json no sea "null" o vacío.
  if [ "$image_workdir_from_json" == "null" ] || [ -z "$image_workdir_from_json" ]; then
      image_workdir_from_json="/root" # Fallback seguro
  fi

  # Reconstruir RECONSTRUCTED_ENVIRONMENT_VARS array desde el JSON
  local RECONSTRUCTED_ENVIRONMENT_VARS=()
  if [ "$env_vars_from_json_array_string" != "null" ] && [ "$env_vars_from_json_array_string" != "[]" ]; then
      while IFS= read -r env_item; do
          RECONSTRUCTED_ENVIRONMENT_VARS+=("$env_item")
      done < <(echo "$env_vars_from_json_array_string" | jq -r '.[]')
  fi

  # Reconstruir COMMAND_TO_RUN array desde el JSON
  local RECONSTRUCTED_COMMAND_TO_RUN=()
  if [ "$command_from_json_array_string" != "null" ] && [ "$command_from_json_array_string" != "[]" ]; then
      while IFS= read -r cmd_item; do
          RECONSTRUCTED_COMMAND_TO_RUN+=("$cmd_item")
      done < <(echo "$command_from_json_array_string" | jq -r '.[]')
  fi

  # Decidir el comando final para proot (el mismo que fue lanzado originalmente)
  local FINAL_COMMAND_FOR_PROOT=("${RECONSTRUCTED_COMMAND_TO_RUN[@]}")


  echo "Iniciando contenedor '$container_name' con configuración original..."

  # --- Construir el comando proot como un array (reutilizando lógica de run.sh) ---
  unset LD_PRELOAD # ¡Crucial para evitar conflictos con termux-exec!

  local PROOT_COMMAND_ARRAY=(
    proot
    --link2symlink
    -0 
    -r "$container_rootfs" 
    
    # Bind mounts estáticos y comunes:
    -b /dev
    -b /proc
    -b /sys
    -b /data/data/com.termux/files/usr/tmp:/tmp 
    -b /data/data/com.termux:/data/data/com.termux 
    -b /:/host-rootfs 
    -b /sdcard
    -b /storage 
    -b /mnt
    # resolv.conf se crea en el rootfs, no se monta aquí.
  )
  
  # Argumentos específicos de proot por distribución (para Alpine busybox):
  if [ "$parsed_distribution_name" == "alpine" ]; then
      PROOT_COMMAND_ARRAY+=("-b" "$container_rootfs/bin/busybox:/bin/sh")
  elif [ "$parsed_distribution_name" == "ubuntu" ]; then
      PROOT_COMMAND_ARRAY+=() 
  fi

  # WORKDIR para el comando
  PROOT_COMMAND_ARRAY+=("-w" "$image_workdir_from_json") # Usar WORKDIR de los metadatos de la imagen.

  PROOT_COMMAND_ARRAY+=(
    --kill-on-exit 
    /usr/bin/env 
    -i           
  )
  
  # Variables de entorno para /usr/bin/env -i (usamos las reconstruidas)
  PROOT_COMMAND_ARRAY+=(
    "HOME=/root"
    "PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games"
    "TERM=$TERM" 
    "LANG=C.UTF-8"
  )
  
  # Añadir variables de entorno personalizadas (reconstruidas desde el JSON)
  for env_var in "${RECONSTRUCTED_ENVIRONMENT_VARS[@]}"; do
      PROOT_COMMAND_ARRAY+=("$env_var")
  done
  
  # Añadir el comando a ejecutar y sus argumentos (reconstruidos o por defecto)
  PROOT_COMMAND_ARRAY+=("${FINAL_COMMAND_FOR_PROOT[@]}")


  # --- Ejecutar el contenedor ---
  local LOG_FILE="$container_found_path/container.log" # Usamos el log del contenedor para todos los modos si es necesario.

  echo "Iniciando contenedor '$container_name' con configuración original..."

  # Decidir si ejecutar en detached o interactivo/adjunto basándose en los metadatos.
  if [ "$was_detached_original" == "true" ]; then 
    echo "Ejecutando en modo detached (segundo plano)."
    ( "${PROOT_COMMAND_ARRAY[@]}" > "$LOG_FILE" 2>&1 & )
    local CONTAINER_PID=$!
    echo "Contenedor '$container_name' iniciado en segundo plano. PID: $CONTAINER_PID"
    if command_exists update_container_state_metadata; then
        update_container_state_metadata "$container_name" "running" "true" "null"
    fi
  elif [ "$was_interactive_original" == "true" ]; then
    echo "Entrando al contenedor '$container_name' en modo interactivo."
    "${PROOT_COMMAND_ARRAY[@]}"
    local EXIT_CODE=$? 
    echo "Contenedor '$container_name' terminado. Código de salida: $EXIT_CODE"
    if command_exists update_container_state_metadata; then
        update_container_state_metadata "$container_name" "exited" "false" "$EXIT_CODE"
    fi
  else
    # Fallback: Si no se pudo determinar el modo original, ejecutar de forma interactiva (como default de Docker)
    echo "Advertencia: Modo de ejecución original no determinado. Iniciando interactivamente."
    "${PROOT_COMMAND_ARRAY[@]}"
    local EXIT_CODE=$? 
    echo "Contenedor '$container_name' terminado. Código de salida: $EXIT_CODE"
    if command_exists update_container_state_metadata; then
        update_container_state_metadata "$container_name" "exited" "false" "$EXIT_CODE"
    fi
  fi

  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
main_start_logic "$@"