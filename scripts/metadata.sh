#!/data/data/com.termux/files/usr/bin/bash

# Este script genera y gestiona metadatos JSON para imágenes y contenedores.
# Puede ser 'sourced' para usar sus funciones (ej. en bash interactivo),
# o ejecutado directamente con argumentos para generar/actualizar metadatos (modo CLI).

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh"

if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. Funcionalidad de metadatos podría fallar." >&2
  exit 1 # Crítico
fi

# --- Variables de Configuración Global (deben ser consistentes con el gestor principal) ---
PROOBOX_BASE_DIR="$HOME/.proobox"
IMAGES_DIR="$PROOBOX_BASE_DIR/images"
CONTAINERS_DIR="$PROOBOX_BASE_DIR/containers"

# --- Funciones internas/helpers de metadatos ---

generate_random_id() {
  head /dev/urandom | tr -dc a-f0-9 | head -c 64
}

get_current_iso_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%S.%NZ | sed 's/\([0-9][0-9]\)Z$/:\1Z/'
}

is_valid_json_file() {
    local filepath="$1"
    if [ ! -f "$filepath" ]; then
        return 1
    fi
    jq -e . "$filepath" >/dev/null 2>&1
    return $?
}

# --- Funciones de Gestión de Metadatos (para uso interno o CLI) ---

# Función para normalizar la cadena de versión (ej. "1" -> "1.0.0", "2.5" -> "2.5.0").
# Se incluye aquí para que las funciones de metadatos no dependan de que normalize_image_version esté sourced.
normalize_image_version() {
  local version_str="$1"
  if [ -z "$version_str" ]; then echo ""; return; fi
  if [[ "$version_str" =~ ^[0-9]+$ ]]; then echo "${version_str}.0.0"; return; fi
  if [[ "$version_str" =~ ^[0-9]+\.[0-9]+$ ]]; then echo "${version_str}.0"; return; fi
  echo "$version_str"
}

# generate_image_metadata - Genera metadatos de IMAGEN
# Este es el comando que pull.sh y build.sh llamarán a través del CLI de metadata.sh
# $1: image_id
# $2: repo_tags_json (JSON string, ej: '["repo:tag"]')
# $3: image_path (ruta al .tar.gz de la imagen)
# $4: virtual_size
# $5: container_cmd_json (JSON string, ej: '["cmd", "arg"]' o 'null')
# $6: container_workdir (string, ej: "/root")
# $7: container_env_json (JSON string, ej: '["KEY=VALUE"]')
generate_image_metadata() {
    local image_id="$1"
    local repo_tags_json_str="$2"
    local image_path="$3"
    local virtual_size="$4"
    local container_cmd_json_str="${5:-null}"
    local container_workdir_str="${6:-/root}"
    local container_env_json_str="${7:-[]}"

    local first_tag=$(echo "$repo_tags_json_str" | jq -r '.[0]')
    local parts=(${first_tag//:/ })
    local image_name_part=$(echo "${parts[0]}" | tr '[:upper:]' '[:lower:]')
    local image_version_part="${parts[1]:-latest}"

    local metadata_file="$IMAGES_DIR/${image_name_part}-${image_version_part}.json"
    local current_timestamp=$(get_current_iso_timestamp)
    local actual_image_size_bytes="$(du -b "$image_path" 2>/dev/null | awk '{print $1}')"
    if [ -z "$actual_image_size_bytes" ]; then actual_image_size_bytes="0"; fi

    # Parsear JSON strings a valores JSON primitivos o arrays usando jq
    local parsed_cmd_json=$(echo "$container_cmd_json_str" | jq -c '. // null' 2>/dev/null || echo "null")
    local parsed_repo_tags_json=$(echo "$repo_tags_json_str" | jq -c '. // []' 2>/dev/null || echo "[]")
    local parsed_env_json=$(echo "$container_env_json_str" | jq -c '. // []' 2>/dev/null || echo "[]")
    
    # Asegurarse de que WorkingDir no sea literalmente "null" o "[]"
    local final_container_workdir="$container_workdir_str"
    if [ "$final_container_workdir" == "null" ] || [ "$final_container_workdir" == "[]" ]; then
        final_container_workdir="/root"
    fi

    cat << EOF > "$metadata_file"
{
  "Id": "$image_id",
  "RepoTags": $parsed_repo_tags_json,
  "Created": "$current_timestamp",
  "Size": "$actual_image_size_bytes",
  "VirtualSize": "$virtual_size",
  "ContainerConfig": {
    "Cmd": $parsed_cmd_json,
    "WorkingDir": "$final_container_workdir",
    "Entrypoint": null,
    "Env": $parsed_env_json
  },
  "Os": "linux",
  "Architecture": "$(get_mapped_architecture)",
  "Paths": {
    "ImagePath": "$image_path"
  }
}
EOF
    return 0
}

# generate_container_metadata - Genera metadatos de CONTENEDOR
# Este es el comando que run.sh llamará a través del CLI de metadata.sh
# $1: container_name
# $2: image_tag
# $3: parsed_distribution_name
# $4: parsed_image_version
# $5: image_path (ruta al .tar.gz de la imagen base)
# $6: container_rootfs (ruta al rootfs del contenedor)
# $7: detached_mode_str ("true" o "false")
# $8: remove_on_exit_str ("true" o "false")
# $9: initial_command_json_str (JSON string, ej: '["/bin/bash", "--login"]' o 'null')
# $10: env_vars_array_string (JSON string, ej: '["KEY=VALUE"]')
# $11: mounts_json_string (JSON string)
# $12: interactive_original_str ("true" o "false")
generate_container_metadata() {
  local container_name="$1"
  local image_tag="$2"
  local parsed_distribution_name="$3"
  local parsed_image_version="$4"
  local image_path="$5"
  local container_rootfs="$6"
  local detached_mode_str="$7"
  local remove_on_exit_str="$8"
  local initial_command_json_str="${9:-null}"
  local env_vars_array_string="${10:-[]}"
  local mounts_json_string="${11:-[]}"
  local interactive_original_str="${12:-false}"

  local CONTAINER_DATA_DIR="$CONTAINERS_DIR/$container_name"
  local METADATA_FILE="$CONTAINER_DATA_DIR/metadata.json"
  local CURRENT_TIMESTAMP=$(get_current_iso_timestamp)

  local INITIAL_STATUS="created"
  local IS_RUNNING_BOOL="false"
  if [ "$detached_mode_str" == "true" ]; then
    INITIAL_STATUS="running"
    IS_RUNNING_BOOL="true"
  fi

  local IMAGE_ID=$(md5sum "$image_path" 2>/dev/null | awk '{print $1}')
  if [ -z "$IMAGE_ID" ]; then IMAGE_ID="unknown_id"; fi
  local CONTAINER_ID=$(generate_random_id)

  local container_workdir_from_image="/root"
  # Asumimos que normalize_image_version exista, ya sea globalmente o en run/pull.sh
  local IMAGE_METADATA_FILE_FOR_WORKDIR="$IMAGES_DIR/${parsed_distribution_name}-$(normalize_image_version "$parsed_image_version").json"
  if [ -f "$IMAGE_METADATA_FILE_FOR_WORKDIR" ]; then
      local raw_workdir_from_json=$(jq -r '.ContainerConfig.WorkingDir' "$IMAGE_METADATA_FILE_FOR_WORKDIR" 2>/dev/null)
      if [ "$raw_workdir_from_json" != "null" ] && [ -n "$raw_workdir_from_json" ]; then
          container_workdir_from_image="$raw_workdir_from_json"
      fi
  fi

  # Parsear JSON strings a valores JSON primitivos o arrays usando jq
  local parsed_initial_command_json=$(echo "$initial_command_json_str" | jq -c '. // null' 2>/dev/null || echo "null")
  local parsed_env_vars_array_string=$(echo "$env_vars_array_string" | jq -c '. // []' 2>/dev/null || echo "[]")
  local parsed_mounts_json=$(echo "$mounts_json_string" | jq -c '. // []' 2>/dev/null || echo "[]")

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
    "Env": $parsed_env_vars_array_string,
    "Cmd": $parsed_initial_command_json,
    "Image": "$image_tag",
    "WorkingDir": "$container_workdir_from_image",
    "Entrypoint": null,
    "Healthcheck": null
  },
  "HostConfig": {
    "Binds": $parsed_mounts_json,
    "AutoRemove": $remove_on_exit_str
  },
  "Mounts": $parsed_mounts_json,
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
    return 0
}


# update_container_state_metadata - Actualiza el estado de un contenedor
# Este es el comando que run.sh, stop.sh y container_manager.sh llamarán a través del CLI de metadata.sh
# $1: container_name
# $2: status
# $3: running_bool ("true" o "false" string)
# $4: exit_code (número o "null" string)
update_container_state_metadata() {
  local container_name="$1"
  local status="$2"
  local running_bool_str="$3"
  local exit_code_str="${4:-null}"

  local CONTAINER_DATA_DIR="$CONTAINERS_DIR/$container_name"
  local METADATA_FILE="$CONTAINER_DATA_DIR/metadata.json"
  local CURRENT_TIMESTAMP=$(get_current_iso_timestamp)

  if [ ! -f "$METADATA_FILE" ]; then
    echo "Advertencia: Archivo de metadatos no encontrado para el contenedor '$container_name'. No se pudo actualizar el estado." >&2
    return 1
  fi

  local json_exit_code="$exit_code_str"
  if [[ ! "$exit_code_str" =~ ^[0-9]+$ ]] && [[ "$exit_code_str" != "null" ]]; then
      json_exit_code="null"
  fi

  local temp_metadata_file="$METADATA_FILE.tmp"

  # Añadir permisos de escritura al directorio padre por si acaso
  local PARENT_DIR=$(dirname "$METADATA_FILE")
  chmod u+w "$PARENT_DIR" 2>/dev/null || true # Ignorar errores si no tiene permiso para chmod
  chmod u+w "$METADATA_FILE" 2>/dev/null || true # Añadir permisos de escritura al archivo existente.

  # Intento de jq
  jq --arg status "$status" \
     --argjson running "$(if [ "$running_bool_str" == "true" ]; then echo true; else echo false; fi)" \
     --arg finishedat "$CURRENT_TIMESTAMP" \
     --argjson exitcode "$json_exit_code" \
     '.State.Status = $status | .State.Running = $running | .State.FinishedAt = $finishedat | .State.ExitCode = $exitcode' \
     "$METADATA_FILE" > "$temp_metadata_file"
  local JQ_EXIT_CODE=$?

  if [ "$JQ_EXIT_CODE" -ne 0 ]; then
      rm -f "$temp_metadata_file" # Limpiar archivo temporal
      return 1
  fi

  # Intento de mover/reemplazar el archivo
  mv "$temp_metadata_file" "$METADATA_FILE"
  local MV_EXIT_CODE=$?

  if [ "$MV_EXIT_CODE" -ne 0 ]; then
      echo "ERROR: Falló al mover el archivo temporal a '$METADATA_FILE' (código $MV_EXIT_CODE)." >&2
      echo "DEBUG: Asegúrese de tener permisos de escritura en el directorio: '$PARENT_DIR'" >&2
      echo "DEBUG: Contenido de '$temp_metadata_file' ANTES del mv fallido:\n$(cat "$temp_metadata_file" 2>/dev/null)" >&2
      # Intentar copiar y luego eliminar como fallback si mv falla.
      cp "$temp_metadata_file" "$METADATA_FILE" 2>/dev/null
      if [ $? -eq 0 ]; then
          echo "Advertencia: 'mv' falló, pero 'cp' tuvo éxito. Puede que necesite limpiar el archivo temporal." >&2
          rm -f "$temp_metadata_file" # Limpiar solo si cp tuvo éxito
      else
          echo "Error: Ni 'mv' ni 'cp' pudieron actualizar '$METADATA_FILE'. Dejando archivo temporal: '$temp_metadata_file'." >&2
      fi
      return 1
  fi
  
  # Lógica para --rm si el contenedor termina
  if [ "$status" == "exited" ]; then
      local AUTO_REMOVE=$(jq -r '.HostConfig.AutoRemove' "$METADATA_FILE" 2>/dev/null)
      if [ "$AUTO_REMOVE" == "true" ]; then
          local RM_SCRIPT="${SCRIPT_DIR:-$(dirname "$(realpath "$0")")}/rm.sh" 
          if [ -f "$RM_SCRIPT" ]; then
              "$RM_SCRIPT" -f "$container_name"
          else
              echo "Advertencia: Script 'rm.sh' no encontrado. No se pudo eliminar el contenedor '$container_name' automáticamente (--rm)." >&2
          fi
      fi
  fi

  return $?
}

# LÓGICA PRINCIPAL DEL SCRIPT CUANDO SE EJECUTA DIRECTAMENTE (NO CUANDO SE HACE 'source')
# Este bloque permite que metadata.sh actúe como una CLI para sus funciones.
# Ejemplo de uso: scripts/metadata.sh generate_image_metadata "id" "[\"repo:tag\"]" "path/to/tar" "size"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [ -z "$1" ]; then
        echo "Uso: metadata.sh <comando> [args...]" >&2
        echo "Comandos: generate_image_metadata, generate_container_metadata, update_container_state_metadata" >&2
        exit 1
    fi

    case "$1" in
        generate_image_metadata)
            generate_image_metadata "${@:2}"
            exit $?
            ;;
        generate_container_metadata)
            generate_container_metadata "${@:2}"
            exit $?
            ;;
        update_container_state_metadata)
            update_container_state_metadata "${@:2}"
            exit $?
            ;;
        *)
            echo "Comando desconocido para metadata.sh: $1" >&2
            exit 1
            ;;
    esac
fi