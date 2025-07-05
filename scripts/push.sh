#!/data/data/com.termux/files/usr/bin/bash

# Este script sube una imagen local (.tar.gz y .json) a un repositorio SFTP via un backend HTTP.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh"
METADATA_SCRIPT="$SCRIPT_DIR/metadata.sh" # Para metadatos de imagen

if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. Funcionalidad de push limitada." >&2
  exit 1
fi

if [ ! -f "$METADATA_SCRIPT" ]; then
  echo "Error crítico: metadata.sh no encontrado en '$METADATA_SCRIPT'. No se pueden gestionar metadatos." >&2
  exit 1
fi
. "$METADATA_SCRIPT"


# --- Variables de Configuración Global ---
PROOBOX_BASE_DIR="$HOME/.proobox"
IMAGES_DIR="$PROOBOX_BASE_DIR/images"
REPO_CONFIG_FILE="$PROOBOX_BASE_DIR/config.json" # Ruta al archivo de configuración del repo


# --- Lógica Principal del Script push.sh ---
main_push_logic() {
  local IMAGE_TAG_TO_PUSH="$1"

  show_push_help() {
    echo "Uso: push.sh <nombre_de_la_imagen>[:<etiqueta>]"
    echo ""
    echo "Sube una imagen local (su .tar.gz y sus metadatos .json) a un repositorio SFTP via un backend HTTP."
    echo "Configura la URL del backend en: $REPO_CONFIG_FILE bajo 'backend.url'."
    echo "Requiere el backend de Node.js/SFTP corriendo en el servidor."
    echo ""
    echo "Ejemplos:"
    echo "  ./proobox push my_custom_app:latest"
  }

  if [ -z "$IMAGE_TAG_TO_PUSH" ]; then
    echo "Error: Se debe especificar el nombre de la imagen a subir." >&2
    show_push_help
    return 1
  fi

  if ! command_exists curl; then
    echo "Error: 'curl' no está instalado. Por favor, instálalo con 'pkg install curl'." >&2
    return 1
  fi

  # 1. Leer configuración del backend
  if [ ! -f "$REPO_CONFIG_FILE" ]; then
    echo "Error: Archivo de configuración del repositorio no encontrado: '$REPO_CONFIG_FILE'." >&2
    echo "Por favor, crea este archivo con el formato JSON esperado (ej. para backend.url)." >&2
    return 1
  fi

  local BACKEND_URL=$(jq -r '.backend.url' "$REPO_CONFIG_FILE" 2>/dev/null) # URL del backend, ej: "http://192.168.100.201:3000"
  if [ -z "$BACKEND_URL" ] || [ "$BACKEND_URL" == "null" ]; then
    echo "Error: URL del backend no configurada en '$REPO_CONFIG_FILE' bajo 'backend.url'." >&2
    return 1
  fi

  echo "Backend configurado para SFTP: $BACKEND_URL"

  # 2. Localizar archivos de imagen y metadatos
  local parsed_dist_name=$(echo "$IMAGE_TAG_TO_PUSH" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  local parsed_image_version=$(echo "$IMAGE_TAG_TO_PUSH" | cut -d':' -f2)
  if [ -z "$parsed_image_version" ]; then parsed_image_version="latest"; fi

  if ! type -t normalize_image_version &>/dev/null; then
    echo "Error crítico: La función 'normalize_image_version' no está disponible. Verifique 'utils.sh'." >&2
    return 1
  fi

  local IMAGE_TAR_FILENAME="${parsed_dist_name}-$(normalize_image_version "$parsed_image_version").tar.gz"
  local IMAGE_JSON_FILENAME="${parsed_dist_name}-$(normalize_image_version "$parsed_image_version").json"

  local LOCAL_TAR_PATH="${IMAGES_DIR}/$IMAGE_TAR_FILENAME"
  local LOCAL_JSON_PATH="${IMAGES_DIR}/$IMAGE_JSON_FILENAME"

  if [ ! -f "$LOCAL_TAR_PATH" ] || [ ! -f "$LOCAL_JSON_PATH" ]; then
    echo "Error: La imagen '$IMAGE_TAG_TO_PUSH' (o sus metadatos) no se encontró localmente." >&2
    echo "Asegúrate de haberla descargado o compilado." >&2
    return 1
  fi

  # 3. Subir archivos al backend (que los subirá a SFTP)
  echo "--- Subiendo imagen '$IMAGE_TAG_TO_PUSH' al backend SFTP ---"

  local UPLOAD_SUCCESS=0

  # Subir el archivo TAR.GZ
  echo "Subiendo: $LOCAL_TAR_PATH al backend..."
  # Usar -F para multipart/form-data, 'imageFile' debe coincidir con upload.single('imageFile') en el backend
  curl -s -X POST \
       -F "imageFile=@$LOCAL_TAR_PATH" \
       "${BACKEND_URL}/images/upload" # Endpoint de subida
  if [ $? -ne 0 ]; then
    echo "Error: Falló la subida del archivo TAR.GZ al backend." >&2
    UPLOAD_SUCCESS=1
  fi

  # Subir el archivo JSON
  if [ "$UPLOAD_SUCCESS" -eq 0 ]; then
      echo "Subiendo: $LOCAL_JSON_PATH al backend..."
      curl -s -X POST \
           -F "imageFile=@$LOCAL_JSON_PATH" \
           "${BACKEND_URL}/images/upload" # Mismo endpoint de subida
      if [ $? -ne 0 ]; then
        echo "Error: Falló la subida del archivo JSON al backend." >&2
        UPLOAD_SUCCESS=1
      fi
  fi

  if [ "$UPLOAD_SUCCESS" -eq 0 ]; then
    echo "¡Imagen '$IMAGE_TAG_TO_PUSH' subida con éxito al repositorio SFTP (via backend)!"
  else
    echo "Error: Falló la subida completa de la imagen al repositorio SFTP." >&2
    return 1
  fi

  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_push_logic "$@"
fi