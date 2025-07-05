#!/data/data/com.termux/files/usr/bin/bash

# Este script se encarga de descargar imágenes oficiales de distribuciones o desde un repositorio SFTP via backend HTTP.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh"
METADATA_SCRIPT_PULL="$SCRIPT_DIR/metadata.sh"

if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. La funcionalidad de descarga podría ser imprecisa." >&2
  exit 1
fi

if [ -f "$METADATA_SCRIPT_PULL" ]; then
  . "$METADATA_SCRIPT_PULL"
else
  echo "Error crítico: metadata.sh no encontrado en '$METADATA_SCRIPT_PULL'. No se generarán metadatos para la imagen descargada." >&2
  exit 1
fi


# --- Variables de Configuración Global ---
DOWNLOAD_BASE_DIR="$HOME/.proobox"
DOWNLOAD_IMAGES_DIR="$DOWNLOAD_BASE_DIR/images"
REPO_CONFIG_FILE="$PROOBOX_BASE_DIR/config.json"


# --- Funciones de Descarga de Imágenes ---

# Determina y mapea la arquitectura del sistema.
get_mapped_architecture() {
  local termux_arch=$(dpkg --print-architecture)
  case "$termux_arch" in
    aarch64) echo "arm64";;
    arm) echo "armhf";;
    amd64|x86_64) echo "amd64";;
    *) echo "Error: Arquitectura '$termux_arch' no soportada para descarga de imágenes." >&2; return 1;;
  esac
}

# Obtiene la última versión estable de Alpine desde su CDN.
get_latest_alpine_version() {
  local latest_version=""
  local release_url="https://dl-cdn.alpinelinux.org/alpine/releases/"

  latest_version=$(wget -qO- "$release_url" 2>/dev/null | \
                   grep -oE 'v[0-9]+\.[0-9]+/' | \
                   sort -V | \
                   tail -n 1 | \
                   sed 's/v//;s/\///')

  if [ -z "$latest_version" ]; then
    echo "Advertencia: No se pudo determinar la última versión de Alpine desde $release_url. Usando 3.20 como fallback."
    latest_version="3.20"
  fi
  echo "$latest_version"
}

# Función para normalizar la cadena de versión (ej. "1" -> "1.0.0", "2.5" -> "2.5.0").
normalize_image_version() {
  local version_str="$1"
  if [ -z "$version_str" ]; then echo ""; return; fi
  if [[ "$version_str" =~ ^[0-9]+$ ]]; then echo "${version_str}.0.0"; return; fi
  if [[ "$version_str" =~ ^[0-9]+\.[0-9]+$ ]]; then echo "${version_str}.0"; return; fi
  echo "$version_str"
}

# Función principal para descargar imágenes.
# Retorna 0 si la descarga fue exitosa, 1 si falló.
download_image() {
  local distribution_name_arg="$1"
  local image_version_arg="$2"
  local target_arch_arg="$3"


  distribution_name_arg=$(echo "$distribution_name_arg" | tr '[:upper:]' '[:lower:]')

  echo "--- Descargando Imagen ${distribution_name_arg^} ---"

  if [ -z "$image_version_arg" ]; then
    if [ "$distribution_name_arg" == "alpine" ]; then
      image_version_arg=$(get_latest_alpine_version)
      if [ -z "$image_version_arg" ]; then
        echo "Error: No se pudo determinar la última versión de Alpine. Abortando descarga." >&2
        return 1
      fi
    elif [ "$distribution_name_arg" == "ubuntu" ]; then
        echo "Error: La versión debe especificarse para ${distribution_name_arg^}. Ej: ${distribution_name_arg}:22.04.3." >&2
        return 1
    else
        echo "Error: No se puede determinar la última versión para '${distribution_name_arg}'. Por favor, especifica la versión." >&2
        return 1
    fi
  fi

  local normalized_image_version="$image_version_arg"
  if [[ "$normalized_image_version" =~ ^[0-9]+$ ]]; then
      normalized_image_version="${normalized_image_version}.0.0"
  elif [[ "$normalized_image_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
      normalized_image_version="${normalized_image_version}.0"
  fi
  image_version_arg="$normalized_image_version"


  local current_host_arch=$(get_mapped_architecture)
  if [ $? -ne 0 ]; then echo "$current_host_arch"; return 1; fi
  local download_arch="${target_arch_arg:-$current_host_arch}"
  echo "Arquitectura detectada para descarga: $download_arch"

  if ! command_exists wget; then
    echo "Error: 'wget' no está instalado. Por favor, instálalo con 'pkg install wget'." >&2
    return 1
  fi

  # Rutas de archivos locales
  local LOCAL_IMAGE_TAR_FILENAME="${distribution_name_arg}-${image_version_arg}.tar.gz"
  echo "Archivo TAR local: $LOCAL_IMAGE_TAR_FILENAME"
  local LOCAL_IMAGE_JSON_FILENAME="${distribution_name_arg}-${image_version_arg}.json"
  local LOCAL_TAR_PATH="$DOWNLOAD_IMAGES_DIR/$LOCAL_IMAGE_TAR_FILENAME"
  local LOCAL_JSON_PATH="$DOWNLOAD_IMAGES_DIR/$LOCAL_IMAGE_JSON_FILENAME"

  mkdir -p "$DOWNLOAD_IMAGES_DIR"

  # Si la imagen ya existe localmente (TAR y JSON válidos), saltar la descarga.
  if [ -f "$LOCAL_TAR_PATH" ] && [ -f "$LOCAL_JSON_PATH" ]; then
      echo "La imagen '$LOCAL_IMAGE_TAR_FILENAME' ya existe en '$DOWNLOAD_IMAGES_DIR'. Saltando la descarga."
      return 0
  fi

  local DOWNLOAD_FINAL_STATUS=1 # 0 para éxito, 1 para fallo

  # --- OBTENER CONFIGURACIÓN DEL BACKEND PARA PULL ---
  local BACKEND_URL=""
  if [ -f "$REPO_CONFIG_FILE" ]; then
      BACKEND_URL=$(jq -r '.backend.url' "$REPO_CONFIG_FILE" 2>/dev/null)
  fi

  # --- Intentar descargar desde el Backend (SFTP vía HTTP) ---
  if [ -n "$BACKEND_URL" ] && [ "$BACKEND_URL" != "null" ]; then
    # Construir la ruta del objeto en el servidor SFTP (ej: "alpine/alpine-3.22.0.tar.gz")
    local SFTP_OBJECT_TAR_PATH="${distribution_name_arg}-${image_version_arg}.tar.gz"
    local SFTP_OBJECT_JSON_PATH="${distribution_name_arg}/${LOCAL_IMAGE_JSON_FILENAME}"

    local username_path=$(echo "$(echo "$1" | cut -d':' -f1)" | cut -d'/' -f1)
    local image_name=$(echo "$(echo "$1" | cut -d':' -f1)" | cut -d'/' -f2)

    echo "aaaaa/$username_path/$image_name/$image_version_arg/$image_name-$image_version_arg.tar.gz"
    local repository_tar_path="proobox/$username_path/$image_name/$image_version_arg/$image_name-$image_version_arg.tar.gz"
    local repository_json_path="proobox/$username_path/$image_name/$image_version_arg/$image_name-$image_version_arg.json"


    # Construir la URL de descarga del backend
    local DOWNLOAD_BACKEND_URL_TAR="${BACKEND_URL}/api/download/${repository_tar_path}"
    local DOWNLOAD_BACKEND_URL_JSON="${BACKEND_URL}/api/download/${repository_json_path}"


    echo "Intentando descargar de backend SFTP: $DOWNLOAD_BACKEND_URL_TAR"
    echo "$LOCAL_TAR_PATH" "$LOCAL_JSON_PATH"
    # mkdir -p "$LOCAL_TAR_PATH"
    # mkdir -p "$LOCAL_JSON_PATH"
    wget -O "$LOCAL_TAR_PATH" "$DOWNLOAD_BACKEND_URL_TAR"
    if [ $? -eq 0 ]; then
      echo "Imagen TAR descargada de backend SFTP."
      wget -O "$LOCAL_JSON_PATH" "$DOWNLOAD_BACKEND_URL_JSON" # Intentar descargar JSON
      if [ $? -ne 0 ]; then
        echo "Advertencia: Metadatos JSON no encontrados o falló descarga de backend SFTP. Se generarán metadatos básicos." >&2
        local REPO_TAG_FOR_META="[\"${distribution_name_arg}:${image_version_arg}\"]"
        local IMAGE_ID_FOR_META="$(md5sum "$LOCAL_TAR_PATH" | awk '{print $1}' 2>/dev/null)"
        if [ -z "$IMAGE_ID_FOR_META" ]; then IMAGE_ID_FOR_META="unknown_id"; fi # Fallback
        generate_image_metadata \
          "$IMAGE_ID_FOR_META" "$REPO_TAG_FOR_META" "$LOCAL_TAR_PATH" "unknown" "null" "/root" "[]"
        if [ $? -ne 0 ]; then echo "ERROR: generate_image_metadata falló al generar metadatos básicos después de descarga de backend SFTP." >&2; rm -f "$LOCAL_JSON_PATH"; fi
      else
        echo "Metadatos JSON descargados de backend SFTP."
      fi
      echo "--- Descarga completada desde backend SFTP ---"
      DOWNLOAD_FINAL_STATUS=0 # Éxito desde backend SFTP
    else
      echo "No se pudo descargar la imagen TAR.GZ de backend SFTP. Intentando fuentes oficiales..."
    fi
  fi

  # --- Descargar desde fuentes oficiales (si la descarga desde backend no fue exitosa) ---
  if [ "$DOWNLOAD_FINAL_STATUS" -ne 0 ]; then # Solo si la descarga remota/MinIO/SFTP no tuvo éxito
    local OFFICIAL_DOWNLOAD_URL=""
    case "$distribution_name_arg" in
      alpine)
        local ALPINE_MAJOR_MINOR=$(echo "$image_version_arg" | cut -d'.' -f1-2)
        local ALPINE_ARCH_FOR_URL="aarch64"
        if [ "$download_arch" == "arm64" ]; then ALPINE_ARCH_FOR_URL="aarch64"; elif [ "$download_arch" == "amd64" ]; then ALPINE_ARCH_FOR_URL="x86_64"; elif [ "$download_arch" == "armhf" ]; then ALPINE_ARCH_FOR_URL="armhf"; else echo "Error: Arch '$download_arch' no compatible con Alpine."; return 1; fi
        OFFICIAL_DOWNLOAD_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR_MINOR}/releases/${ALPINE_ARCH_FOR_URL}/alpine-minirootfs-${image_version_arg}-${ALPINE_ARCH_FOR_URL}.tar.gz"
        ;;
      ubuntu)
        local UBUNTU_ARCH_FOR_URL=""
        if [ "$download_arch" == "arm64" ]; then UBUNTU_ARCH_FOR_URL="arm64"; elif [ "$download_arch" == "amd64" ]; then UBUNTU_ARCH_FOR_URL="amd64"; elif [ "$download_arch" == "armhf" ]; then UBUNTU_ARCH_FOR_URL="armhf"; else echo "Error: Arch '$download_arch' no compatible con Ubuntu."; return 1; fi
        OFFICIAL_DOWNLOAD_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/${image_version_arg}/release/ubuntu-base-${image_version_arg}-base-${UBUNTU_ARCH_FOR_URL}.tar.gz"
        ;;
      *)
        echo "Error interno: La distribución '$distribution_name_arg' no tiene una lógica de descarga definida." >&2
        return 1
        ;;
    esac 

    echo "Intentando descargar la imagen de ${distribution_name_arg^} (versión ${image_version_arg}, arquitectura ${download_arch}) desde fuentes oficiales..."
    echo "URL de descarga: $OFFICIAL_DOWNLOAD_URL"

    wget -O "$LOCAL_TAR_PATH" "$OFFICIAL_DOWNLOAD_URL"
    if [ $? -eq 0 ]; then
      echo "¡Descarga completada con éxito! Imagen guardada en: $LOCAL_TAR_PATH"
      local REPO_TAG_FOR_META="[\"${distribution_name_arg}:${image_version_arg}\"]" # Array JSON
      local IMAGE_ID_FOR_META="$(md5sum "$LOCAL_TAR_PATH" | awk '{print $1}' 2>/dev/null)"
      if [ -z "$IMAGE_ID_FOR_META" ]; then IMAGE_ID_FOR_META="unknown_id"; fi # Fallback

      generate_image_metadata \
        "$IMAGE_ID_FOR_META" \
        "$REPO_TAG_FOR_META" \
        "$LOCAL_TAR_PATH" \
        "unknown" \
        "null" "/root" "[]" # Default values for CMD, WorkDir, ENV
      echo "Metadatos de la imagen descargada guardados en: $LOCAL_JSON_PATH"
      echo "--- Proceso de descarga finalizado ---"
      DOWNLOAD_FINAL_STATUS=0 # Éxito desde oficial
    else
      echo "Error: Falló la descarga de la imagen de ${distribution_name_arg^}. Asegúrate de que la versión '$image_version_arg' exista para la arquitectura '$download_arch' y que la URL '$OFFICIAL_DOWNLOAD_URL' sea correcta." >&2
      DOWNLOAD_FINAL_STATUS=1 # Fallo total
    fi
  fi

  return "$DOWNLOAD_FINAL_STATUS" # Retorna el estado final
}

# Lógica principal si pull.sh se llama directamente
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_pull_logic() {
      show_help() {
        echo "Uso: pull.sh <imagen>[:<version>]"
        echo ""
        echo "Descarga una imagen de contenedor desde su repositorio remoto o fuentes oficiales."
        echo "Si la versión no se especifica, se intenta descargar la última versión estable (solo para Alpine)."
        echo "Ejemplos:"
        echo "  ./proobox pull alpine:3.22.0"
        echo "  ./proobox pull ubuntu:22.04.3"
        echo "  ./proobox pull my_custom_image:latest" # Si estaba configurado el remoto.
      }

      if [ -z "$1" ]; then show_help; return 0; fi
      echo "Descargando imagen: $1"
      local distribution_name_cli=$(echo "$1" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')

      echo "Distribución: $distribution_name_cli $(echo "$1" | cut -d'/' -f2)"
      local image_version_cli=$(echo "$1" | cut -d':' -f2)
      if [ -z "$image_version_cli" ] && [[ "$1" == *":"* ]]; then
          echo "Error: Si usa ':', debe especificar una versión completa. Ej: ubuntu:22.04.3" >&2
          show_help
          return 1
      fi
      if [ -z "$image_version_cli" ] && [ "$distribution_name_cli" != "alpine" ]; then
          echo "Error: La versión debe ser especificada para la distribución '$distribution_name_cli'. Ej: $distribution_name_cli:22.04.3" >&2
          show_help
          return 1
      fi
      if [ -z "$image_version_cli" ] && [ "$distribution_name_cli" == "alpine" ]; then
          image_version_cli="" # La función lo detectará.
      fi

      download_image "$distribution_name_cli" "$image_version_cli" "" # Pasa "" para que use la arch detectada
      return $? # Retorna el código de salida de download_image
    }
    main_pull_logic "$@"
fi