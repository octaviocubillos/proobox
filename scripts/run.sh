#!/data/data/com.termux/files/usr/bin/bash

# Este script es el corazón de la ejecución de contenedores.
# Incluye el manejo de opciones como nombres, variables de entorno, volúmenes y modos interactivos/detached.

# --- Cargar pull.sh y metadata.sh para acceder a sus funciones y variables compartidas ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PULL_SCRIPT="$SCRIPT_DIR/pull.sh"
METADATA_SCRIPT="$SCRIPT_DIR/metadata.sh" 

if [ -f "$PULL_SCRIPT" ]; then
  . "$PULL_SCRIPT" # Esto carga pull.sh, haciendo que sus funciones y vars estén disponibles.
else
  echo "Error: No se encontró el script de pull '$PULL_SCRIPT'. La funcionalidad de ejecución podría estar limitada."
  exit 1
fi

if [ -f "$METADATA_SCRIPT" ]; then
  . "$METADATA_SCRIPT" # Esto carga metadata.sh.
  if ! command_exists generate_container_metadata; then
      echo "Error: Las funciones de metadatos no se cargaron correctamente desde '$METADATA_SCRIPT'."
      echo "Asegúrate de que 'metadata.sh' sea un script de Bash válido y tenga permisos."
      exit 1 
  fi
else
  echo "Error: No se encontró el script de metadatos '$METADATA_SCRIPT'. Los metadatos no se generarán/actualizarán."
  exit 1 
fi

# Directorio para las instancias de contenedores
CONTAINERS_DIR="$HOME/.termux-container/containers" 
CACHED_IMAGES_DIR="$HOME/.termux-container/cached_images" 


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
    echo "  -e, --env <KEY=VALUE>      Establece una variable de entorno dentro del contenedor (ej: -e VAR=VAL)."
    echo "  -d, --detach               Ejecuta el contenedor en segundo plano (detached)."
    echo "  -v, --volume <HOST:CONT>   Monta un volumen del host en el contenedor (ej: -v ~/data:/app/data)."
    echo "  -it, --interactive --tty   Ejecuta el contenedor en modo interactivo con una terminal."
    echo "  --rm                       Elimina el contenedor automáticamente al finalizar la ejecución."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container run ubuntu:22.04.3 /bin/bash"
    echo "  ./termux-container run --name my_app -e APP_ENV=production ubuntu:22.04.3 apt update"
    echo "  ./termux-container run alpine      # Descarga y ejecuta la última versión de Alpine con su shell por defecto"
    echo "  ./termux-container run -d -n mydetached ubuntu:22.04.3 sleep 30"
  }

  # Parseo de opciones de línea de comandos. Consume las opciones y deja los argumentos posicionales.
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -n|--name)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          CONTAINER_NAME="$2"
          shift 2
        else
          echo "Error: Se requiere un nombre para la opción -n/--name."
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
            echo "Error: Formato de variable de entorno incorrecto. Use KEY=VALUE (ej: -e MY_VAR=my_value)."
            show_run_help
            return 1
          fi
        else
          echo "Error: Se requiere una variable de entorno para la opción -e/--env."
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
            echo "Error: Formato de volumen incorrecto. Use HOST_PATH:CONTAINER_PATH (ej: -v ~/data:/app/data)."
            show_run_help
            return 1
          fi
        else
          echo "Error: Se requiere un volumen para la opción -v/--volume."
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
    echo "Error: Las opciones '-d' (--detach) y '-it' (--interactive --tty) son mutuamente excluyentes."
    show_run_help
    return 1
  fi

  # Verifica que se haya proporcionado una imagen.
  if [ -z "$IMAGE_TAG" ]; then
    echo "Error: Se requiere el nombre de la imagen y la versión (ej: ubuntu:22.04.3 o alpine)."
    show_run_help
    return 1
  fi

  # Parsea el tag de la imagen (ej: "ubuntu:22.04.3" -> distribucion="ubuntu", version="22.04.3").
  local parsed_distribution_name
  local parsed_image_version

  IFS=':' read -r parsed_distribution_name parsed_image_version <<< "$IMAGE_TAG"

  if [ -z "$parsed_distribution_name" ]; then
    echo "Error: Formato de imagen incorrecto. Use 'distribucion:version' o 'distribucion'."
    show_run_help
    return 1
  fi

  parsed_distribution_name=$(echo "$parsed_distribution_name" | tr '[:upper:]' '[:lower:]')

  # Si la versión no se especifica (ej: "alpine"), se deja vacía para que 'download_image' la busque.
  if [ -z "$parsed_image_version" ]; then
      parsed_image_version="" 
  fi

  # Determinar el nombre del archivo de imagen comprimida (asume .tar.gz para imágenes oficiales).
  local local_compressed_image_filename="${parsed_distribution_name}-${parsed_image_version}.tar.gz"
  local COMPRESSED_IMAGE_PATH="$DOWNLOAD_IMAGES_DIR/$local_compressed_image_filename"

  # --- Ruta al archivo de metadatos de la imagen ---
  local IMAGE_METADATA_FILE="$DOWNLOAD_IMAGES_DIR/${parsed_distribution_name}-${parsed_image_version}.json"


  # --- Lógica de descarga automática si la imagen comprimida no existe localmente ---
  local IMAGE_ACTUAL_COMPRESSED_PATH # Variable para almacenar la ruta final de la imagen comprimida.

  # Si el archivo comprimido no existe o no se especificó la versión (solo para Alpine), intenta descargar.
  if [ ! -f "$COMPRESSED_IMAGE_PATH" ] || ([ -z "$parsed_image_version" ] && [ "$parsed_distribution_name" == "alpine" ]); then
    echo "Imagen '${IMAGE_TAG}' no encontrada localmente o versión no especificada. Intentando descargar..."
    
    if ! download_image "$parsed_distribution_name" "$parsed_image_version" "$(get_mapped_architecture)"; then 
      echo "Error: Falló la descarga de la imagen '${IMAGE_TAG}'. No se puede iniciar el contenedor."
      return 1
    fi

    # Después de una descarga exitosa, la ruta ya está determinada por LOCAL_IMAGE_FILENAME_FINAL.
    IMAGE_ACTUAL_COMPRESSED_PATH="$DOWNLOAD_IMAGES_DIR/$local_compressed_image_filename"
    echo "Imagen comprimida localizada y ruta actualizada a: $IMAGE_ACTUAL_COMPRESSED_PATH"

  else
    IMAGE_ACTUAL_COMPRESSED_PATH="$DOWNLOAD_IMAGES_DIR/$local_compressed_image_filename"
    echo "Imagen comprimida '${IMAGE_TAG}' encontrada localmente en: $IMAGE_ACTUAL_COMPRESSED_PATH"
  fi

  if [ ! -f "$IMAGE_ACTUAL_COMPRESSED_PATH" ]; then
      echo "Error crítico: La imagen comprimida '${IMAGE_TAG}' (${IMAGE_ACTUAL_COMPRESSED_PATH}) no existe después de la verificación/descarga."
      return 1
  fi


  # 1. Preparar el directorio del contenedor y el rootfs
  if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME="${parsed_distribution_name}-$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
    echo "Generando nombre de contenedor: $CONTAINER_NAME"
  fi

  local CONTAINER_ROOTFS="$CONTAINERS_DIR/$CONTAINER_NAME/rootfs" # El directorio raíz del sistema de archivos del contenedor.
  local CONTAINER_DATA_DIR="$CONTAINERS_DIR/$CONTAINER_NAME"     # El directorio base para los datos de este contenedor.


  # --- LÓGICA DE CACHEO DE IMÁGENES DESCOMPRIMIDAS MEJORADA ---
  # Directorio para la imagen base descomprimida en cache.
  local IMAGE_CACHE_PATH="$CACHED_IMAGES_DIR/${parsed_distribution_name}-${parsed_image_version}"
  mkdir -p "$CACHED_IMAGES_DIR" # Asegurar que el directorio de cache exista.

  # Si el rootfs del contenedor NO existe, entonces procedemos a crearlo (desde cache o descomprimiendo).
  if [ ! -d "$CONTAINER_ROOTFS" ]; then
    echo "Creando directorio para el contenedor: $CONTAINER_DATA_DIR"
    mkdir -p "$CONTAINER_DATA_DIR" || { echo "Error: No se pudo crear el directorio del contenedor."; return 1; }

    if [ -d "$IMAGE_CACHE_PATH" ] && [ -n "$(ls -A "$IMAGE_CACHE_PATH" 2>/dev/null)" ]; then
      echo "Usando imagen cacheadada para '${IMAGE_TAG}' desde '$IMAGE_CACHE_PATH'..."
      # Copia los archivos del cache al rootfs del nuevo contenedor.
      cp -a "$IMAGE_CACHE_PATH/." "$CONTAINER_ROOTFS" || { echo "Error: Falló la copia desde el cache de imágenes."; rm -rf "$CONTAINER_DATA_DIR"; return 1; }
    else
      echo "Cache de imagen descomprimida no encontrada. Descomprimiendo '${IMAGE_TAG}' en '$CONTAINER_ROOTFS'..."
      mkdir -p "$CONTAINER_ROOTFS" || { echo "Error: No se pudo crear el directorio rootfs del contenedor."; return 1; }
      
      tar -xf "$IMAGE_ACTUAL_COMPRESSED_PATH" -C "$CONTAINER_ROOTFS" --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' --no-same-owner || { echo "Error: Falló la descompresión de la imagen .tar.gz."; rm -rf "$CONTAINER_DATA_DIR"; return 1; }
      
      echo "Guardando imagen descomprimida en cache para futuros usos: '$IMAGE_CACHE_PATH'"
      cp -a "$CONTAINER_ROOTFS/." "$IMAGE_CACHE_PATH" || { echo "Advertencia: Falló el cacheo de la imagen descomprimida. No afectará la ejecución actual."; }
    fi
    
    # Crea los directorios especiales que proot necesita
    mkdir -p "$CONTAINER_ROOTFS/dev"
    mkdir -p "$CONTAINER_ROOTFS/proc"
    mkdir -p "$CONTAINER_ROOTFS/sys"
    mkdir -p "$CONTAINER_ROOTFS/tmp"
    mkdir -p "$CONTAINER_ROOTFS/run" 
    chmod 1777 "$CONTAINER_ROOTFS/tmp" 

    # --- Configurar DNS (Creación de archivo en lugar de bind-mount) ---
    echo "nameserver 8.8.8.8" > "$CONTAINER_ROOTFS/etc/resolv.conf"
    echo "nameserver 8.8.4.4" >> "$CONTAINER_ROOTFS/etc/resolv.conf"
    echo "DNS configurado con servidores de Google."
    # --- Fin de configuración de DNS ---

    echo "Entorno básico configurado."
  else
    echo "Advertencia: El contenedor '$CONTAINER_NAME' ya existe. Reutilizando el existente."
  fi
  # --- FIN DE PREPARACIÓN Y CACHEO DEL ROOTFS ---


  # --- Generar/Actualizar Metadatos del Contenedor (AHORA SIEMPRE SE EJECUTA AQUÍ) ---
  # Preparar los argumentos para generate_container_metadata
  local command_json_string="null" 
  local env_vars_json_string="[]"
  local FINAL_MOUNTS_JSON="[]" # Inicializar para evitar errores si no hay montajes.

  # 1. Preparar command_json_string (usando COMMAND_TO_RUN_CLI o el CMD de la imagen)
  local PROOT_EXEC_SHELL_PATH="" # Ruta al shell dentro del contenedor (/bin/sh o /bin/bash)
  local IMAGE_CMD_FROM_METADATA_JSON="null" # Valor por defecto (string JSON)
  local IMAGE_WORKDIR_FROM_METADATA="/root" # Valor por defecto para WORKDIR de la imagen

  # Leer CMD y WorkDir de los metadatos de la imagen si existen.
  if [ -f "$IMAGE_METADATA_FILE" ]; then
      IMAGE_CMD_FROM_METADATA_JSON=$(jq -c '.ContainerConfig.Cmd' "$IMAGE_METADATA_FILE" 2>/dev/null)
      local temp_workdir=$(jq -r '.ContainerConfig.WorkingDir' "$IMAGE_METADATA_FILE" 2>/dev/null)
      if [ "$temp_workdir" != "null" ] && [ -n "$temp_workdir" ]; then
          IMAGE_WORKDIR_FROM_METADATA="$temp_workdir"
      fi
  fi

  # Determinar FINAL_COMMAND_TO_EXECUTE (el comando real que proot ejecutará):
  local FINAL_COMMAND_TO_EXECUTE=() 
  if [ ${#COMMAND_TO_RUN_CLI[@]} -eq 0 ]; then # Si no hay comando CLI, usar el CMD de la imagen.
      if [ "$IMAGE_CMD_FROM_METADATA_JSON" != "null" ] && [ "$IMAGE_CMD_FROM_METADATA_JSON" != "[]" ]; then
          echo "No se especificó comando en 'run'. Usando CMD de la imagen: '$IMAGE_CMD_FROM_METADATA_JSON'"
          # Convertir el string JSON del CMD de la imagen a un array Bash.
          while IFS= read -r cmd_item; do
              FINAL_COMMAND_TO_EXECUTE+=("$cmd_item")
          done < <(echo "$IMAGE_CMD_FROM_METADATA_JSON" | jq -r '.[]')
          command_json_string="$IMAGE_CMD_FROM_METADATA_JSON" # Para metadatos, usar el JSON original del CMD.
      else
          echo "No se especificó comando en 'run' y la imagen no tiene CMD. Usando shell por defecto."
          # Si no hay CMD ni comando CLI, usar el shell por defecto para ejecución y metadatos.
          if [ "$parsed_distribution_name" == "alpine" ]; then PROOT_EXEC_SHELL_PATH="/bin/sh"; fi
          if [ "$parsed_distribution_name" == "ubuntu" ]; then PROOT_EXEC_SHELL_PATH="/bin/bash"; fi
          if $INTERACTIVE_TTY; then
              FINAL_COMMAND_TO_EXECUTE=("$PROOT_EXEC_SHELL_PATH" "--login")
              command_json_string="[\"$PROOT_EXEC_SHELL_PATH\", \"--login\"]" # Para metadatos
          else
              FINAL_COMMAND_TO_EXECUTE=("$PROOT_EXEC_SHELL_PATH") 
              command_json_string="[\"$PROOT_EXEC_SHELL_PATH\"]" # Para metadatos
          fi
      fi
  else
      # Si el usuario SÍ especificó un comando en la línea de 'run', ese tiene prioridad.
      FINAL_COMMAND_TO_EXECUTE=("${COMMAND_TO_RUN_CLI[@]}")
      # Para metadatos, convertimos COMMAND_TO_RUN_CLI a JSON string.
      local temp_cmd_json_cli="[\""
      local first_cmd_cli=true
      for cmd_arg_cli in "${COMMAND_TO_RUN_CLI[@]}"; do
          if [ "$first_cmd_cli" = true ]; then first_cmd_cli=false; else temp_cmd_json_cli+="\",\""; fi
          temp_cmd_json_cli+=$(echo "$cmd_arg_cli" | sed 's/"/\\"/g')
      done
      temp_cmd_json_cli+="\"]"
      command_json_string="$temp_cmd_json_cli"
  fi

  # 2. Preparar env_vars_json_string (no cambió)
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

  # 3. Construir FINAL_MOUNTS_JSON (no cambió)
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
  METADATA_MOUNTS_ARRAY+=('{ "Source":"(generated by Termux container)", "Destination":"/etc/resolv.conf", "Mode":"rw" }') 
  
  # Añadir bind-mounts personalizados del usuario (-v)
  for vol_spec in "${VOLUMES[@]}"; do
      local host_path=$(echo "$vol_spec" | cut -d':' -f1)
      local container_path=$(echo "$vol_spec" | cut -d':' -f2)
      METADATA_MOUNTS_ARRAY+=('{ "Source":"'"$host_path"'", "Destination":"'"$container_path"'", "Mode":"rw" }')
  done

  # Añadir el bind-mount de busybox si es Alpine
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

  # Llamada a generate_container_metadata (AHORA SIEMPRE SE HACE AQUÍ)
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
    "$(if $INTERACTIVE_TTY; then echo "true"; else echo "false"; fi)" # NUEVO: Pasar InteractiveOriginal
  # --- FIN DE GENERACIÓN DE METADATOS ---

  # 3. Construir el comando proot como un array
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
  
  # Añadir bind-mounts personalizados del usuario (opción -v)
  for vol_spec in "${VOLUMES[@]}"; do
      PROOT_COMMAND_ARRAY+=("-b" "$vol_spec")
  done

  # Argumentos específicos de proot por distribución.
  if [ "$parsed_distribution_name" == "alpine" ]; then
      # Workaround para Alpine (musl libc) con versiones limitadas de proot.
      PROOT_COMMAND_ARRAY+=("-b" "$CONTAINER_ROOTFS/bin/busybox:/bin/sh")
  elif [ "$parsed_distribution_name" == "ubuntu" ]; then
      PROOT_COMMAND_ARRAY+=() # No specific proot args for Ubuntu here.
  fi

  # Establecer el WORKDIR del contenedor (del Buildfile o por defecto)
  PROOT_COMMAND_ARRAY+=("-w" "$IMAGE_WORKDIR_FROM_METADATA") 

  PROOT_COMMAND_ARRAY+=(
    --kill-on-exit 
    /usr/bin/env 
    -i           
  )
  
  # Environment variables for /usr/bin/env -i
  PROOT_COMMAND_ARRAY+=(
    "HOME=/root"
    "PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games"
    "TERM=$TERM" 
    "LANG=C.UTF-8"
  )
  
  # Add custom environment variables from the user (-e)
  for env_var in "${ENVIRONMENT_VARS[@]}"; do
      PROOT_COMMAND_ARRAY+=("$env_var")
  done
  
  # Add the final command to execute and its arguments
  PROOT_COMMAND_ARRAY+=("${FINAL_COMMAND_TO_EXECUTE[@]}")

  # 4. Execute the container with proot
  echo "Starting container '$CONTAINER_NAME'..."

  # Determine how to execute the full command based on detached mode.
  if $DETACHED_MODE; then
    echo "Ejecutando en modo detached (segundo plano)."
    ( "${PROOT_COMMAND_ARRAY[@]}" > "$CONTAINER_DATA_DIR/container.log" 2>&1 & )
    local CONTAINER_PID=$!
    echo "Contenedor '$CONTAINER_NAME' iniciado en segundo plano. PID: $CONTAINER_PID"
    echo "Para ver la salida, revisa: $CONTAINER_DATA_DIR/container.log"
    if command_exists update_container_state_metadata; then
        update_container_state_metadata "$CONTAINER_NAME" "running" "true" "null" 
    fi
  else
    echo "Entrando al contenedor '$CONTAINER_NAME'..."
    "${PROOT_COMMAND_ARRAY[@]}"
    local EXIT_CODE=$? 
    echo "Contenedor '$CONTAINER_NAME' terminado. Código de salida: $EXIT_CODE"
    if command_exists update_container_state_metadata; then
        update_container_state_metadata "$CONTAINER_NAME" "exited" "false" "$EXIT_CODE"
    fi
  fi

  # --- Lógica de eliminación automática (--rm) ---
  if $REMOVE_ON_EXIT; then
    echo "Opción --rm detectada. Eliminando contenedor '$CONTAINER_NAME'..."
    local RM_SCRIPT="$SCRIPT_DIR/rm.sh"
    if [ -f "$RM_SCRIPT" ]; then
        "$RM_SCRIPT" -f "$CONTAINER_NAME"
    else
        echo "Advertencia: Script 'rm.sh' no encontrado. No se puede eliminar el contenedor '$CONTAINER_NAME' automáticamente."
    fi
  fi
}

# Call the main function with all arguments passed to the script.
main_run_logic "$@"