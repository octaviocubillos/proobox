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
    echo "Sube una imagen local (su .tar.gz y sus metadatos .json) a un repositorio SFTP via un backend HTTP (un solo POST)."
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
  local USERNAME=$(jq -r '.backend.username' "$REPO_CONFIG_FILE" 2>/dev/null) # Usuario SFTP del backend, para la URL
  local JWT_TOKEN=$(jq -r '.backend.token' "$REPO_CONFIG_FILE" 2>/dev/null) # Usuario SFTP del backend, para la URL
  
  if [ -z "$BACKEND_URL" ] || [ "$BACKEND_URL" == "null" ]; then
    echo "Error: Configuración del backend o usuario SFTP incompleta en '$REPO_CONFIG_FILE'." >&2
    echo "Asegúrate de que 'backend.url' y 'sftp.username' estén definidos." >&2
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

  # 3. Construir la URL del endpoint de subida
  # Nueva URL: http://localhost:3000/api/upload/proobox/{sftpUser}/{imageName}/{imageVersion}
  local UPLOAD_ENDPOINT="${BACKEND_URL}/api/upload/proobox/${USERNAME}/${parsed_dist_name}/${parsed_image_version}"
  # local UPLOAD_ENDPOINT="${BACKEND_URL}/api/upload/proobox/${parsed_image_version}"
  echo "Endpoint de subida: $UPLOAD_ENDPOINT"

  # 4. Subir ambos archivos en una sola llamada curl
  echo "--- Subiendo imagen y metadatos en un solo POST ---"

  # -F "imageFile=@/path/to/image.tar.gz"
  # -F "metadataFile=@/path/to/metadata.json"

  echo "Subiendo imagen y metadatos... $LOCAL_TAR_PATH y $LOCAL_JSON_PATH"
  curl -s -X POST \
       -F "files=@$LOCAL_TAR_PATH" \
       -F "files=@$LOCAL_JSON_PATH" \
       -H "Authorization: Bearer $JWT_TOKEN" \
       "$UPLOAD_ENDPOINT"
  local CURL_EXIT_CODE=$?

  if [ "$CURL_EXIT_CODE" -eq 0 ]; then
    echo "¡Imagen '$IMAGE_TAG_TO_PUSH' subida con éxito al repositorio SFTP (vía backend)!"
  else
    echo "Error: Falló la subida de la imagen y metadatos al backend. Código de salida curl: $CURL_EXIT_CODE." >&2
    echo "Verifique los logs del backend para más detalles." >&2
    return 1
  fi

  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_push_logic "$@"
fi