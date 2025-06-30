#!/data/data/com.termux/files/usr/bin/bash

# Este script contiene funciones para generar y gestionar los metadatos de los contenedores en formato JSON.

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh"

if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. La funcionalidad de metadatos podría fallar." >&2
  exit 1
fi


# Función para generar o actualizar el archivo metadata.json de un contenedor.
# Argumentos esperados:
# $1: container_name - El nombre del contenedor.
# $2: image_tag - La imagen completa (ej. "ubuntu:22.04.3").
# $3: parsed_distribution_name - El nombre de la distribución (ej. "ubuntu").
# $4: parsed_image_version - La versión de la imagen (ej. "22.04.3").
# $5: image_path - Ruta completa al archivo .tar.gz de la imagen.
# $6: container_rootfs - Ruta completa al directorio rootfs del contenedor.
# $7: detached_mode_str - "true" o "false" si el contenedor se inició en modo detached.
# $8: remove_on_exit_str - "true" o "false" si la opción --rm está activada.
# $9: initial_command_json_str - El comando inicial ejecutado, como una cadena JSON (ej. "[\"/bin/bash\", \"--login\"]").
# $10: env_vars_array_string - Las variables de entorno como una cadena JSON de array (ej. "[\"VAR=VAL\"]").
# $11: mounts_json_string - Los bind-mounts como una cadena JSON de array (ej. "[{\"Source\":\"/host\",\"Destination\":\"/cont\"}]").
# $12: interactive_original_str - "true" o "false" si fue lanzado con -it.
generate_container_metadata() {
  local container_name="$1"
  local image_tag="$2"
  local parsed_distribution_name="$3"
  local parsed_image_version="$4"
  local image_path="$5"
  local container_rootfs="$6"
  local detached_mode_str="$7" # "true" o "false"
  local remove_on_exit_str="$8" # "true" o "false"
  local initial_command_json_str="${9:-null}" # Comando inicial como JSON string, default a null
  local env_vars_array_string="${10:-[]}" # Env vars como JSON string de array, default a array vacío
  local mounts_json_string="${11:-[]}" # Montajes como JSON string de array, default a array vacío
  local interactive_original_str="${12:-false}" # Modo interactivo original

  local CONTAINER_DATA_DIR="$HOME/.termux-container/containers/$container_name"
  local METADATA_FILE="$CONTAINER_DATA_DIR/metadata.json"
  local CURRENT_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%N%z) # Formato ISO 8601 con zona horaria Z (UTC)

  # Estado inicial
  local INITIAL_STATUS="created"
  local IS_RUNNING_BOOL="false" 
  if [ "$detached_mode_str" == "true" ]; then
    INITIAL_STATUS="running" 
    IS_RUNNING_BOOL="true"
  fi

  # Identificador de imagen (hash del path del archivo)
  local IMAGE_ID=$(echo "$image_path" | md5sum | cut -d' ' -f1)
  # Generar un ID de contenedor único (hash aleatorio de 64 caracteres)
  local CONTAINER_ID=$(head /dev/urandom | tr -dc a-f0-9 | head -c 64)

  cat << EOF > "$METADATA_FILE"
{
  "Id": "$CONTAINER_ID",
  "Name": "$container_name",
  "Image": {
    "Name": "$image_tag",
    "Id": "$IMAGE_ID"
  },
  "State": {
    "Status": "$INITIAL_STATUS",
    "Running": $IS_RUNNING_BOOL,             
    "DetachedOriginal": $detached_mode_str,  
    "InteractiveOriginal": $interactive_original_str, 
    "StartedAt": "$CURRENT_TIMESTAMP",
    "FinishedAt": null,                       
    "ExitCode": null                          
  },
  "Config": {
    "Hostname": "$container_name",
    "Domainname": "",
    "User": "root",
    "Env": $env_vars_array_string,
    "Cmd": $initial_command_json_str,
    "Image": "$image_tag",
    "WorkingDir": "/root",
    "Entrypoint": null,                       
    "Healthcheck": null                       
  },
  "HostConfig": {
    "Binds": $mounts_json_string,
    "AutoRemove": $remove_on_exit_str      
  },
  "Mounts": $mounts_json_string,
  "NetworkSettings": {
    "IPAddress": "",
    "Ports": {}
  },
  "Paths": {
    "RootfsPath": "$container_rootfs",
    "LogFile": "$(if [ "$detached_mode_str" == "true" ]; then echo "$CONTAINER_DATA_DIR/container.log"; else echo "null"; fi)", 
    "ImagePath": "$image_path"
  }
}
EOF
  #echo "Metadatos (estilo Docker) guardados en: $METADATA_FILE" # Desactivar para limpiar salida
  return 0
}

# Función para actualizar el estado de un contenedor en su metadata.json
update_container_state_metadata() {
  local container_name="$1"
  local status="$2"
  local running_bool="$3" # Esto es un string "true" o "false"
  local exit_code="${4:-null}" # Esto es un string "0" o "null"

  local CONTAINER_DATA_DIR="$HOME/.termux-container/containers/$container_name"
  local METADATA_FILE="$CONTAINER_DATA_DIR/metadata.json"
  local CURRENT_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.%N%z)

  if [ ! -f "$METADATA_FILE" ]; then
    echo "Advertencia: Archivo de metadatos no encontrado para el contenedor '$container_name'. No se pudo actualizar el estado." >&2
    return 1
  fi

  # Asegurarse de que exit_code sea un número o null JSON.
  local json_exit_code="$exit_code"
  if [[ ! "$exit_code" =~ ^[0-9]+$ ]] && [[ "$exit_code" != "null" ]]; then
      json_exit_code="null" # Si no es un número y no es "null", forzar a null JSON.
  fi

  # Usar --argjson para pasar valores booleanos y null correctamente.
  jq --arg status "$status" \
     --argjson running "$(if [ "$running_bool" == "true" ]; then echo true; else echo false; fi)" \
     --arg finishedat "$CURRENT_TIMESTAMP" \
     --argjson exitcode "$json_exit_code" \
     '.State.Status = $status | .State.Running = $running | .State.FinishedAt = $finishedat | .State.ExitCode = $exitcode' \
     "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
  
  return 0
}

# Este script no se ejecuta directamente. Sus funciones son 'sourced' por otros scripts.
# No hay lógica principal aquí.