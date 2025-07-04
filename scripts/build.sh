#!/data/data/com.termux/files/usr/bin/bash

# Este script permite crear imágenes personalizadas a partir de un archivo de configuración (Buildfile).
# Ahora incluye cacheo de capas para acelerar las construcciones.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PULL_SCRIPT="$SCRIPT_DIR/pull.sh"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh" # Aseguramos que utils.sh esté disponible

# Cargar utils.sh para funciones como command_exists
if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. La funcionalidad de compilación podría ser limitada." >&2
  exit 1
fi

# Cargar pull.sh (para download_image, get_mapped_architecture)
if [ -f "$PULL_SCRIPT" ]; then
  . "$PULL_SCRIPT" 
else
  echo "Error: No se encontró el script de pull '$PULL_SCRIPT'. La funcionalidad de compilación podría ser limitada."
  exit 1
fi

# Directorios
DOWNLOAD_IMAGES_DIR="$HOME/.proobox/images" 
CONTAINERS_DIR="$HOME/.proobox/containers" 
CACHED_IMAGES_DIR="$HOME/.proobox/cached_images" # Directorio para cache de capas de build

# --- Funciones de Utilidad (locales a build.sh) ---
# get_dir_hash y get_container_size_from_tar se mantienen aquí.

# Función para calcular un hash SHA256 del contenido de un directorio.
get_dir_hash() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        echo "0" # Hash para directorio vacío o inexistente
        return
    fi 
    find "$dir_path" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}' | head -c 12
}

# Obtiene el tamaño de un archivo tar.gz
get_container_size_from_tar() {
    local tar_path="$1"
    if [ -f "$tar_path" ]; then
        du -h "$tar_path" | awk '{print $1}'
    else
        echo "0B"
    fi
}

# Obtiene la hora actual formateada como HH:MM:SS
get_current_time() {
    date +"%H:%M:%S"
}

# Calcula el tiempo transcurrido en segundos y lo formatea.
format_elapsed_time() {
    local start_time=$1
    local end_time=$2
    local elapsed=$((end_time - start_time))
    if [ "$elapsed" -lt 1 ]; then
        printf "%.1fs" "0.0" # Menos de 1 segundo, mostrar como 0.0s
    else
        echo "${elapsed}s"
    fi
}

# --- Lógica Principal del Script build.sh ---
main_build_logic() {
  local BUILD_FILE_PATH="Buildfile" # Por defecto
  local IMAGE_TAG_NAME="" # Nombre de la nueva imagen (ej. my_app:v1)
  local NO_CACHE=false # Opcional: --no-cache

  local BUILD_START_TIME=$(date +%s) # Inicia el cronómetro total de la compilación

  show_build_help() {
    echo "Uso: build.sh [opciones] <ruta_contexto>"
    echo ""
    echo "Construye una imagen de contenedor desde un Buildfile y un contexto."
    echo "El contexto es el directorio donde se encuentran el Buildfile y los archivos a copiar."
    echo ""
    echo "Opciones:"
    echo "  -f, --file <ruta>          Especifica la ruta al Buildfile (por defecto: ./Buildfile)."
    echo "  -t, --tag <nombre>[:<etiqueta>] Asigna un nombre y etiqueta a la nueva imagen (ej: my_app:v1)."
    echo "  --no-cache                 Deshabilita el uso de cache durante la construcción."
    echo ""
    echo "Ejemplos:"
    echo "  proobox build ."
    echo "  proobox build -t my_custom_ubuntu:latest /path/to/my/app/code"
    echo "  proobox build -f MyCustomBuildfile -t my_app:test ."
  }

  # Parseo de opciones
  local POSITIONAL_ARGS=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -f|--file)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          BUILD_FILE_PATH="$2"
          shift 2
        else
          echo "Error: Se requiere una ruta para la opción -f/--file."
          show_build_help
          return 1
        fi
        ;;
      -t|--tag)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then
          IMAGE_TAG_NAME="$2"
          shift 2
        else
          echo "Error: Se requiere un nombre/etiqueta para la opción -t/--tag."
          show_build_help
          return 1
        fi
        ;;
      --no-cache)
        NO_CACHE=true
        shift
        ;;
      -h|--help)
        show_build_help
        return 0
        ;;
      *)
        POSITIONAL_ARGS+=("$1") # Recoge argumentos posicionales
        shift
        ;;
    esac
  done

  # El argumento posicional restante debe ser el directorio de contexto.
  local BUILD_CONTEXT_PATH=""
  if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
    BUILD_CONTEXT_PATH="${POSITIONAL_ARGS[0]}"
  fi

  if [ -z "$BUILD_CONTEXT_PATH" ]; then
    echo "Error: Se requiere un directorio de contexto de construcción (ej: '.')."
    show_build_help
    return 1
  fi

  # Resolver rutas absolutas
  BUILD_CONTEXT_PATH=$(realpath "$BUILD_CONTEXT_PATH" 2>/dev/null)
  if [ ! -d "$BUILD_CONTEXT_PATH" ]; then
    echo "Error: El directorio de contexto '$BUILD_CONTEXT_PATH' no existe."
    return 1
  fi

  BUILD_FILE_PATH=$(realpath -m "$BUILD_CONTEXT_PATH/$BUILD_FILE_PATH" 2>/dev/null) # Asegura ruta absoluta del buildfile
  if [ ! -f "$BUILD_FILE_PATH" ]; then
    echo "Error: El Buildfile '$BUILD_FILE_PATH' no existe o no es un archivo."
    return 1
  fi

  if [ -z "$IMAGE_TAG_NAME" ]; then
    echo "Error: Se requiere la opción -t/--tag para nombrar la nueva imagen."
    return 1
  fi

  # --- Fase 1: Carga y Conteo de Pasos ---
  # Leer Buildfile completo y pre-procesar líneas con '\'
  local buildfile_content_temp=$(cat "$BUILD_FILE_PATH") 
  local PROCESSED_BUILDFILE_LINES=()
  local current_logical_line=""
  local is_continuing_line=false
  local TOTAL_BUILD_STEPS=0 # Contará solo RUN, COPY, WORKDIR, CMD, ENV

  while IFS= read -r raw_line; do
    local trimmed_line=$(echo "$raw_line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') 
    
    if [ "$is_continuing_line" = true ]; then
        current_logical_line+=" $trimmed_line"
    else
        current_logical_line="$trimmed_line"
    fi

    if [[ "$current_logical_line" =~ \\$ ]]; then
        current_logical_line=$(echo "$current_logical_line" | sed 's/\\$//')
        is_continuing_line=true
        continue 
    else
        if [[ -n "$current_logical_line" ]] && ! [[ "$current_logical_line" =~ ^# ]]; then
            local cmd_type=$(echo "$current_logical_line" | awk '{print $1}')
            if [ "$cmd_type" != "FROM" ]; then # FROM no es un paso "contable" en la numeración de Docker.
                PROCESSED_BUILDFILE_LINES+=("$current_logical_line")
                TOTAL_BUILD_STEPS=$((TOTAL_BUILD_STEPS + 1))
            else
                # Almacenar la línea FROM por separado para usarla en el paso 1.
                local FROM_LINE="$current_logical_line"
            fi
        fi
        current_logical_line=""
        is_continuing_line=false
    fi
  done < <(echo "$buildfile_content_temp")

  if [ "$is_continuing_line" = true ]; then
      echo "Error de sintaxis en Buildfile: El archivo termina con '\\' sin un comando de continuación." >&2
      rm -rf "$BUILD_DATA_DIR"
      return 1
  fi
  # --- Fin de pre-procesamiento y conteo ---


  echo -e "\nCompilando '${IMAGE_TAG_NAME}' $(get_current_time)"
  # No mostramos [+] Building (X/Y) FINISHED aquí, sino al final.
  # Mostramos los pasos internos iniciales de Docker.
  local DOCKER_BUILD_INTERNAL_START_TIME=$(date +%s)
  echo -n "$(get_current_time) => [internal] load build definition from Buildfile "
  echo " (0.0s)" # Siempre 0s para esto en Docker
  echo -n "$(get_current_time) => => transferring dockerfile: $(stat -c %s "$BUILD_FILE_PATH")B "
  echo " (0.0s)"

  # Cargar metadatos para la imagen base (FROM)
  local BASE_IMAGE_TAG=$(echo "$FROM_LINE" | awk '{print $2}')
  local base_dist_name=$(echo "$BASE_IMAGE_TAG" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  local base_image_version=$(echo "$BASE_IMAGE_TAG" | cut -d':' -f2)
  local base_image_tar_path="${DOWNLOAD_IMAGES_DIR}/${base_dist_name}-${base_image_version}.tar.gz"

  local START_METADATA_LOAD=$(date +%s)
  echo -n "$(get_current_time) => [internal] load metadata for ${BASE_IMAGE_TAG} "
  # Simular la descarga/carga de la capa FROM
  if [ ! -f "$base_image_tar_path" ]; then
    if ! download_image "$base_dist_name" "$base_image_version" "$(get_mapped_architecture)"; then
      echo "Error: Falló la descarga de la imagen base '$BASE_IMAGE_TAG'."
      return 1
    fi
  fi
  local END_METADATA_LOAD=$(date +%s)
  ELAPSED_TIME=$((END_METADATA_LOAD - START_METADATA_LOAD))
  echo " ($(format_elapsed_time $START_METADATA_LOAD $END_METADATA_LOAD))" # Tiempo para el paso metadata

  echo -n "$(get_current_time) => [internal] load .dockerignore "
  echo " (0.0s)" # Simula carga .dockerignore
  echo -n "$(get_current_time) => => transferring context: $(du -b "$BUILD_CONTEXT_PATH" | awk '{print $1}')B "
  echo " (0.0s)" # Simula transferencia de contexto

  # 3. Crear un contenedor temporal para la construcción.
  local BUILD_CONTAINER_NAME="build-temp-$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)" 
  local BUILD_ROOTFS="$CONTAINERS_DIR/$BUILD_CONTAINER_NAME/rootfs"
  local BUILD_DATA_DIR="$CONTAINERS_DIR/$BUILD_CONTAINER_NAME"

  mkdir -p "$BUILD_DATA_DIR" || { echo "Error: No se pudo crear el directorio del contenedor temporal."; return 1; }
  mkdir -p "$BUILD_ROOTFS" || { echo "Error: No se pudo crear el rootfs del contenedor temporal."; return 1; }

  # --- Lógica de Cacheo para la capa FROM ---
  local BASE_IMAGE_FULL_HASH=$(echo "$BASE_IMAGE_TAG" | sha256sum | awk '{print $1}')
  local BASE_IMAGE_SHORT_HASH=$(echo "$BASE_IMAGE_FULL_HASH" | head -c 12)
  local CACHE_FROM_PATH="$CACHED_IMAGES_DIR/layer-$BASE_IMAGE_SHORT_HASH"
  mkdir -p "$CACHED_IMAGES_DIR" 

  START_TIME_STEP=$(date +%s)
  local IS_FROM_CACHED=false
  local STEP_STATUS="RUNNING"
  if [ -d "$CACHE_FROM_PATH" ] && [ "$NO_CACHE" = false ] && [ -n "$(ls -A "$CACHE_FROM_PATH" 2>/dev/null)" ]; then
    echo -n "$(get_current_time) => CACHED [1/${TOTAL_BUILD_STEPS}] FROM ${BASE_IMAGE_TAG} "
    cp -a "$CACHE_FROM_PATH/." "$BUILD_ROOTFS" || { echo "Error: Falló la copia de la capa FROM cacheada."; rm -rf "$BUILD_DATA_DIR"; return 1; }
    IS_FROM_CACHED=true
    STEP_STATUS="CACHED"
  else
    echo -e "$(get_current_time) => [1/${TOTAL_BUILD_STEPS}] FROM ${BASE_IMAGE_TAG} "
    
    tar -xf "$base_image_tar_path" -C "$BUILD_ROOTFS" --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' --no-same-owner >/dev/null 2>&1

    if [ "$(ls -AF "$BUILD_ROOTFS" | wc -l)" -le 0 ]; then
      echo "?????"
      echo "Error: Falló la descompresión de la imagen base."; 
      /bin/rm -rf "$BUILD_DATA_DIR";
      return 1; 
    fi
    
    if [ "$NO_CACHE" = false ]; then
        cp -a "$BUILD_ROOTFS/." "$CACHE_FROM_PATH" || { echo "Advertencia: Falló el cacheo de la capa FROM."; }
    fi
  fi
  END_TIME_STEP=$(date +%s)
  ELAPSED_TIME=$(format_elapsed_time $START_TIME_STEP $END_TIME_STEP)
  echo " (${ELAPSED_TIME})"


  # Configurar directorios especiales y DNS
  mkdir -p "$BUILD_ROOTFS/dev" "$BUILD_ROOTFS/proc" "$BUILD_ROOTFS/sys" "$BUILD_ROOTFS/tmp" "$BUILD_ROOTFS/run"
  chmod 1777 "$BUILD_ROOTFS/tmp"
  echo "nameserver 8.8.8.8" > "$BUILD_ROOTFS/etc/resolv.conf"
  echo "nameserver 8.8.4.4" >> "$BUILD_ROOTFS/etc/resolv.conf"

  # 4. Ejecutar los comandos del Buildfile.
  local CURRENT_WORKDIR="/root" 
  local FINAL_CMD_ARGS_JSON="null" 
  local LAST_LAYER_HASH="$BASE_IMAGE_SHORT_HASH" 
  local ACCUMULATED_ENV_VARS_JSON="[]" # Acumula las variables ENV en JSON string

  # Variables de entorno estándar para el entorno de construcción de /usr/bin/env -i
  local PROOT_BUILD_ENV_VARS_BASE=( 
    "HOME=/root"
    "PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games"
    "TERM=xterm-256color" 
    "LANG=C.UTF-8"
  )

  # Función para obtener el array de variables de entorno COMBINADO para este paso
  get_combined_env_vars_for_step() {
      local combined_env_array=()
      for base_var in "${PROOT_BUILD_ENV_VARS_BASE[@]}"; do
          combined_env_array+=("$base_var")
      done
      if [ "$ACCUMULATED_ENV_VARS_JSON" != "null" ] && [ "$ACCUMULATED_ENV_VARS_JSON" != "[]" ]; then
          while IFS= read -r env_item; do
              combined_env_array+=("$env_item")
          done < <(echo "$ACCUMULATED_ENV_VARS_JSON" | jq -r '.[]')
      fi
      printf "%s\n" "${combined_env_array[@]}"
  }

  local STEP_NUMBER_CURRENT=1 # Contador de pasos para [N/M], empieza desde 1 (después de FROM)
  if [ "$IS_FROM_CACHED" = false ]; then # Si FROM no fue cacheado, ya lo contamos como 1.
    STEP_NUMBER_CURRENT=1
  fi
  # Ajustar el contador para que los pasos después de FROM empiecen en el número correcto.
  # El conteo TOTAL_BUILD_STEPS ya incluye todos los pasos del Buildfile excepto FROM.
  # Así que el primer paso real (RUN, COPY, etc.) será 1 de TOTAL_BUILD_STEPS.

  for line in "${PROCESSED_BUILDFILE_LINES[@]}"; do
    local COMMAND_TYPE=$(echo "$line" | awk '{print $1}')
    local COMMAND_ARGS_RAW=$(echo "$line" | cut -d' ' -f2-) 
    
    local DISPLAY_COMMAND_ARGS=$(echo "$COMMAND_ARGS_RAW" | head -c 60)
    if [ "${#COMMAND_ARGS_RAW}" -gt 60 ]; then
        DISPLAY_COMMAND_ARGS+="..."
    fi

    local COMMAND_HASH=""
    if [ "$COMMAND_TYPE" == "COPY" ]; then
        local SOURCE_HOST_REL=$(echo "$COMMAND_ARGS_RAW" | awk '{print $1}')
        local DEST_CONTAINER=$(echo "$COMMAND_ARGS_RAW" | awk '{print $2}')
        local SOURCE_HOST_ABS="$BUILD_CONTEXT_PATH/$SOURCE_HOST_REL"

        if [ ! -e "$SOURCE_HOST_ABS" ]; then
            echo "Error: Origen '$SOURCE_HOST_ABS' para COPY no encontrado. Abortando construcción."
            rm -rf "$BUILD_DATA_DIR"
            return 1
        fi
        COMMAND_HASH=$(echo "${line}" | sha256sum | awk '{print $1}' | head -c 12)
        COMMAND_HASH+=$(cat "$SOURCE_HOST_ABS" | sha256sum | awk '{print $1}' | head -c 12)
    else
        COMMAND_HASH=$(echo "${line}" | sha256sum | awk '{print $1}' | head -c 12) 
    fi

    local CURRENT_LAYER_ID="${LAST_LAYER_HASH}-${COMMAND_HASH}"
    local CACHE_LAYER_PATH="$CACHED_IMAGES_DIR/layer-$CURRENT_LAYER_ID"
    
    local SKIPPED_FROM_CACHE=false
    local START_TIME_STEP=$(date +%s) 
    local STEP_STATUS="RUNNING"

    if [ "$NO_CACHE" = false ] && [ -d "$CACHE_LAYER_PATH" ] && [ -n "$(ls -A "$CACHE_LAYER_PATH" 2>/dev/null)" ]; then
        echo -n "$(get_current_time) => CACHED [${STEP_NUMBER_CURRENT}/${TOTAL_BUILD_STEPS}] ${COMMAND_TYPE} ${DISPLAY_COMMAND_ARGS} "
        cp -a "$CACHE_LAYER_PATH/." "$BUILD_ROOTFS" || { echo "Error: Falló la copia de la capa cacheada. Abortando construcción."; rm -rf "$BUILD_DATA_DIR"; return 1; }
        SKIPPED_FROM_CACHE=true
        STEP_STATUS="CACHED"
    else
        echo -n "$(get_current_time) => [${STEP_NUMBER_CURRENT}/${TOTAL_BUILD_STEPS}] ${COMMAND_TYPE} ${DISPLAY_COMMAND_ARGS} "
    fi

    unset LD_PRELOAD 

    local PROOT_BASE_ARGS=(
      proot
      --link2symlink
      -0 
      -r "$BUILD_ROOTFS"
      -b /dev:/dev -b /proc:/proc -b /sys:/sys -b /data/data/com.termux/files/usr/tmp:/tmp 
      -b /data/data/com.termux:/data/data/com.termux -b /:/host-rootfs -b /sdcard -b /storage -b /mnt
    )
    
    if [ "$base_dist_name" == "alpine" ]; then
        PROOT_BASE_ARGS+=("-b" "$BUILD_ROOTFS/bin/busybox:/bin/sh")
    fi

    PROOT_BASE_ARGS+=("-w" "$CURRENT_WORKDIR")
    PROOT_BASE_ARGS+=("--kill-on-exit")


    case "$COMMAND_TYPE" in
      FROM)
        # Esto ya fue manejado al inicio y no debería aparecer aquí.
        ;;
      RUN)
        if [ "$SKIPPED_FROM_CACHE" = false ]; then
            local RUN_SHELL="/bin/bash"
            if [ "$base_dist_name" == "alpine" ]; then RUN_SHELL="/bin/sh"; fi
            
            local COMBINED_ENV_VARS_ARRAY=($(get_combined_env_vars_for_step))
            local ENV_AND_CMD_ARGS=("/usr/bin/env" "-i") 
            ENV_AND_CMD_ARGS+=("${COMBINED_ENV_VARS_ARRAY[@]}")
            ENV_AND_CMD_ARGS+=("$RUN_SHELL" "-c" "$COMMAND_ARGS_RAW") 
            
            local STEP_LOG_FILE="$BUILD_DATA_DIR/step_${STEP_NUMBER_CURRENT}.log"
            "${PROOT_BASE_ARGS[@]}" "${ENV_AND_CMD_ARGS[@]}" > "$STEP_LOG_FILE" 2>&1
            local CMD_EXIT_CODE=$?

            if [ "$CMD_EXIT_CODE" -ne 0 ]; then
              echo -e "\nError: El paso 'RUN $DISPLAY_COMMAND_ARGS' falló con código $CMD_EXIT_CODE."
              echo "Contenido del log del paso:"
              cat "$STEP_LOG_FILE"
              rm -rf "$BUILD_DATA_DIR"
              return 1
            fi
            
            if [ "$NO_CACHE" = false ]; then
                mkdir -p "$CACHE_LAYER_PATH"
                cp -a "$BUILD_ROOTFS/." "$CACHE_LAYER_PATH" || { echo "Advertencia: Falló el cacheo de la capa. No afectará la construcción actual."; }
            fi
        fi
        LAST_LAYER_HASH="$CURRENT_LAYER_ID" 
        ;;
      COPY)
        if [ "$SKIPPED_FROM_CACHE" = false ]; then
            local SOURCE_HOST_REL=$(echo "$COMMAND_ARGS_RAW" | awk '{print $1}')
            local DEST_CONTAINER=$(echo "$COMMAND_ARGS_RAW" | awk '{print $2}')
            local SOURCE_HOST_ABS="$BUILD_CONTEXT_PATH/$SOURCE_HOST_REL"

            if [ ! -e "$SOURCE_HOST_ABS" ]; then
                echo "Error: Origen '$SOURCE_HOST_ABS' para COPY no encontrado. Abortando construcción."
                rm -rf "$BUILD_DATA_DIR"
                return 1
            fi

            PROOT_BASE_ARGS+=("-b" "$BUILD_CONTEXT_PATH:/host_build_context")

            local CP_CMD="/bin/cp -a"
            if [ "$base_dist_name" == "alpine" ]; then CP_CMD="/bin/busybox cp -a"; fi

            local COMBINED_ENV_VARS_ARRAY=($(get_combined_env_vars_for_step)) 
            local ENV_AND_CMD_ARGS=("/usr/bin/env" "-i")
            ENV_AND_CMD_ARGS+=("${COMBINED_ENV_VARS_ARRAY[@]}")
            local RUN_SHELL="/bin/bash" 
            if [ "$base_dist_name" == "alpine" ]; then RUN_SHELL="/bin/sh"; fi
            ENV_AND_CMD_ARGS+=("$RUN_SHELL" "-c" "$CP_CMD /host_build_context/\"$SOURCE_HOST_REL\" \"$DEST_CONTAINER\"")

            local STEP_LOG_FILE="$BUILD_DATA_DIR/step_${STEP_NUMBER_CURRENT}.log"
            "${PROOT_BASE_ARGS[@]}" "${ENV_AND_CMD_ARGS[@]}" > "$STEP_LOG_FILE" 2>&1
            local CMD_EXIT_CODE=$?

            if [ "$CMD_EXIT_CODE" -ne 0 ]; then
              echo "Error: El paso 'COPY $DISPLAY_COMMAND_ARGS' falló con código $CMD_EXIT_CODE."
              echo "Contenido del log del paso:"
              cat "$STEP_LOG_FILE"
              rm -rf "$BUILD_DATA_DIR"
              return 1
            fi
            
            if [ "$NO_CACHE" = false ]; then
                mkdir -p "$CACHE_LAYER_PATH"
                cp -a "$BUILD_ROOTFS/." "$CACHE_LAYER_PATH" || { echo "Advertencia: Falló el cacheo de la capa. No afectará la construcción actual."; }
            fi
        fi
        LAST_LAYER_HASH="$CURRENT_LAYER_ID" 
        ;;
      WORKDIR)
        CURRENT_WORKDIR="$COMMAND_ARGS_RAW"
        LAST_LAYER_HASH="$CURRENT_LAYER_ID" 
        ;;
      CMD)
        FINAL_CMD_ARGS_JSON="$COMMAND_ARGS_RAW" 
        LAST_LAYER_HASH="$CURRENT_LAYER_ID" 
        ;;
      ENV) 
        local env_arg_split=""
        if [[ "$COMMAND_ARGS_RAW" =~ ^[^=]+= ]]; then 
            ACCUMULATED_ENV_VARS_JSON=$(echo "$ACCUMULATED_ENV_VARS_JSON" | jq --arg new_env "$COMMAND_ARGS_RAW" '. += [$new_env]')
        elif [ -n "$(echo "$COMMAND_ARGS_RAW" | awk '{print $1}')" ]; then 
            local env_key=$(echo "$COMMAND_ARGS_RAW" | awk '{print $1}')
            local env_value=$(echo "$COMMAND_ARGS_RAW" | cut -d' ' -f2-)
            ACCUMULATED_ENV_VARS_JSON=$(echo "$ACCUMULATED_ENV_VARS_JSON" | jq --arg name "$env_key" --arg value "$env_value" '. += ["\($name)=\($value)"]')
        else
            echo "Advertencia: Formato de ENV inválido '$COMMAND_ARGS_RAW'. Saltando." >&2
        fi
        LAST_LAYER_HASH="$CURRENT_LAYER_ID" 
        ;;
      *)
        echo "Advertencia: Comando de Buildfile desconocido '$COMMAND_TYPE'. Saltando." >&2 
        ;;
    esac
    # Solo incrementar el STEP_NUMBER_DISPLAY si no se saltó este paso.
    # El tiempo transcurrido se muestra después de cada paso.
    # Los mensajes de "Estableciendo WORKDIR" o "Comando predeterminado" ya no necesitan su propio 'echo -n'.
    # if [ "$SKIPPED_FROM_CACHE" = false ]; then
    #     if [ "$COMMAND_TYPE" == "WORKDIR" ]; then
    #         echo -e "Estableciendo WORKDIR: ${DISPLAY_COMMAND_ARGS} "
    #     elif [ "$COMMAND_TYPE" == "CMD" ]; then
    #         echo -e "Comando predeterminado (CMD) guardado: ${DISPLAY_COMMAND_ARGS} "
    #     elif [ "$COMMAND_TYPE" == "ENV" ]; then
    #         echo -e "Estableciendo variable de entorno: ${DISPLAY_COMMAND_ARGS} "
    #     fi
    # fi

    local END_TIME_STEP=$(date +%s)
    local ELAPSED_TIME_FORMATTED=$(format_elapsed_time $START_TIME_STEP $END_TIME_STEP)
    echo " (${ELAPSED_TIME_FORMATTED})"

    # Solo incrementar el número de paso si NO es un paso CACHED.
    # El STEP_NUMBER_DISPLAY ya está diseñado para avanzar con cada línea lógica real.
    # Si SKIPPED_FROM_CACHE es true, el STEP_NUMBER_DISPLAY no se incrementa.
    # Ya está bien manejado con STEP_NUMBER_DISPLAY=$((STEP_NUMBER_DISPLAY + 1)) dentro del if/else.
    STEP_NUMBER_CURRENT=$((STEP_NUMBER_CURRENT + 1)) # Incrementar el contador para el display
    if [ "$STEP_NUMBER_CURRENT" -gt "$TOTAL_BUILD_STEPS" ]; then
        break # Si superamos los pasos totales, salir del bucle.
    fi

  done # Cierre del bucle for sobre PROCESSED_BUILDFILE_LINES

  local BUILD_END_TIME=$(date +%s)
  local TOTAL_BUILD_ELAPSED_TIME=$((BUILD_END_TIME - BUILD_START_TIME))

  echo -e "\n[+] Building $(format_elapsed_time $BUILD_START_TIME $BUILD_END_TIME) FINISHED ${IMAGE_TAG_NAME}" # Resumen final
  
  # 5. Guardar la nueva imagen.
  local NEW_IMAGE_DIST_NAME=$(echo "$IMAGE_TAG_NAME" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  local NEW_IMAGE_VERSION_TAG=$(echo "$IMAGE_TAG_NAME" | cut -d':' -f2)
  if [ -z "$NEW_IMAGE_VERSION_TAG" ]; then NEW_IMAGE_VERSION_TAG="latest"; fi 

  local NEW_IMAGE_FILENAME="${NEW_IMAGE_DIST_NAME}-${NEW_IMAGE_VERSION_TAG}.tar.gz"
  local NEW_IMAGE_PATH="${DOWNLOAD_IMAGES_DIR}/${NEW_IMAGE_FILENAME}"

  # Mostrando la línea final de exportación como Docker
  echo -n "$(get_current_time) => exporting to image "
  local EXPORT_START_TIME=$(date +%s)
  echo "---------- $NEW_IMAGE_PATH"
    
  sh -c "/bin/tar -czf "$NEW_IMAGE_PATH" \
      --exclude='dev/*' \
      --exclude='proc/*' \
      --exclude='sys/*' \
      --exclude='tmp/*' \
      --exclude='run/*' \
      -C "$BUILD_ROOTFS" ." || { echo "Error: Falló al crear la imagen TAR.GZ."; rm -rf "$BUILD_DATA_DIR"; return 1; }
  
  local EXPORT_END_TIME=$(date +%s)
  local EXPORT_ELAPSED_TIME=$(format_elapsed_time $EXPORT_START_TIME $EXPORT_END_TIME)
  echo " (${EXPORT_ELAPSED_TIME})"
  
  local METADATA_WRITE_START_TIME=$(date +%s)
  # --- Guardar metadatos de la imagen ---
  local IMAGE_METADATA_FILE="$DOWNLOAD_IMAGES_DIR/${NEW_IMAGE_DIST_NAME}-${NEW_IMAGE_VERSION_TAG}.json"
  local CURRENT_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%N%z)
  local IMAGE_ID=$(echo "$NEW_IMAGE_PATH" | md5sum | cut -d' ' -f1)

  local FINAL_CMD_JSON_FOR_METADATA_CLEAN="null"
  if command_exists jq; then
      echo  " {{{{{{{{$FINAL_CMD_ARGS_JSON" 
      if echo "$FINAL_CMD_ARGS_JSON" | jq -e 'if type == "array" then . else empty end' >/dev/null 2>&1; then

          FINAL_CMD_JSON_FOR_METADATA_CLEAN="$FINAL_CMD_ARGS_JSON"
      fi
  else
      if [ -n "$FINAL_CMD_ARGS_JSON" ]; then
          FINAL_CMD_JSON_FOR_METADATA_CLEAN="$FINAL_CMD_ARGS_JSON"
      fi
  fi

  local FINAL_WORKDIR_FOR_METADATA="${CURRENT_WORKDIR}" 

  cat << EOF > "$IMAGE_METADATA_FILE"
{
  "Id": "$IMAGE_ID",
  "RepoTags": ["$IMAGE_TAG_NAME"],
  "Created": "$CURRENT_TIMESTAMP",
  "Size": "$(get_container_size_from_tar "$NEW_IMAGE_PATH")",
  "VirtualSize": "$(get_dir_hash "$BUILD_ROOTFS")",
  "ContainerConfig": {
    "Cmd": $FINAL_CMD_JSON_FOR_METADATA_CLEAN,
    "WorkingDir": "$FINAL_WORKDIR_FOR_METADATA",
    "Entrypoint": null,
    "Env": $ACCUMULATED_ENV_VARS_JSON 
  },
  "Os": "linux",
  "Architecture": "$(get_mapped_architecture)"
}
EOF
  local METADATA_WRITE_END_TIME=$(date +%s)
  local METADATA_WRITE_ELAPSED_TIME=$(format_elapsed_time $METADATA_WRITE_START_TIME $METADATA_WRITE_END_TIME)
  echo -e "$(get_current_time) => => writing image sha256:${IMAGE_ID} (${METADATA_WRITE_ELAPSED_TIME})"
  echo -e "$(get_current_time) => => naming => /library/${IMAGE_TAG_NAME} (${METADATA_WRITE_ELAPSED_TIME})" 

  # 6. Limpiar el contenedor temporal de construcción.
  rm -rf "$BUILD_DATA_DIR"

  echo "------------------------------------------------------------" 
  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
main_build_logic "$@"