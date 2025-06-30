#!/data/data/com.termux/files/usr/bin/bash

# Este script se encarga de descargar imágenes oficiales de distribuciones.
# Funciona como una librería de funciones si es 'sourced', o como un script independiente si se llama directamente.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh" # Ruta al script de utilidades.
METADATA_SCRIPT_PULL="$SCRIPT_DIR/metadata.sh" # Ruta al script de metadatos.

# Cargar utils.sh (para command_exists)
if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. La funcionalidad de descarga podría ser imprecisa." >&2
  exit 1
fi

# Cargar metadata.sh si está disponible (para generate_container_metadata)
if [ -f "$METADATA_SCRIPT_PULL" ]; then
  . "$METADATA_SCRIPT_PULL" 
  if ! command_exists generate_container_metadata; then
      echo "Error: La función 'generate_container_metadata' no se cargó correctamente desde '$METADATA_SCRIPT_PULL'." >&2
      echo "Asegúrate de que 'metadata.sh' sea un script de Bash válido y tenga permisos." >&2
      # No salimos aquí, ya que pull.sh aún puede descargar el tar.gz, solo no generará metadatos.
  fi
else
  echo "Advertencia: metadata.sh no encontrado en '$METADATA_SCRIPT_PULL'. No se generarán metadatos para la imagen descargada." >&2
fi


# --- Variables de Configuración Global ---
DOWNLOAD_BASE_DIR="$HOME/.termux-container"
DOWNLOAD_IMAGES_DIR="$DOWNLOAD_BASE_DIR/images"

# --- Funciones de Descarga de Imágenes ---

# Función para determinar y mapear la arquitectura del sistema.
get_mapped_architecture() { # Esta función ya no necesita 'command_exists' aquí si utils.sh se carga.
  local termux_arch=$(dpkg --print-architecture)
  local mapped_arch=""

  case "$termux_arch" in
    aarch64) mapped_arch="arm64";; # Mapea a 'arm64' para Ubuntu, 'aarch64' para Alpine
    arm) mapped_arch="armhf";;    # Para ARM de 32 bits
    amd64|x86_64) mapped_arch="amd64";; # Para emulación x86_64 o dispositivos compatibles
    *)
      echo "Error: Arquitectura '$termux_arch' no soportada para descarga de imágenes." >&2
      return 1
      ;;
  esac
  echo "$mapped_arch"
}

# Función auxiliar para obtener el tamaño de un archivo tar.gz
get_container_size_from_tar() { # Necesaria para metadatos de imagen
    local tar_path="$1"
    if [ -f "$tar_path" ]; then
        du -h "$tar_path" | awk '{print $1}'
    else
        echo "0B"
    fi
}

# Función auxiliar para obtener la última versión de Alpine (solo para Alpine).
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
    echo "Considere especificar la versión explícitamente (ej: alpine:3.22.0)."
    latest_version="3.20" 
  fi
  echo "$latest_version"
}

# Función principal para descargar imágenes oficiales.
download_image() {
  local distribution_name_arg="$1" 
  local image_version_arg="$2"     
  local target_arch_arg="$3"       

  echo "--- Descargando Imagen ${distribution_name_arg^} ---"

  # Determinar la versión si no se proporciona (solo para Alpine)
  if [ -z "$image_version_arg" ]; then
    echo "No se especificó la versión. Intentando obtener la última versión estable de ${distribution_name_arg^}..."
    if [ "$distribution_name_arg" == "alpine" ]; then
      image_version_arg=$(get_latest_alpine_version)
      if [ -z "$image_version_arg" ]; then
        echo "Error: No se pudo determinar la última versión de Alpine y no se especificó. Abortando descarga."
        return 1 
      fi
      echo "Última versión de Alpine detectada: ${image_version_arg}"
    else
      echo "Error: La detección automática de la última versión no está implementada para ${distribution_name_arg^}. Por favor, especifica la versión (ej: ${distribution_name_arg}:22.04.3)."
      return 1 
    fi
  fi

  # Determinar la arquitectura de la máquina Termux
  local current_host_arch=$(get_mapped_architecture)
  if [ $? -ne 0 ]; then
    echo "$current_host_arch" 
    return 1
  fi
  
  local download_arch="${target_arch_arg:-$current_host_arch}" 

  echo "Arquitectura detectada para descarga: $download_arch"

  # Verificar dependencias esenciales para la descarga
  echo "Verificando dependencias..."
  if ! command_exists wget; then # Usa command_exists de utils.sh
    echo "Error: 'wget' no está instalado. Por favor, instálalo con 'pkg install wget'."
    return 1
  fi
  echo "'wget' detectado."

  local DOWNLOAD_URL=""
  local LOCAL_IMAGE_FILENAME=""

  # Lógica específica para construir la URL de descarga y el nombre del archivo local.
  case "$distribution_name_arg" in
    alpine)
      local ALPINE_ARCH_FOR_URL="aarch64"
      if [ "$download_arch" == "arm64" ]; then 
          ALPINE_ARCH_FOR_URL="aarch64"
      elif [ "$download_arch" == "amd64" ]; then
          ALPINE_ARCH_FOR_URL="x86_64" 
      elif [ "$download_arch" == "armhf" ]; then
          ALPINE_ARCH_FOR_URL="armhf" 
      else
          echo "Error: Arquitectura '$download_arch' no compatible con las URLs de Alpine."
          return 1
      fi

      local ALPINE_MAJOR_MINOR_VERSION=$(echo "$image_version_arg" | cut -d'.' -f1-2)
      DOWNLOAD_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MAJOR_MINOR_VERSION}/releases/${ALPINE_ARCH_FOR_URL}/alpine-minirootfs-${image_version_arg}-${ALPINE_ARCH_FOR_URL}.tar.gz"
      LOCAL_IMAGE_FILENAME="${distribution_name_arg}-${image_version_arg}.tar.gz"
      ;;
    ubuntu)
      # URL de Ubuntu Oficial (para Ubuntu 22.04.3 LTS base)
      # Ejemplo: http://cdimage.ubuntu.com/ubuntu-base/releases/22.04.3/release/ubuntu-base-22.04.3-base-arm64.tar.gz
      
      local UBUNTU_ARCH_FOR_URL=""
      if [ "$download_arch" == "arm64" ]; then
          UBUNTU_ARCH_FOR_URL="arm64"
      elif [ "$download_arch" == "amd64" ]; then
          UBUNTU_ARCH_FOR_URL="amd64"
      elif [ "$download_arch" == "armhf" ]; then
          UBUNTU_ARCH_FOR_URL="armhf" 
      else
          echo "Error: Ubuntu no está disponible para la arquitectura '$download_arch'."
          return 1
      fi

      local UBUNTU_VERSION_IN_URL="${image_version_arg}" 
      
      DOWNLOAD_URL="http://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_VERSION_IN_URL}/release/ubuntu-base-${image_version_arg}-base-${UBUNTU_ARCH_FOR_URL}.tar.gz"
      LOCAL_IMAGE_FILENAME="ubuntu-${image_version_arg}.tar.gz"
      ;;
    *)
      echo "Error interno: La distribución '$distribution_name_arg' no tiene una lógica de descarga definida."
      return 1 
      ;;
  esac 

  local IMAGE_PATH="$DOWNLOAD_IMAGES_DIR/$LOCAL_IMAGE_FILENAME"

  # Crear los directorios de almacenamiento si no existen.
  if [ ! -d "$DOWNLOAD_BASE_DIR" ]; then
    echo "Creando directorio base: $DOWNLOAD_BASE_DIR"
    mkdir -p "$DOWNLOAD_BASE_DIR"
  fi
  if [ ! -d "$DOWNLOAD_IMAGES_DIR" ]; then
    echo "Creando directorio de imágenes: $DOWNLOAD_IMAGES_DIR"
    mkdir -p "$DOWNLOAD_IMAGES_DIR"
  else
    echo "El directorio de imágenes ya existe: $DOWNLOAD_IMAGES_DIR"
  fi

  # Descargar la imagen si no existe localmente.
  echo "Intentando descargar la imagen de ${distribution_name_arg^} (versión ${image_version_arg}, arquitectura ${download_arch})..."
  echo "URL de descarga: $DOWNLOAD_URL"

  if [ -f "$IMAGE_PATH" ]; then
    echo "La imagen '$LOCAL_IMAGE_FILENAME' ya existe en '$DOWNLOAD_IMAGES_DIR'. Saltando la descarga."
  else
    wget -O "$IMAGE_PATH" "$DOWNLOAD_URL"
    if [ $? -eq 0 ]; then
      echo "¡Descarga completada con éxito! Imagen guardada en: $IMAGE_PATH"
      # --- Generar Metadatos para la imagen descargada ---
      # Necesita cargar scripts/metadata.sh para usar generate_container_metadata.
      # Esta lógica se ejecuta si pull.sh es llamado directamente o si run.sh lo llama.
      local METADATA_SCRIPT_PULL_PULL="$SCRIPT_DIR/metadata.sh" # Corregido: Variable distinta
      if [ -f "$METADATA_SCRIPT_PULL" ]; then
        . "$METADATA_SCRIPT_PULL" # Carga metadata.sh si pull.sh se ejecuta directamente.
        if ! command_exists generate_container_metadata; then # Usa command_exists de utils.sh
          echo "Advertencia: generate_container_metadata no disponible en pull.sh. Metadatos de descarga no generados." >&2
        else
          local REPO_TAG_FOR_META="${distribution_name_arg}:${image_version_arg}"
          # No tenemos el rootfs para el VirtualSize aquí, lo dejamos como "unknown".
          # No tenemos el Cmd para la imagen descargada, será "null".
          # Mounts y Env también serán null/empty.
          generate_container_metadata \
            "$distribution_name_arg-$image_version_arg" \
            "$REPO_TAG_FOR_META" \
            "$distribution_name_arg" \
            "$image_version_arg" \
            "$IMAGE_PATH" \
            "unknown" \
            "false" "false" \
            "null" "[]" "[]" # Valores predeterminados para el JSON
          echo "Metadatos de la imagen descargada guardados en: $IMAGE_METADATA_FILE"
        fi
      else
        echo "Advertencia: metadata.sh no encontrado en '$METADATA_SCRIPT_PULL'. No se generarán metadatos para la imagen descargada." >&2
      fi
      # --- Fin de Generación de Metadatos ---
    else
      echo "Error: Falló la descarga de la imagen de ${distribution_name_arg^}. Asegúrate de que la versión '$image_version_arg' exista para la arquitectura '$download_arch' y que la URL '$DOWNLOAD_URL' sea correcta."
      return 1
    fi
  fi

  echo "--- Proceso de descarga finalizado ---"
  return 0 
}

# --- Lógica de Ejecución Principal (si pull.sh se llama directamente) ---
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_pull_logic() {
      show_help() {
        echo "Uso: pull.sh <imagen>[:<version>]"
        echo ""
        echo "Descarga una imagen de contenedor desde su fuente oficial."
        echo "Si la versión no se especifica, se intenta descargar la última versión estable (solo para Alpine)."
        echo "Ejemplos:"
        echo "  pull.sh alpine:3.22.0"
        echo "  pull.sh alpine       (Descarga la última versión estable de Alpine)"
        echo "  pull.sh ubuntu:22.04.3 (Descarga Ubuntu 22.04.3 LTS para tu arquitectura)"
      }

      if [ -z "$1" ]; then
        show_help
        return 0
      fi

      local distribution_name_cli
      local image_version_cli

      IFS=':' read -r distribution_name_cli image_version_cli <<< "$1"

      if [ -z "$distribution_name_cli" ]; then
          echo "Error: Formato de imagen incorrecto. Use 'distribucion:version' o 'distribucion'."
          show_help
          return 1
      fi

      # Manejo de versiones: solo Alpine puede no especificar versión.
      if [ -z "$image_version_cli" ] && [[ "$1" == *":"* ]]; then
          echo "Error: Si usa ':', debe especificar una versión completa. Ej: ubuntu:22.04.3"
          show_help
          return 1
      fi
      
      if [ -z "$image_version_cli" ] && [[ "$1" != *":"* ]]; then
          if [ "$distribution_name_cli" != "alpine" ]; then
            echo "Error: La versión debe ser especificada para la distribución '$distribution_name_cli'. Ej: $distribution_name_cli:22.04.3"
            show_help
            return 1
          fi
          image_version_cli="" # Para Alpine, buscará la última.
      fi

      distribution_name_cli=$(echo "$distribution_name_cli" | tr '[:upper:]' '[:lower:]')

      # Llamamos a la función download_image con los argumentos parseados de la CLI
      case "$distribution_name_cli" in
        alpine|ubuntu) # Ahora soporta Ubuntu
          download_image "$distribution_name_cli" "$image_version_cli" "" # Pasa "" para que use la arch detectada
          ;;
        *)
          echo "Error: Distribución '$distribution_name_cli' no soportada actualmente para descarga. Soportadas: alpine, ubuntu."
          show_help
          return 1
          ;;
      esac
    }
    main_pull_logic "$@" # Llama a la función si el script es ejecutado directamente.
fi