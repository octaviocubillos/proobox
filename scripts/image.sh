#!/data/data/com.termux/files/usr/bin/bash

# Este script gestiona las imágenes de contenedores en el sistema.

# --- Variables de Configuración Global ---
DOWNLOAD_IMAGES_DIR="$HOME/.proobox/images"
CONTAINERS_DIR="$HOME/.proobox/containers" # Necesario para is_running

# --- Funciones de Utilidad ---
# Función para verificar si un comando existe en el PATH.
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

# Determina si un proceso proot está en ejecución para un contenedor dado.
is_running() {
    local container_name="$1"
    local rootfs_path_escaped=$(echo "$CONTAINERS_DIR/$container_name/rootfs" | sed 's/\//\\\//g')
    if pgrep -f "proot.*-r $rootfs_path_escaped" >/dev/null; then
        echo "Running"
    else
        echo "Exited"
    fi
}

# Obtiene el tamaño del rootfs de un contenedor (para ps.sh, pero también puede ser útil aquí).
get_container_size() {
    local container_name="$1"
    local rootfs_path="$CONTAINERS_DIR/$container_name/rootfs"
    if [ -d "$rootfs_path" ]; then
        du -sh "$rootfs_path" 2>/dev/null | awk '{print $1}'
    else
        echo "0B"
    fi
}

# Función para obtener la ruta al archivo JSON de metadatos de una imagen.
get_image_metadata_path() {
    local target_image_spec="$1" # Ej: "ubuntu:22.04.3" o un ID corto "a1b2c3d4e5f6"
    local metadata_file_path=""

    # 1. Intentar por nombre completo (repo:tag)
    local img_name_part=$(echo "$target_image_spec" | cut -d':' -f1)
    local img_tag_part=$(echo "$target_image_spec" | cut -d':' -f2)
    if [ -z "$img_tag_part" ]; then img_tag_part="latest"; fi # Default tag

    local potential_path="${DOWNLOAD_IMAGES_DIR}/${img_name_part}-${img_tag_part}.json"
    if [ -f "$potential_path" ]; then
        echo "$potential_path"
        return 0
    fi

    # 2. Intentar por ID corto (buscar en todos los JSON por el campo .Id)
    if [ ${#target_image_spec} -ge 4 ] && [ ${#target_image_spec} -le 12 ]; then 
        local found_json_path=$(find "$DOWNLOAD_IMAGES_DIR" -maxdepth 1 -name "*.json" -print0 | xargs -0 jq -r "select(.Id | startswith(\"$target_image_spec\")) | .Image.Name" 2>/dev/null | head -n 1) 
        
        if [ -n "$found_json_path" ]; then
            local reconstructed_name_part=$(echo "$found_json_path" | cut -d':' -f1)
            local reconstructed_tag_part=$(echo "$found_json_path" | cut -d':' -f2)
            if [ -z "$reconstructed_tag_part" ]; then reconstructed_tag_part="latest"; fi
            echo "${DOWNLOAD_IMAGES_DIR}/${reconstructed_name_part}-${reconstructed_tag_part}.json"
            return 0
        fi
    fi

    return 1 
}

# --- Lógica Principal del Script image.sh ---
main_image_logic() {
  local subcommand="$1" 
  shift 

  show_image_help() {
    echo "Uso: image.sh [comando]"
    echo ""
    echo "Comandos para gestión de imágenes:"
    echo "  ls                     Lista las imágenes disponibles."
    echo "  rm <nombre>[:<tag>]    Elimina una imagen. Opciones: -f (forzar)."
    echo "  tag <origen>:<tag_origen> <destino>:<tag_destino>  Etiqueta una imagen."
    echo ""
    echo "Opciones comunes para 'ls':"
    echo "  -q, --quiet            Muestra solo los IDs de las imágenes."
    echo "  -s, --size             Muestra el tamaño total de cada imagen."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container image ls"
    echo "  ./termux-container image ls -s"
    echo "  ./termux-container image rm my_app:latest"
    echo "  ./termux-container image tag ubuntu:22.04.3 ubuntu:latest"
  }

  if [ -z "$subcommand" ]; then
    show_image_help
    return 0
  fi

  # Asegurarse de que jq está instalado para todas las operaciones que lo necesiten.
  if ! command_exists jq; then
    echo "Error: 'jq' no está instalado. Necesario para leer/escribir metadatos de imágenes. Por favor, instálalo con 'pkg install jq'."
    return 1
  fi

  case "$subcommand" in
    ls)
      local SHOW_QUIET=false
      local SHOW_SIZE=false

      # Parseo de opciones para 'ls'
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          -q|--quiet)
            SHOW_QUIET=true
            shift
            ;;
          -s|--size)
            SHOW_SIZE=true
            shift
            ;;
          -h|--help)
            show_image_help
            return 0
            ;;
          *) 
            echo "Error: Opción o argumento desconocido para 'image ls': $1"
            show_image_help
            return 1
            ;;
        esac
      done

      echo "--- Imágenes de Contenedores Disponibles ---"
      if [ ! -d "$DOWNLOAD_IMAGES_DIR" ] || [ -z "$(ls -A "$DOWNLOAD_IMAGES_DIR" 2>/dev/null)" ]; then
        echo "No hay imágenes descargadas o construidas aún."
        echo "Usa 'termux-container pull <imagen>' o 'termux-container build' para crearlas."
        return 0
      fi

      local image_data=()
      # NUEVO: Leer todos los archivos JSON de metadatos directamente y filtrarlos.
      # Esto es más robusto que usar find + xargs + jq para cada archivo.
      local json_files=($(find "$DOWNLOAD_IMAGES_DIR" -maxdepth 1 -name "*.json" -print0 | xargs -0))

      if [ ${#json_files[@]} -eq 0 ]; then
          echo "No se encontraron archivos de metadatos de imagen (.json) en '$DOWNLOAD_IMAGES_DIR'."
          return 0
      fi

      for json_file in "${json_files[@]}"; do
          # Depuración:
          # echo "Procesando JSON: $json_file" >&2

          # Leer datos del JSON, con manejo de errores si el JSON es inválido o faltan campos.
          local image_id=$(jq -r '.Id // "unknown_id"' "$json_file" 2>/dev/null | head -c 12) # ID corto
          local repo_tags_json=$(jq -c '.RepoTags // []' "$json_file" 2>/dev/null) # Array de tags, default a []
          local created_at=$(jq -r '.Created // "unknown_date"' "$json_file" 2>/dev/null)
          local image_disk_size=$(jq -r '.Size // "0B"' "$json_file" 2>/dev/null) # Tamaño del tarball
          local image_name_from_json=$(jq -r '.Image.Name // "unknown_image_name"' "$json_file" 2>/dev/null) # Para obtener el nombre completo desde el JSON

          # Si el JSON es malformado, jq puede fallar y las variables pueden quedar vacías o con "null".
          if [ -z "$image_id" ] || [ "$image_id" == "unknown_id" ]; then
              echo "Advertencia: Archivo JSON malformado o incompleto detectado: $json_file. Saltando." >&2
              continue
          fi
          
          # Asegurarse de que el primary_repo_tag no sea null.
          local primary_repo_tag=$(echo "$repo_tags_json" | jq -r '.[0] // "none" ')
          if [ "$primary_repo_tag" == "none" ]; then # Si no hay tags en RepoTags, usar el nombre de imagen completo
              primary_repo_tag="$image_name_from_json"
          fi
          
          # Añadir la información a la lista para ordenar.
          image_data+=("$created_at|$image_id|$primary_repo_tag|$image_disk_size")

      done # Fin del bucle for sobre $json_files

      # Ordenar por fecha de creación (más reciente primero)
      IFS=$'\n' sorted_images=($(sort -r -t'|' -k1 <<<"${image_data[*]}"))
      unset IFS

      local header_printed=false
      local count=0

      if [ "${#sorted_images[@]}" -eq 0 ]; then
        echo "No hay imágenes válidas para mostrar."
        return 0
      fi

      if ! $SHOW_QUIET; then
        printf "%-14s %-30s %-25s %s\n" "IMAGE ID" "REPOSITORY:TAG" "CREATED" "SIZE"
        echo "----------------------------------------------------------------------------------------------------"
        header_printed=true
      fi

      for img_line in "${sorted_images[@]}"; do
        local created_at_full=$(echo "$img_line" | cut -d'|' -f1)
        local img_id=$(echo "$img_line" | cut -d'|' -f2)
        local repo_tag=$(echo "$img_line" | cut -d'|' -f3)
        local img_size=$(echo "$img_line" | cut -d'|' -f4)
        
        # Formatear la fecha de creación a un formato más corto (ej. "2024-06-30 15:00")
        local created_display=""
        if [ "$created_at_full" != "unknown_date" ]; then
            created_display=$(date -d "$created_at_full" +"%Y-%m-%d %H:%M") 
        else
            created_display="<unknown>"
        fi
        
        if $SHOW_QUIET; then
          echo "$img_id"
        else
          local display_size_col=""
          if $SHOW_SIZE; then display_size_col="$img_size"; else display_size_col="-" ;fi # Mostrar tamaño solo si se pide
          
          printf "%-14s %-30s %-25s %s\n" "$img_id" "$repo_tag" "$created_display" "$display_size_col"
        fi
        count=$((count + 1))
      done
      echo "----------------------------------------------------------------------------------------------------"
      ;;

    rm)
      local FORCE_REMOVE=false
      local IMAGES_TO_REMOVE=()

      # Parseo de opciones para 'rm'
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          -f|--force)
            FORCE_REMOVE=true
            shift
            ;;
          -l|--link)
            echo "Advertencia: La opción '-l' ('--link') no tiene un efecto directo en esta implementación."
            shift
            ;;
          -v|--volume)
            echo "Advertencia: La opción '-v' ('--volume') no tiene un efecto directo en esta implementación."
            shift
            ;;
          -h|--help)
            show_image_help
            return 0
            ;;
          *) # Argumentos restantes son los nombres/IDs de las imágenes
            IMAGES_TO_REMOVE+=("$1")
            shift
            ;;
        esac
      done

      if [ ${#IMAGES_TO_REMOVE[@]} -eq 0 ]; then
        echo "Error: Se debe especificar al menos una imagen para eliminar."
        show_image_help
        return 1
      fi

      for target_image_spec in "${IMAGES_TO_REMOVE[@]}"; do
        local image_metadata_file_path=$(get_image_metadata_path "$target_image_spec")
        
        if [ $? -ne 0 ] || [ ! -f "$image_metadata_file_path" ]; then # Verifica que get_image_metadata_path tuvo éxito
            echo "Error: Imagen '$target_image_spec' no encontrada o no tiene metadatos válidos."
            continue
        fi

        local image_id_full=$(jq -r '.Id' "$image_metadata_file_path" 2>/dev/null) # ID completo de la imagen
        local image_tags_json=$(jq -c '.RepoTags' "$image_metadata_file_path" 2>/dev/null) # Todos los tags
        local primary_repo_tag=$(echo "$image_tags_json" | jq -r '.[0]') # Primer tag para mostrar
        local image_tar_path=$(jq -r '.Paths.ImagePath' "$image_metadata_file_path" 2>/dev/null)
        local image_cached_rootfs_hash=$(jq -r '.VirtualSize' "$image_metadata_file_path" 2>/dev/null) # Usamos VirtualSize para el hash de cache

        echo "Intentando eliminar imagen: '$primary_repo_tag' (ID: ${image_id_full:0:12})"

        # Verificar si hay contenedores activos usando esta imagen.
        echo "Nota: No se verifica si hay contenedores en ejecución usando esta imagen. Usa 'termux-container ps' para verificar."
        if [ "$FORCE_REMOVE" == "true" ]; then
            echo "Forzando eliminación. Se eliminará incluso si hay contenedores (no verificados) que la usan."
        fi

        # Eliminar el archivo tar.gz de la imagen.
        if [ -f "$image_tar_path" ]; then
          rm -f "$image_tar_path"
          if [ $? -eq 0 ]; then
            echo "Archivo de imagen TAR: '$image_tar_path' eliminado."
          else
            echo "Error: No se pudo eliminar el archivo de imagen TAR: '$image_tar_path'."
          fi
        fi

        # Eliminar el archivo de metadatos JSON de la imagen.
        if [ -f "$image_metadata_file_path" ]; then
          rm -f "$image_metadata_file_path"
          if [ $? -eq 0 ]; then
            echo "Metadatos de imagen: '$image_metadata_file_path' eliminados."
          else
            echo "Error: No se pudo eliminar el archivo de metadatos de imagen: '$image_metadata_file_path'."
          fi
        fi

        # Eliminar el caché de capas asociado a esta imagen base (el FROM layer del build).
        # El hash del cache es el VirtualSize del JSON.
        local CACHE_FROM_PATH="$CACHED_IMAGES_DIR/layer-${image_cached_rootfs_hash}" 
        if [ -d "$CACHE_FROM_PATH" ]; then
            echo "Eliminando cache de capa FROM: '$CACHE_FROM_PATH'..."
            rm -rf "$CACHE_FROM_PATH"
        fi
        
        echo "¡Imagen '$primary_repo_tag' procesada para eliminación!"
      done
      ;;

    tag)
      local SOURCE_IMAGE_TAG_SPEC="$1" # e.g., "ubuntu:22.04.3" or "my_app:latest"
      local NEW_TAG_NAME="$2"     # e.g., "ubuntu:latest" or "my_app:v1.0"

      if [ -z "$SOURCE_IMAGE_TAG_SPEC" ] || [ -z "$NEW_TAG_NAME" ]; then
        echo "Error: Uso incorrecto. Uso: image.sh tag <origen>:<tag_origen> <destino>:<tag_destino>"
        show_image_help
        return 1
      fi

      local source_metadata_path=$(get_image_metadata_path "$SOURCE_IMAGE_TAG_SPEC")
      if [ $? -ne 0 ] || [ ! -f "$source_metadata_path" ]; then
        echo "Error: La imagen fuente '${SOURCE_IMAGE_TAG_SPEC}' no se encontró o no tiene metadatos válidos."
        return 1
      fi

      # Extraer información de la imagen fuente desde sus metadatos
      local src_image_id=$(jq -r '.Id' "$source_metadata_path")
      local src_image_tar_path=$(jq -r '.Paths.ImagePath' "$source_metadata_path")

      # Parsear el nuevo tag
      local new_repo_name=$(echo "$NEW_TAG_NAME" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
      local new_tag_version=$(echo "$NEW_TAG_NAME" | cut -d':' -f2)
      if [ -z "$new_tag_version" ]; then new_tag_version="latest"; fi # Default tag if not specified

      local new_image_filename="${new_repo_name}-${new_tag_version}.tar.gz" # El archivo .tar.gz para el nuevo tag
      local new_image_path="${DOWNLOAD_IMAGES_DIR}/$new_image_filename"
      local new_metadata_path="${DOWNLOAD_IMAGES_DIR}/${new_repo_name}-${new_tag_version}.json" # El archivo .json para el nuevo tag

      # Validar que la nueva etiqueta no cambie el nombre del repositorio principal si no es un "tag" puro.
      local current_primary_repo=$(echo "$SOURCE_IMAGE_TAG_SPEC" | cut -d':' -f1)
      if [ "$current_primary_repo" != "$new_repo_name" ]; then
          echo "Error: Actualmente, el comando 'tag' solo permite cambiar la etiqueta de una imagen, no su nombre de repositorio. ('$current_primary_repo' vs '$new_repo_name')"
          return 1
      fi

      if [ -f "$new_image_path" ] || [ -f "$new_metadata_path" ]; then
        echo "Advertencia: La imagen con el nuevo tag '${NEW_TAG_NAME}' ya existe y será sobrescrita."
        # Opcional: preguntar al usuario antes de sobrescribir, o usar una opción -f.
      fi

      echo "Etiquetando imagen de '${SOURCE_IMAGE_TAG_SPEC}' a '${NEW_TAG_NAME}'..."
      
      # 1. Copiar el archivo tar.gz (si el nuevo tag es un nombre de archivo diferente)
      # Esto solo ocurre si la versión del tag cambia.
      if [ "$src_image_tar_path" != "$new_image_path" ]; then
        cp "$src_image_tar_path" "$new_image_path" || { echo "Error: Falló la copia del archivo TAR.GZ."; return 1; }
      fi

      # 2. Modificar los metadatos JSON para el nuevo tag.
      # Leemos los metadatos de origen, añadimos el nuevo tag a RepoTags y actualizamos la fecha de creación.
      jq --arg new_tag "$NEW_TAG_NAME" \
         --arg current_timestamp "$(date -u +%Y-%m-%dT%H:%M:%S.%N%z)" \
         '.RepoTags += [$new_tag] | .Created = $current_timestamp' \
         "$source_metadata_path" > "$new_metadata_path.tmp" && mv "$new_metadata_path.tmp" "$new_metadata_path" || { echo "Error: Falló al modificar o copiar los metadatos JSON."; rm -f "$new_image_path"; return 1; }
      
      echo "¡Imagen etiquetada con éxito! Nueva referencia: '$NEW_TAG_NAME'."
      ;;
    *)
      echo "Error: Comando desconocido para 'image': $subcommand"
      show_image_help
      return 1
      ;;
  esac
}

# Llama a la función principal con todos los argumentos pasados al script.
main_image_logic "$@"