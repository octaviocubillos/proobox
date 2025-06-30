#!/data/data/com.termux/files/usr/bin/bash

# Este script permite crear imágenes personalizadas a partir de un archivo de configuración (Buildfile).
# Ahora incluye cacheo de capas para acelerar las construcciones.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PULL_SCRIPT="$SCRIPT_DIR/pull.sh"

# Cargar pull.sh (para download_image, get_mapped_architecture)
if [ -f "$PULL_SCRIPT" ]; then
  . "$PULL_SCRIPT" 
else
  echo "Error: No se encontró el script de pull '$PULL_SCRIPT'. Funcionalidad de build limitada."
  exit 1
fi

# Directorios
DOWNLOAD_IMAGES_DIR="$HOME/.termux-container/images" 
CONTAINERS_DIR="$HOME/.termux-container/containers" 
CACHED_IMAGES_DIR="$HOME/.termux-container/cached_images" # Directorio para cache de capas de build

# --- Funciones de Utilidad (locales a build.sh) ---
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

# Función para calcular un hash SHA256 del contenido de un directorio.
get_dir_hash() {
    local dir_path="$1"
    if [ ! -d "$dir_path" ]; then
        echo "0" # Hash para directorio vacío o inexistente
        return
    fi 
    # find + sort para asegurar orden consistente, luego sha256sum
    # Pipe a sha256sum y tomar los primeros 12 caracteres para el ID corto
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


# --- Lógica Principal del Script build.sh ---
main_build_logic() {
  local BUILD_FILE_PATH="Buildfile" # Por defecto
  local IMAGE_TAG_NAME="" # Nombre de la nueva imagen (ej. my_app:v1)
  local NO_CACHE=false # Opcional: --no-cache

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
    echo "  ./termux-container build ."
    echo "  ./termux-container build -t my_custom_ubuntu:latest /path/to/my/app/code"
    echo "  ./termux-container build -f MyCustomBuildfile -t my_app:test ."
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

  echo "--- Iniciando Construcción de Imagen ---"
  echo "Buildfile: $BUILD_FILE_PATH"
  echo "Contexto:  $BUILD_CONTEXT_PATH"
  echo "Nueva Imagen (Tag): $IMAGE_TAG_NAME"

  # 1. Leer el Buildfile y determinar la imagen base.
  local FROM_LINE=$(grep -m 1 '^FROM ' "$BUILD_FILE_PATH")
  if [ -z "$FROM_LINE" ]; then
    echo "Error: Buildfile no contiene una línea 'FROM'."
    return 1
  fi

  local BASE_IMAGE_TAG=$(echo "$FROM_LINE" | awk '{print $2}')
  if [ -z "$BASE_IMAGE_TAG" ]; then
    echo "Error: La línea 'FROM' en el Buildfile no especifica una imagen base."
    return 1
  fi

  echo "Imagen base especificada: $BASE_IMAGE_TAG"

  # 2. Descargar la imagen base si no existe.
  local base_dist_name=$(echo "$BASE_IMAGE_TAG" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  local base_image_version=$(echo "$BASE_IMAGE_TAG" | cut -d':' -f2)
  local base_image_tar_path="${DOWNLOAD_IMAGES_DIR}/${base_dist_name}-${base_image_version}.tar.gz"

  if [ ! -f "$base_image_tar_path" ]; then
    echo "Imagen base '$BASE_IMAGE_TAG' no encontrada localmente. Descargando..."
    if ! download_image "$base_dist_name" "$base_image_version" "$(get_mapped_architecture)"; then
      echo "Error: Falló la descarga de la imagen base '$BASE_IMAGE_TAG'."
      return 1
    fi
  else
    echo "Imagen base '$BASE_IMAGE_TAG' encontrada localmente."
  fi

  # 3. Crear un contenedor temporal para la construcción.
  local BUILD_CONTAINER_NAME="build-temp-$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)" # ID más largo
  local BUILD_ROOTFS="$CONTAINERS_DIR/$BUILD_CONTAINER_NAME/rootfs"
  local BUILD_DATA_DIR="$CONTAINERS_DIR/$BUILD_CONTAINER_NAME"

  echo "Creando contenedor temporal para la construcción: $BUILD_CONTAINER_NAME"
  mkdir -p "$BUILD_DATA_DIR" || { echo "Error: No se pudo crear el directorio del contenedor temporal."; return 1; }
  mkdir -p "$BUILD_ROOTFS" || { echo "Error: No se pudo crear el rootfs del contenedor temporal."; return 1; }

  # --- Lógica de Cacheo para la capa FROM ---
  # El ID de la capa FROM es un hash de la imagen base original.
  # Usar un hash más corto para el nombre del directorio.
  local BASE_IMAGE_FULL_HASH=$(echo "$BASE_IMAGE_TAG" | sha256sum | awk '{print $1}')
  local BASE_IMAGE_SHORT_HASH=$(echo "$BASE_IMAGE_FULL_HASH" | head -c 12)
  local CACHE_FROM_PATH="$CACHED_IMAGES_DIR/layer-$BASE_IMAGE_SHORT_HASH"
  mkdir -p "$CACHED_IMAGES_DIR" # Asegurar que el directorio de cache exista.

  if [ -d "$CACHE_FROM_PATH" ] && [ "$NO_CACHE" = false ] && [ -n "$(ls -A "$CACHE_FROM_PATH" 2>/dev/null)" ]; then
    echo "Usando capa FROM cacheadada para '$BASE_IMAGE_TAG'..."
    cp -a "$CACHE_FROM_PATH/." "$BUILD_ROOTFS" || { echo "Error: Falló la copia de la capa FROM cacheada."; rm -rf "$BUILD_DATA_DIR"; return 1; }
  else
    echo "Capa FROM no cacheada. Descomprimiendo imagen base en '$BUILD_ROOTFS'..."
    tar -xf "$base_image_tar_path" -C "$BUILD_ROOTFS" --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' --no-same-owner || { echo "Error: Falló la descompresión de la imagen base."; rm -rf "$BUILD_DATA_DIR"; return 1; }
    
    # Guardar la capa FROM en cache para futuros usos.
    if [ "$NO_CACHE" = false ]; then
        echo "Guardando capa FROM en cache: '$CACHE_FROM_PATH'"
        cp -a "$BUILD_ROOTFS/." "$CACHE_FROM_PATH" || { echo "Advertencia: Falló el cacheo de la capa FROM. No afectará la construcción actual."; }
    fi
  fi

  # Configurar directorios especiales y DNS
  mkdir -p "$BUILD_ROOTFS/dev" "$BUILD_ROOTFS/proc" "$BUILD_ROOTFS/sys" "$BUILD_ROOTFS/tmp" "$BUILD_ROOTFS/run"
  chmod 1777 "$BUILD_ROOTFS/tmp"
  echo "nameserver 8.8.8.8" > "$BUILD_ROOTFS/etc/resolv.conf"
  echo "nameserver 8.8.4.4" >> "$BUILD_ROOTFS/etc/resolv.conf"
  echo "Entorno base de construcción configurado (DNS a 8.8.8.8)."

  # 4. Ejecutar los comandos del Buildfile.
  echo "Ejecutando pasos del Buildfile..."
  
  local STEP_COUNTER=0
  local CURRENT_WORKDIR="/root" # Directorio de trabajo inicial en el contenedor
  local FINAL_CMD_ARGS_JSON="null" # <--- Variable para el string JSON del CMD!
  local LAST_LAYER_HASH="$BASE_IMAGE_SHORT_HASH" # Hash de la capa anterior para el cacheo

  # Variables de entorno estándar para el entorno de construcción de /usr/bin/env -i
  local PROOT_BUILD_ENV_VARS=(
    "HOME=/root"
    "PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games"
    "TERM=xterm-256color" 
    "LANG=C.UTF-8"
  )

  # Leer Buildfile línea por línea
  while IFS= read -r line; do 
    line=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//') # Eliminar espacios en blanco
    if [[ -z "$line" || "$line" =~ ^# ]]; then continue; fi 
    
    local COMMAND_TYPE=$(echo "$line" | awk '{print $1}')
    local COMMAND_ARGS_RAW=$(echo "$line" | cut -d' ' -f2-) 
    
    # Pre-calculo del hash del comando para el cacheo
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
    if [ "$NO_CACHE" = false ] && [ -d "$CACHE_LAYER_PATH" ] && [ -n "$(ls -A "$CACHE_LAYER_PATH" 2>/dev/null)" ]; then
        echo "--- Paso $STEP_COUNTER: Usando capa cacheada para '$COMMAND_TYPE $COMMAND_ARGS_RAW' ---"
        cp -a "$CACHE_LAYER_PATH/." "$BUILD_ROOTFS" || { echo "Error: Falló la copia de la capa cacheada. Abortando construcción."; rm -rf "$BUILD_DATA_DIR"; return 1; }
        SKIPPED_FROM_CACHE=true
    else
        STEP_COUNTER=$((STEP_COUNTER + 1)) # Solo incrementar si no se usa el cache
        echo "--- Paso $STEP_COUNTER: $COMMAND_TYPE $COMMAND_ARGS_RAW ---"
        echo "  Capa no cacheada. Ejecutando..."
    fi

    unset LD_PRELOAD # Crucial antes de cada invocación de proot.

    # Construir los argumentos base de proot para este paso (sin /usr/bin/env ni comando final aún)
    local PROOT_BASE_ARGS=(
      proot
      --link2symlink
      -0 
      -r "$BUILD_ROOTFS"
      -b /dev:/dev -b /proc:/proc -b /sys:/sys -b /data/data/com.termux/files/usr/tmp:/tmp 
      -b /data/data/com.termux:/data/data/com.termux -b /:/host-rootfs -b /sdcard -b /storage -b /mnt
    )
    
    # Añadir bind-mount para Alpine si es necesario
    if [ "$base_dist_name" == "alpine" ]; then
        PROOT_BASE_ARGS+=("-b" "$BUILD_ROOTFS/bin/busybox:/bin/sh")
    fi

    # Establecer el WORKDIR actual para el comando
    PROOT_BASE_ARGS+=("-w" "$CURRENT_WORKDIR")
    PROOT_BASE_ARGS+=("--kill-on-exit") # Terminar proot al finalizar este paso.


    case "$COMMAND_TYPE" in
      FROM)
        # FROM ya fue manejado al inicio, se ignora aquí.
        ;;
      RUN)
        if [ "$SKIPPED_FROM_CACHE" = false ]; then
            # El comando a ejecutar es el shell adecuado para la distro, que interpretará COMMAND_ARGS_RAW.
            local RUN_SHELL="/bin/bash"
            if [ "$base_dist_name" == "alpine" ]; then RUN_SHELL="/bin/sh"; fi
            
            # Construir el comando final para 'env -i' y el shell/comando
            local ENV_AND_CMD_ARGS=("/usr/bin/env" "-i") # Iniciar env -i
            ENV_AND_CMD_ARGS+=("${PROOT_BUILD_ENV_VARS[@]}") # Variables de entorno base
            ENV_AND_CMD_ARGS+=("$RUN_SHELL" "-c" "$COMMAND_ARGS_RAW") # Shell y comando
            
            echo "  Ejecutando: $COMMAND_ARGS_RAW"
            "${PROOT_BASE_ARGS[@]}" "${ENV_AND_CMD_ARGS[@]}" # Ejecutar el comando proot completo
            if [ $? -ne 0 ]; then
              echo "Error: El paso 'RUN $COMMAND_ARGS_RAW' falló. Abortando construcción."
              rm -rf "$BUILD_DATA_DIR"
              return 1
            fi
            
            # Guardar la capa en cache si no se ha saltado y no hay --no-cache
            if [ "$NO_CACHE" = false ]; then
                echo "  Guardando capa en cache: '$CACHE_LAYER_PATH'"
                mkdir -p "$CACHE_LAYER_PATH"
                cp -a "$BUILD_ROOTFS/." "$CACHE_LAYER_PATH" || { echo "Advertencia: Falló el cacheo de la capa. No afectará la construcción actual."; }
            fi
        fi
        LAST_LAYER_HASH="$CURRENT_LAYER_ID" # Actualizar hash de la última capa
        ;;
      COPY)
        if [ "$SKIPPED_FROM_CACHE" = false ]; then
            # Sintaxis: COPY <origen_host_relativo> <destino_contenedor>
            local SOURCE_HOST_REL=$(echo "$COMMAND_ARGS_RAW" | awk '{print $1}')
            local DEST_CONTAINER=$(echo "$COMMAND_ARGS_RAW" | awk '{print $2}')
            local SOURCE_HOST_ABS="$BUILD_CONTEXT_PATH/$SOURCE_HOST_REL"

            if [ ! -e "$SOURCE_HOST_ABS" ]; then
                echo "Error: Origen '$SOURCE_HOST_ABS' para COPY no encontrado. Abortando construcción."
                rm -rf "$BUILD_DATA_DIR"
                return 1
            fi

            # Para COPY, necesitamos montar el contexto de construcción dentro del contenedor temporal.
            PROOT_BASE_ARGS+=("-b" "$BUILD_CONTEXT_PATH:/host_build_context")

            # El comando 'cp -a' dentro del contenedor.
            local CP_CMD="/bin/cp -a"
            if [ "$base_dist_name" == "alpine" ]; then CP_CMD="/bin/busybox cp -a"; fi

            # Construir el comando final para 'env -i' y 'cp -a'.
            local ENV_AND_CMD_ARGS=("/usr/bin/env" "-i")
            ENV_AND_CMD_ARGS+=("${PROOT_BUILD_ENV_VARS[@]}")
            local RUN_SHELL="/bin/bash" 
            if [ "$base_dist_name" == "alpine" ]; then RUN_SHELL="/bin/sh"; fi
            # Asegurarse de que las rutas dentro del contenedor estén citadas.
            ENV_AND_CMD_ARGS+=("$RUN_SHELL" "-c" "$CP_CMD /host_build_context/\"$SOURCE_HOST_REL\" \"$DEST_CONTAINER\"")

            echo "  Copiando '$SOURCE_HOST_REL' a '$DEST_CONTAINER' en el contenedor..."
            "${PROOT_BASE_ARGS[@]}" "${ENV_AND_CMD_ARGS[@]}" # Ejecutar el comando proot completo
            if [ $? -ne 0 ]; then
              echo "Error: El paso 'COPY $COMMAND_ARGS_RAW' falló. Abortando construcción."
              rm -rf "$BUILD_DATA_DIR"
              return 1
            fi
            
            # Guardar la capa en cache si no se ha saltado y no hay --no-cache
            if [ "$NO_CACHE" = false ]; then
                echo "  Guardando capa en cache: '$CACHE_LAYER_PATH'"
                mkdir -p "$CACHE_LAYER_PATH"
                cp -a "$BUILD_ROOTFS/." "$CACHE_LAYER_PATH" || { echo "Advertencia: Falló el cacheo de la capa. No afectará la construcción actual."; }
            fi
        fi
        LAST_LAYER_HASH="$CURRENT_LAYER_ID" # Actualizar hash de la última capa
        ;;
      WORKDIR)
        # Actualizamos el directorio de trabajo actual para las próximas invocaciones de proot.
        CURRENT_WORKDIR="$COMMAND_ARGS_RAW"
        echo "  Estableciendo WORKDIR: $CURRENT_WORKDIR"
        # WORKDIR no genera una nueva capa, solo cambia el estado para el hashing de futuras capas.
        ;;
      CMD)
        # Se guarda el CMD para la imagen final.
        # CAPTURA EL STRING JSON DEL CMD TAL CUAL APARECE EN EL BUILDFILE.
        FINAL_CMD_ARGS_JSON="$COMMAND_ARGS_RAW" 
        echo "  Comando predeterminado (CMD) guardado: $FINAL_CMD_ARGS_JSON"
        ;;
      *)
        echo "Advertencia: Comando de Buildfile desconocido '$COMMAND_TYPE'. Saltando."
        ;;
    esac
  done < "$BUILD_FILE_PATH" # <--- ¡Aquí se lee el Buildfile directamente!

  echo "--- Pasos del Buildfile finalizados ---"

  # 5. Guardar la nueva imagen.
  local NEW_IMAGE_DIST_NAME=$(echo "$IMAGE_TAG_NAME" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  local NEW_IMAGE_VERSION_TAG=$(echo "$IMAGE_TAG_NAME" | cut -d':' -f2)
  if [ -z "$NEW_IMAGE_VERSION_TAG" ]; then NEW_IMAGE_VERSION_TAG="latest"; fi # Etiqueta por defecto

  local NEW_IMAGE_FILENAME="${NEW_IMAGE_DIST_NAME}-${NEW_IMAGE_VERSION_TAG}.tar.gz"
  local NEW_IMAGE_PATH="${DOWNLOAD_IMAGES_DIR}/${NEW_IMAGE_FILENAME}"

  echo "Guardando el estado del contenedor '$BUILD_CONTAINER_NAME' como nueva imagen '$IMAGE_TAG_NAME'..."
  # Crear el tar.gz del rootfs del contenedor temporal.
  tar -czf "$NEW_IMAGE_PATH" \
      --exclude='dev/*' \
      --exclude='proc/*' \
      --exclude='sys/*' \
      --exclude='tmp/*' \
      --exclude='run/*' \
      -C "$BUILD_ROOTFS" . || { echo "Error: Falló al crear la imagen TAR.GZ."; rm -rf "$BUILD_DATA_DIR"; return 1; }

  if [ $? -eq 0 ]; then
    echo "¡Imagen '$IMAGE_TAG_NAME' creada con éxito en '$NEW_IMAGE_PATH'!"
  else
    echo "Error: Falló la creación de la imagen '$IMAGE_TAG_NAME'."
    rm -rf "$BUILD_DATA_DIR"
    return 1
  fi

  # --- Guardar metadatos de la imagen ---
  local IMAGE_METADATA_FILE="$DOWNLOAD_IMAGES_DIR/${NEW_IMAGE_DIST_NAME}-${NEW_IMAGE_VERSION_TAG}.json"
  local CURRENT_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%N%z)
  local IMAGE_ID=$(echo "$NEW_IMAGE_PATH" | md5sum | cut -d' ' -f1)

  # Asegurarse de que FINAL_CMD_ARGS_JSON sea un string JSON válido.
  local FINAL_CMD_JSON_FOR_METADATA_CLEAN="null"
  if command_exists jq; then
      if echo "$FINAL_CMD_ARGS_JSON" | jq -e '.|type == "array"' >/dev/null 2>&1; then
          FINAL_CMD_JSON_FOR_METADATA_CLEAN="$FINAL_CMD_ARGS_JSON"
      else
          echo "Advertencia: CMD en Buildfile no parece un array JSON válido. Guardando como null."
          FINAL_CMD_JSON_FOR_METADATA_CLEAN="null"
      fi
  else
      echo "Advertencia: 'jq' no está instalado. No se puede validar el formato JSON del CMD en Buildfile."
      echo "Asegúrese de que el CMD en su Buildfile esté en formato JSON de array (ej: [\"/bin/bash\", \"--login\"])."
      FINAL_CMD_JSON_FOR_METADATA_CLEAN="$FINAL_CMD_ARGS_JSON" 
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
    "Entrypoint": null 
  },
  "Os": "linux",
  "Architecture": "$(get_mapped_architecture)"
}
EOF
  echo "Metadatos de la imagen guardados en: $IMAGE_METADATA_FILE"
  # --- FIN Guardado de metadatos de la imagen ---

  # 6. Limpiar el contenedor temporal de construcción.
  echo "Limpiando contenedor temporal '$BUILD_CONTAINER_NAME'..."
  rm -rf "$BUILD_DATA_DIR"

  echo "--- Proceso de construcción finalizado ---"
  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
main_build_logic "$@"