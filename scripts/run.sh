#!/data/data/com.termux/files/usr/bin/bash

# Este script es el corazón de la ejecución de contenedores.
# Incluye el manejo de opciones como nombres, variables de entorno, volúmenes y modos interactivos/detached.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PULL_SCRIPT="$SCRIPT_DIR/pull.sh"
METADATA_SCRIPT="$SCRIPT_DIR/metadata.sh" 
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh"

# Cargar utils.sh
if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. La funcionalidad de ejecución podría estar limitada." >&2
  exit 1
fi

# Cargar pull.sh
if [ -f "$PULL_SCRIPT" ]; then
  . "$PULL_SCRIPT" 
else
  echo "Error: No se encontró el script de pull '$PULL_SCRIPT'. La funcionalidad de ejecución podría estar limitada." >&2
  exit 1
fi

# Cargar metadata.sh (ahora es una librería de funciones pura)
if [ -f "$METADATA_SCRIPT" ]; then
  . "$METADATA_SCRIPT" 
else
  echo "Error crítico: No se encontró el script de metadatos '$METADATA_SCRIPT'. Los metadatos no se generarán/actualizarán." >&2
  exit 1 
fi

# Directorio base para los datos de PRooBox (debe ser consistente con Python config.py)
PROOBOX_BASE_DIR="$HOME/.proobox"
CONTAINERS_DIR="$PROOBOX_BASE_DIR/containers" 
CACHED_IMAGES_DIR="$PROOBOX_BASE_DIR/cached_layers" # Cache para capas de Build (consistente con Python)

normalize_image_version() {
  local version_str="$1"
  if [ -z "$version_str" ]; then
      echo ""
      return
  fi

  if [[ "$version_str" =~ ^[0-9]+$ ]]; then # Si es solo un número entero
      echo "${version_str}.0.0"
      return
  fi
  
  if [[ "$version_str" =~ ^[0-9]+\.[0-9]+$ ]]; then # Si es X.Y
      echo "${version_str}.0"
      return
  fi
  
  echo "$version_str" # Retorna la cadena original si no coincide con los patrones
}

# --- Lógica principal de run.sh encapsulada en una función ---
main_run_logic() {
  local CONTAINER_NAME=""
  local DETACHED_MODE=false
  local REMOVE_ON_EXIT=false 
  local INTERACTIVE_TTY=false 
  local IMAGE_TAG="" 
  local COMMAND_TO_RUN_CLI=() # Comando especificado por el usuario en la línea de 'run'.
  local ENVIRONMENT_VARS=() 
  local VOLUMES=() 

  show_run_help() {
    echo "Uso: run.sh [opciones] <imagen>[:<version>] [comando] [argumentos...]"
    echo ""
    echo "Ejecuta un comando en un nuevo contenedor."
    echo ""
    echo "Opciones:"
    echo "  -n, --name <nombre>        Asigna un nombre al contenedor. Si no se especifica, se genera uno aleatorio."
    echo "  -e, --env <KEY=VALUE>      Establece una variable de entorno dentro del contenedor (ej: KEY=VALUE)."
    echo "  -d, --detach               Ejecuta el contenedor en segundo plano (detached)."
    echo "  -v, --volume <HOST:CONT>   Monta un volumen del host en el contenedor (ej: ~/data:/app/data)."
    echo "  -it, --interactive --tty   Ejecuta el contenedor en modo interactivo con una terminal."
    echo "  --rm                       Elimina el contenedor automáticamente al finalizar la ejecución."
    echo ""
    echo "Ejemplos:"
    echo "  ./proobox run ubuntu:22.04.3 /bin/bash"
    echo "  ./proobox run --name my_app -e APP_ENV=production ubuntu:22.04.3 apt update"
    echo "  ./proobox run alpine      # Descarga y ejecuta la última versión de Alpine con su shell por defecto"
    echo "  ./proobox run -d -n mydetached ubuntu:22.04.3 sleep 30"
  }

  # Parseo de opciones de línea de comandos. Consume las opciones y deja los argumentos posicionales.
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -n|--name)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          CONTAINER_NAME="$2"
          shift 2
        else
          echo "Error: Se requiere un nombre para la opción -n/--name." >&2
          show_run_help
          return 1
        fi
        ;;
      -e|--env)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          if [[ "$2" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]]; then
            ENVIRONMENT_VARS+=("$2")
            shift 2
          else
            echo "Error: Formato de variable de entorno incorrecto. Use KEY=VALUE (ej: -e MY_VAR=my_value)." >&2
            show_run_help
            return 1
          fi
        else
          echo "Error: Se requiere una variable de entorno para la opción -e/--env." >&2
          show_run_help
          return 1
        fi
        ;;
      -d|--detach)
        DETACHED_MODE=true
        shift
        ;;
      -v|--volume) 
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          if [[ "$2" =~ ^[^:]+:[^:]+$ ]]; then
            VOLUMES+=("$2")
            shift 2
          else
            echo "Error: Formato de volumen incorrecto. Use HOST_PATH:CONTAINER_PATH (ej: -v ~/data:/app/data)." >&2
            show_run_help
            return 1
          fi
        else
          echo "Error: Se requiere un volumen para la opción -v/--volume." >&2
          show_run_help
          return 1
        fi
        ;;
      -it) 
        INTERACTIVE_TTY=true
        shift
        ;;
      --interactive|--tty) 
        INTERACTIVE_TTY=true
        shift
        ;;
      --rm) 
        REMOVE_ON_EXIT=true
        shift
        ;;
      -h|--help)
        show_run_help
        return 0
        ;;
      *) 
        if [ -z "$IMAGE_TAG" ]; then
          IMAGE_TAG="$1"
          shift
        else 
          COMMAND_TO_RUN_CLI+=("$1") 
          shift 
        fi
        ;;
    esac
  done

  # Validaciones de opciones mutuamente excluyentes
  if $DETACHED_MODE && $INTERACTIVE_TTY; then
    echo "Error: Las opciones '-d' (--detach) y '-it' (--interactive --tty) son mutuamente excluyentes." >&2
    show_run_help
    return 1
  fi

  # Verifica que se haya proporcionado una imagen.
  if [ -z "$IMAGE_TAG" ]; then
    echo "Error: Se requiere el nombre de la imagen y la versión (ej: ubuntu:22.04.3 o alpine)." >&2
    show_run_help
    return 1
  fi

  # Parsea el tag de la imagen (ej: "ubuntu:22.04.3" -> distribucion="ubuntu", version="22.04.3").
  local parsed_distribution_name
  local parsed_image_version

  IFS=':' read -r parsed_distribution_name parsed_image_version <<< "$IMAGE_TAG"

  if [ -z "$parsed_distribution_name" ]; then
    echo "Error: Formato de imagen incorrecto. Use 'distribucion:version' o 'distribucion'." >&2
    show_run_help
    return 1
  fi

  parsed_distribution_name=$(echo "$parsed_distribution_name" | tr '[:upper:]' '[:lower:]')

  # Si la versión no se especifica (ej: "alpine"), se deja vacía para que 'download_image' la busque.
  if [ -z "$parsed_image_version" ]; then
      parsed_image_version="" 
  fi

  # Determinar el nombre del archivo de imagen comprimida (asume .tar.gz para imágenes oficiales).
  local local_compressed_image_filename="${parsed_distribution_name}-$(normalize_image_version "$parsed_image_version").tar.gz"
  local COMPRESSED_IMAGE_PATH="$DOWNLOAD_IMAGES_DIR/$local_compressed_image_filename"

  # --- Ruta al archivo de metadatos de la imagen ---
  local IMAGE_METADATA_FILE="$DOWNLOAD_IMAGES_DIR/${parsed_distribution_name}-$(normalize_image_version "$parsed_image_version").json"


  # --- Lógica de descarga automática si la imagen comprimida no existe localmente ---
  local IMAGE_ACTUAL_COMPRESSED_PATH # Variable para almacenar la ruta final de la imagen comprimida.

  # Si el archivo comprimido no existe o no se especificó la versión (solo para Alpine), intenta descargar.
  if [ ! -f "$COMPRESSED_IMAGE_PATH" ] || [ ! -f "$IMAGE_METADATA_FILE" ]; then
    echo "Imagen '${IMAGE_TAG}' no encontrada localmente o metadatos faltantes. Intentando descargar..."
    
    # download_image retorna 0 en éxito, 1 en fallo
    download_image "$parsed_distribution_name" "$parsed_image_version" "$(get_mapped_architecture)"
    if [ $? -ne 0 ]; then
      echo "Error: Falló la descarga de la imagen '${IMAGE_TAG}'. No se puede iniciar el contenedor." >&2
      return 1
    fi

    # Después de una descarga exitosa, la ruta ya está determinada por LOCAL_IMAGE_FILENAME_FINAL en pull.sh.
    # Necesitamos recrear aquí la ruta basada en lo que pull.sh debería haber hecho.
    IMAGE_ACTUAL_COMPRESSED_PATH="$DOWNLOAD_IMAGES_DIR/$local_compressed_image_filename"
    echo "Imagen comprimida localizada y ruta actualizada a: $IMAGE_ACTUAL_COMPRESSED_PATH"

  else
    IMAGE_ACTUAL_COMPRESSED_PATH="$DOWNLOAD_IMAGES_DIR/$local_compressed_image_filename"
  fi

  if [ ! -f "$IMAGE_ACTUAL_COMPRESSED_PATH" ]; then
      echo "Error crítico: La imagen comprimida '${IMAGE_TAG}' (${IMAGE_ACTUAL_COMPRESSED_PATH}) no existe después de la verificación/descarga." >&2
      return 1
  fi


  # 1. Preparar el directorio del contenedor y el rootfs
  if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME="${parsed_distribution_name}-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
  fi

  local CONTAINER_ROOTFS="$CONTAINERS_DIR/$CONTAINER_NAME/rootfs" # El directorio raíz del sistema de archivos del contenedor.
  local CONTAINER_DATA_DIR="$CONTAINERS_DIR/$CONTAINER_NAME"     # El directorio base para los datos de este contenedor.


  # --- LÓGICA DE CACHEO DE IMÁGENES DESCOMPRIMIDAS ---
  # Directorio para la imagen base descomprimida en cache (será un directorio).
  local IMAGE_CACHE_PATH="$CACHED_IMAGES_DIR/${parsed_distribution_name}-$(normalize_image_version "$parsed_image_version")"
  mkdir -p "$CACHED_IMAGES_DIR" # Asegurar que el directorio de cache exista.

  if [ -d "$CONTAINER_ROOTFS" ]; then
    echo "Advertencia: El contenedor '$CONTAINER_NAME' ya existe. Reutilizando el existente."
  else
    mkdir -p "$CONTAINER_DATA_DIR" || { echo "Error: No se pudo crear el directorio del contenedor."; return 1; }
    mkdir -p "$CONTAINER_ROOTFS" # Asegurarse que el destino existe.

    if [ -d "$IMAGE_CACHE_PATH" ] && [ -n "$(ls -A "$IMAGE_CACHE_PATH" 2>/dev/null)" ]; then
      cp -a "$IMAGE_CACHE_PATH/." "$CONTAINER_ROOTFS" || { echo "Error: Falló la copia desde el cache de imágenes."; rm -rf "$CONTAINER_DATA_DIR"; return 1; }
    else
      echo "Cache de imagen descomprimida no encontrada. Descomprimiendo '${IMAGE_TAG}' en '$CONTAINER_ROOTFS'..."
      
      /bin/tar -xf "$IMAGE_ACTUAL_COMPRESSED_PATH" -C "$CONTAINER_ROOTFS" --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' --no-same-owner || { echo "Error: Falló la descompresión de la imagen .tar.gz."; rm -rf "$CONTAINER_DATA_DIR"; return 1; }
      
      echo "Guardando imagen descomprimida en cache para futuros usos: '$IMAGE_CACHE_PATH'"
      cp -a "$CONTAINER_ROOTFS/." "$IMAGE_CACHE_PATH" || { echo "Advertencia: Falló el cacheo de la imagen descomprimida. No afectará la ejecución actual."; }
    fi
  fi
  # --- FIN DE PREPARACIÓN Y CACHEO DEL ROOTFS ---

  # --- NUEVO: Crear/Asegurar directorios especiales y permisos básicos ANTES de proot ---
  # Esto se ejecuta SIEMPRE, ya sea que el contenedor se creó o se reutilizó.
  mkdir -p "$CONTAINER_ROOTFS/dev" 2>/dev/null; chmod 755 "$CONTAINER_ROOTFS/dev"
  mkdir -p "$CONTAINER_ROOTFS/proc" 2>/dev/null; chmod 755 "$CONTAINER_ROOTFS/proc"
  mkdir -p "$CONTAINER_ROOTFS/sys" 2>/dev/null; chmod 755 "$CONTAINER_ROOTFS/sys"
  mkdir -p "$CONTAINER_ROOTFS/tmp" 2>/dev/null; chmod 1777 "$CONTAINER_ROOTFS/tmp"
  mkdir -p "$CONTAINER_ROOTFS/run" 2>/dev/null; chmod 755 "$CONTAINER_ROOTFS/run"

  mkdir -p "$CONTAINER_ROOTFS/etc" # Asegurar que /etc exista
  echo "nameserver 8.8.8.8" > "$CONTAINER_ROOTFS/etc/resolv.conf"
  echo "nameserver 8.8.4.4" >> "$CONTAINER_ROOTFS/etc/resolv.conf"

  # --- Determinar el COMANDO FINAL a ejecutar (CLI sobre escribe CMD de la imagen) ---
  local PROOT_EXEC_SHELL_PATH="" 
  local IMAGE_CMD_FROM_METADATA_JSON="null" # Valor por defecto (string JSON)
  local IMAGE_WORKDIR_FROM_METADATA="/root" # Valor por defecto seguro.
  local IMAGE_ENV_FROM_METADATA_JSON="null" # Valor por defecto (string JSON)
  if [ -f "$IMAGE_METADATA_FILE" ]; then
      IMAGE_CMD_FROM_METADATA_JSON=$(jq -c '.ContainerConfig.Cmd' "$IMAGE_METADATA_FILE" 2>/dev/null)
      local raw_workdir_from_json=$(jq -r '.ContainerConfig.WorkingDir' "$IMAGE_METADATA_FILE" 2>/dev/null)
      if [ "$raw_workdir_from_json" != "null" ] && [ -n "$raw_workdir_from_json" ]; then
          IMAGE_WORKDIR_FROM_METADATA="$raw_workdir_from_json"
      fi
      local raw_env_from_json=$(jq -c '.ContainerConfig.Env' "$IMAGE_METADATA_FILE" 2>/dev/null)
      if [ "$raw_env_from_json" != "null" ] && [ -n "$raw_env_from_json" ]; then
          IMAGE_ENV_FROM_METADATA_JSON="$raw_env_from_json"
      fi
  fi

  # Determinar FINAL_COMMAND_TO_EXECUTE (el comando real que proot ejecutará):
  local FINAL_COMMAND_TO_EXECUTE=() 
  if [ ${#COMMAND_TO_RUN_CLI[@]} -eq 0 ]; then # Si no hay comando CLI, usar el CMD de la imagen.
      if [ "$IMAGE_CMD_FROM_METADATA_JSON" != "null" ] && [ "$IMAGE_CMD_FROM_METADATA_JSON" != "[]" ]; then
          # Convertir el string JSON del CMD de la imagen a un array Bash.
          while IFS= read -r cmd_item; do
              FINAL_COMMAND_TO_EXECUTE+=("$cmd_item")
          done < <(echo "$IMAGE_CMD_FROM_METADATA_JSON" | jq -r '.[]')
          command_json_string="[\"${FINAL_COMMAND_TO_EXECUTE[@]}\"]" # Para metadatos, el comando final
      else
          if [ "$parsed_distribution_name" == "alpine" ]; then PROOT_EXEC_SHELL_PATH="/bin/sh"; fi
          if [ "$parsed_distribution_name" == "ubuntu" ]; then PROOT_EXEC_SHELL_PATH="/bin/bash"; fi
          if $INTERACTIVE_TTY; then
              FINAL_COMMAND_TO_EXECUTE=("$PROOT_EXEC_SHELL_PATH" "--login")
              command_json_string="[\"$PROOT_EXEC_SHELL_PATH\", \"--login\"]" 
          fi
      fi
  else
      # Si el usuario SÍ especificó un comando en la línea de 'run', ese tiene prioridad.
      FINAL_COMMAND_TO_EXECUTE=("${COMMAND_TO_RUN_CLI[@]}")
      command_json_string="[\"${FINAL_COMMAND_TO_EXECUTE[@]}\"]" 
  fi

  # Preparar env_vars_json_string
  local env_vars_json_string="[]" 
  if [ ${#ENVIRONMENT_VARS[@]} -gt 0 ]; then
      local temp_env_json="["
      local first_env=true
      for env_var in "${ENVIRONMENT_VARS[@]}"; do
          if [ "$first_env" = true ]; then first_env=false; else temp_env_json+="," ; fi
          temp_env_json+="\"$(echo "$env_var" | sed 's/"/\\"/g')\""
      done
      temp_env_json+="]"
      env_vars_json_string="$temp_env_json"
  fi

  # Construir FINAL_MOUNTS_JSON (Binds para metadatos)
  local METADATA_MOUNTS_ARRAY=()
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/dev", "Destination":"/dev", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/proc", "Destination":"/proc", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/sys", "Destination":"/sys", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/data/data/com.termux/files/usr/tmp", "Destination":"/tmp", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/data/data/com.termux", "Destination":"/data/data/com.termux", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/", "Destination":"/host-rootfs", "Mode":"ro" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/sdcard", "Destination":"/sdcard", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/storage", "Destination":"/storage", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"/mnt", "Destination":"/mnt", "Mode":"rw" }')
  METADATA_MOUNTS_ARRAY+=('{ "Source":"(generated by PRooBox)", "Destination":"/etc/resolv.conf", "Mode":"rw" }') 
  
  for vol_spec in "${VOLUMES[@]}"; do
      METADATA_MOUNTS_ARRAY+=('{ "Source":"'"$(echo "$vol_spec" | cut -d':' -f1)"'", "Destination":"'"$(echo "$vol_spec" | cut -d':' -f2)"'", "Mode":"rw" }')
  done

  if [ "$parsed_distribution_name" == "alpine" ]; then
      METADATA_MOUNTS_ARRAY+=('{ "Source":"'"$CONTAINER_ROOTFS/bin/busybox"'", "Destination":"/bin/sh", "Mode":"ro" }')
  fi

  local FINAL_MOUNTS_JSON=""
  local first_mount=true
  for mount_item in "${METADATA_MOUNTS_ARRAY[@]}"; do
    if [ "$first_mount" = true ]; then first_mount=false; else FINAL_MOUNTS_JSON+="," ; fi
    FINAL_MOUNTS_JSON+="$mount_item"
  done
  FINAL_MOUNTS_JSON="[${FINAL_MOUNTS_JSON}]"

  # Llamada a generate_container_metadata 
  generate_container_metadata \
    "$CONTAINER_NAME" \
    "$IMAGE_TAG" \
    "$parsed_distribution_name" \
    "$parsed_image_version" \
    "$IMAGE_ACTUAL_COMPRESSED_PATH" \
    "$CONTAINER_ROOTFS" \
    "$(if $DETACHED_MODE; then echo "true"; else echo "false"; fi)" \
    "$(if $REMOVE_ON_EXIT; then echo "true"; else echo "false"; fi)" \
    "$command_json_string" \
    "$env_vars_json_string" \
    "$FINAL_MOUNTS_JSON" \
    "$(if $INTERACTIVE_TTY; then echo "true"; else echo "false"; fi)"
  if [ $? -ne 0 ]; then
      echo "Error: Falló la generación de metadatos para el contenedor '$CONTAINER_NAME'." >&2
      return 1
  fi

  # --- Construir el comando proot ---
  unset LD_PRELOAD # ¡Crucial para evitar conflictos con termux-exec!

  local PROOT_COMMAND_ARRAY=(
    proot
    --link2symlink
    -0 
    -r "$CONTAINER_ROOTFS" 
    
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
  
  # Añadir bind-mounts personalizados (-v)
  for vol_spec in "${VOLUMES[@]}"; do
      PROOT_COMMAND_ARRAY+=("-b" "$vol_spec")
  done

  # Argumentos específicos de proot por distribución.
  if [ "$parsed_distribution_name" == "alpine" ]; then
      PROOT_COMMAND_ARRAY+=("-b" "$CONTAINER_ROOTFS/bin/busybox:/bin/sh")
      PROOT_COMMAND_ARRAY+=("-b" "$CONTAINER_ROOTFS/bin/busybox:/usr/bin/env")
  fi

  # Establecer el WORKDIR
  PROOT_COMMAND_ARRAY+=("-w" "$IMAGE_WORKDIR_FROM_METADATA") 
  
  PROOT_COMMAND_ARRAY+=(
    --kill-on-exit 
    /usr/bin/env 
    -i           
    "HOME=/root"
    "PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games"
    "TERM=$TERM" 
    "LANG=C.UTF-8"
  )
  for env_var in $(echo "$IMAGE_ENV_FROM_METADATA_JSON" | jq -r '.[]'); do
      PROOT_COMMAND_ARRAY+=("$env_var")
  done

  # Añadir variables de entorno personalizadas (acumuladas)
  for env_var in "${ENVIRONMENT_VARS[@]}"; do
      PROOT_COMMAND_ARRAY+=("$env_var")
  done
  
  # Añadir el comando final a ejecutar
  PROOT_COMMAND_ARRAY+=("${FINAL_COMMAND_TO_EXECUTE[@]}")

  # --- Ejecutar el contenedor ---
  local LOG_FILE="$CONTAINER_DATA_DIR/container.log"

  if $DETACHED_MODE; then
    echo "Ejecutando en modo detached (segundo plano)."
    # Capturar PID después de lanzar.
    ( "${PROOT_COMMAND_ARRAY[@]}" > "$LOG_FILE" 2>&1 & )
    local PIDS_TEMP=$(pgrep -f "proot.*-r ${CONTAINER_ROOTFS//\//\\/}" | head -n 1) # Obtener PID de proot
    echo "Contenedor '$CONTAINER_NAME' iniciado en segundo plano. PID: ${PIDS_TEMP:-?}"
    echo "Para ver la salida, revisa: $LOG_FILE"
    update_container_state_metadata "$CONTAINER_NAME" "running" "true" "null"
  else # Interactive or attached mode
    "${PROOT_COMMAND_ARRAY[@]}"
    local EXIT_CODE=$? 
    update_container_state_metadata "$CONTAINER_NAME" "exited" "false" "$EXIT_CODE"
  fi

  # --- Lógica de eliminación automática (--rm) ---
  # if $REMOVE_ON_EXIT; then
  #   echo "Opción --rm detectada. Eliminando contenedor '$CONTAINER_NAME'..."
  #   local RM_SCRIPT="$SCRIPT_DIR/rm.sh"
  #   if [ -f "$RM_SCRIPT" ]; then
  #       "$RM_SCRIPT" -f "$CONTAINER_NAME"
  #   else
  #       echo "Advertencia: Script 'rm.sh' no encontrado. No se puede eliminar el contenedor '$CONTAINER_NAME' automáticamente." >&2
  #   fi
  # fi

  return 0
}
main_run_logic "$@" # Llama a la función principal con todos los argumentos pasados al script.