#!/data/data/com.termux/files/usr/bin/bash

# Este script sube una imagen local (.tar.gz y .json) a un repositorio MinIO usando el cliente 'mc'.

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
# Asegúrate de que las funciones de metadata.sh estén cargadas.
. "$METADATA_SCRIPT"


# --- Variables de Configuración Global ---
PROOBOX_BASE_DIR="$HOME/.proobox"
IMAGES_DIR="$PROOBOX_BASE_DIR/images"
REPO_CONFIG_FILE="$PROOBOX_BASE_DIR/config.json" # Ruta al archivo de configuración del repo
MINIO_ALIAS="proobox_minio" # Alias para el servidor MinIO en 'mc'


# --- Lógica Principal del Script push.sh ---
main_push_logic() {
  local IMAGE_TAG_TO_PUSH="$1"

  show_push_help() {
    echo "Uso: push.sh <nombre_de_la_imagen>[:<etiqueta>]"
    echo ""
    echo "Sube una imagen local (su .tar.gz y sus metadatos .json) a un repositorio MinIO."
    echo "Configura el endpoint, puerto, usuario y contraseña de MinIO en: $REPO_CONFIG_FILE"
    echo "Requiere el cliente 'mc' (MinIO Client) instalado."
    echo ""
    echo "Ejemplos:"
    echo "  ./proobox push my_custom_app:latest"
  }

  if [ -z "$IMAGE_TAG_TO_PUSH" ]; then
    echo "Error: Se debe especificar el nombre de la imagen a subir." >&2
    show_push_help
    return 1
  fi

  if ! command_exists mc; then
    echo "Error: El cliente 'mc' (MinIO Client) no está instalado." >&2
    echo "Por favor, instálalo siguiendo las instrucciones de MinIO (ej. 'pkg install mc' en Termux si está disponible, o descarga el binario)." >&2
    return 1
  fi

  # 1. Leer configuración de MinIO
  if [ ! -f "$REPO_CONFIG_FILE" ]; then
    echo "Error: Archivo de configuración del repositorio no encontrado: '$REPO_CONFIG_FILE'." >&2
    echo "Por favor, crea este archivo con el formato JSON esperado para MinIO." >&2
    return 1
  fi

  local MINIO_ENDPOINT=$(jq -r '.minio.endpoint' "$REPO_CONFIG_FILE" 2>/dev/null)
  local MINIO_PORT=$(jq -r '.minio.port' "$REPO_CONFIG_FILE" 2>/dev/null)
  local MINIO_USERNAME=$(jq -r '.minio.username' "$REPO_CONFIG_FILE" 2>/dev/null)
  local MINIO_PASSWORD=$(jq -r '.minio.password' "$REPO_CONFIG_FILE" 2>/dev/null)

  if [ -z "$MINIO_ENDPOINT" ] || [ "$MINIO_ENDPOINT" == "null" ] || \
     [ -z "$MINIO_PORT" ] || [ "$MINIO_PORT" == "null" ] || \
     [ -z "$MINIO_USERNAME" ] || [ "$MINIO_USERNAME" == "null" ] || \
     [ -z "$MINIO_PASSWORD" ] || [ "$MINIO_PASSWORD" == "null" ]; then
    echo "Error: Configuración de MinIO incompleta o inválida en '$REPO_CONFIG_FILE'." >&2
    echo "Asegúrate de que 'minio.endpoint', 'minio.port', 'minio.username' y 'minio.password' estén definidos." >&2
    return 1
  fi

  local MINIO_SERVER_URL="http://${MINIO_ENDPOINT}" # O https si tu MinIO usa SSL
  local MINIO_BUCKET="proobox-images" # <-- Define el nombre del bucket donde guardarás las imágenes

  echo "Repositorio MinIO configurado: $MINIO_SERVER_URL (Bucket: $MINIO_BUCKET)"

  # 2. Configurar el alias de MinIO (si no existe o si las credenciales han cambiado)
  # Esto añade o actualiza el alias en la configuración de mc (~/.mc/config.json)
  echo "Configurando alias de MinIO: $MINIO_ALIAS"
  mc alias set "$MINIO_ALIAS" "$MINIO_SERVER_URL" "$MINIO_USERNAME" "$MINIO_PASSWORD"
  if [ $? -ne 0 ]; then
    echo "Error: Falló la configuración del alias de MinIO. Verifica la URL y las credenciales." >&2
    return 1
  fi

  # 3. Crear el bucket si no existe
  echo "Verificando/Creando bucket: $MINIO_BUCKET"
  mc mb "$MINIO_ALIAS/$MINIO_BUCKET" --ignore-existing
  if [ $? -ne 0 ]; then
    echo "Error: Falló la creación o verificación del bucket '$MINIO_BUCKET'. Verifica permisos." >&2
    return 1
  fi

  # 4. Localizar archivos de imagen y metadatos
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

  # 5. Subir archivos a MinIO
  echo "--- Subiendo imagen '$IMAGE_TAG_TO_PUSH' a MinIO ---"

  local UPLOAD_SUCCESS=0

  echo "Subiendo: $LOCAL_TAR_PATH a $MINIO_ALIAS/$MINIO_BUCKET/$IMAGE_TAR_FILENAME"
  mc cp "$LOCAL_TAR_PATH" "$MINIO_ALIAS/$MINIO_BUCKET/$IMAGE_TAR_FILENAME"
  
  if [ $? -ne 0 ]; then
    echo "Error: Falló la subida del archivo TAR.GZ a MinIO." >&2
    UPLOAD_SUCCESS=1
  fi

  echo "Subiendo: $LOCAL_JSON_PATH a $MINIO_ALIAS/$MINIO_BUCKET/$IMAGE_JSON_FILENAME"
  mc cp "$LOCAL_JSON_PATH" "$MINIO_ALIAS/$MINIO_BUCKET/$IMAGE_JSON_FILENAME"
  if [ $? -ne 0 ]; then
    echo "Error: Falló la subida del archivo JSON a MinIO." >&2
    UPLOAD_SUCCESS=1
  fi

  if [ "$UPLOAD_SUCCESS" -eq 0 ]; then
    echo "¡Imagen '$IMAGE_TAG_TO_PUSH' subida con éxito a MinIO!"
  else
    echo "Error: Falló la subida completa de la imagen a MinIO." >&2
    return 1
  fi

  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main_push_logic "$@"
fi