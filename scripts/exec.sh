#!/data/data/com.termux/files/usr/bin/bash

# Este script permite ejecutar comandos dentro de un contenedor en ejecución.

# --- Variables de Configuración Global ---
CONTAINERS_DIR="$HOME/.proobox/containers"

# --- Cargar scripts de utilidad ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
METADATA_SCRIPT="$SCRIPT_DIR/metadata.sh" # Ruta al script de metadatos.
UTILS_SCRIPT="$SCRIPT_DIR/utils.sh" # Ruta al script de utilidades.

if [ -f "$UTILS_SCRIPT" ]; then
  . "$UTILS_SCRIPT"
else
  echo "Error: No se encontró el script de utilidades '$UTILS_SCRIPT'. Funcionalidad limitada." >&2
  exit 1
fi

if [ -f "$METADATA_SCRIPT" ]; then
  . "$METADATA_SCRIPT" 
  if ! command_exists update_container_state_metadata; then # Verificar una función específica
      echo "Error: La función 'update_container_state_metadata' no se cargó correctamente desde '$METADATA_SCRIPT'." >&2
      echo "Asegúrate de que 'metadata.sh' sea un script de Bash válido y tenga permisos." >&2
      exit 1 
  fi
else
  echo "Error: No se encontró el script de metadatos '$METADATA_SCRIPT'. Los metadatos no se generarán/actualizarán." >&2
  exit 1 
fi

# Determina si un proceso proot está en ejecución para un contenedor dado.
is_running() { # Copiado de ps.sh para que exec.sh lo use
    local container_name="$1"
    local containers_dir_path="$HOME/.proobox/containers" # Definir aquí o pasar
    local rootfs_path_escaped=$(echo "$containers_dir_path/$container_name/rootfs" | sed 's/\//\\\//g')
    if pgrep -f "proot.*-r $rootfs_path_escaped" >/dev/null; then
        echo "Running"
    else
        echo "Exited"
    fi
}

# --- Lógica Principal del Script exec.sh ---
main_exec_logic() {
  local INTERACTIVE_MODE=false # -i
  local ALLOCATE_TTY=false     # -t
  local DETACHED_MODE=false    # -d
  local CUSTOM_USER="root"     # --user
  local CUSTOM_WORKDIR=""      # --workdir
  local EXTRA_ENV_VARS=()      # --env
  local TARGET_CONTAINER_ID_OR_NAME="" # Contenedor objetivo
  local COMMAND_TO_EXECUTE=()  # Comando a ejecutar dentro del contenedor

  show_exec_help() {
    echo "Uso: exec.sh [opciones] <nombre_o_id_del_contenedor> [comando] [argumentos...]"
    echo ""
    echo "Ejecuta un comando dentro de un contenedor en ejecución."
    echo ""
    echo "Opciones:"
    echo "  -i, --interactive      Mantiene STDIN abierto para interactuar con el comando."
    echo "  -t, --tty              Asigna una pseudo-TTY (terminal virtual)."
    echo "  -d, --detach           Ejecuta el comando en segundo plano."
    echo "  -u, --user <usuario>   Especifica el usuario para ejecutar el comando (por defecto: root)."
    echo "  -w, --workdir <ruta>   Define el directorio de trabajo dentro del contenedor."
    echo "  -e, --env <KEY=VALUE>  Establece una variable de entorno para el comando."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container exec my_app ls -l /app"
    echo "  ./termux-container exec -it my_app /bin/bash"
    echo "  ./termux-container exec -d my_app touch /tmp/executed.txt"
    echo "  ./termux-container exec -u www-data my_app id"
  }

  # Parseo de opciones
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -i|--interactive) INTERACTIVE_MODE=true; shift;;
      -t|--tty) ALLOCATE_TTY=true; shift;;
      -d|--detach) DETACHED_MODE=true; shift;;
      -u|--user)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then CUSTOM_USER="$2"; shift 2; else echo "Error: Falta usuario para -u."; show_exec_help; return 1; fi
        ;;
      -w|--workdir)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then CUSTOM_WORKDIR="$2"; shift 2; else echo "Error: Falta directorio para -w."; show_exec_help; return 1; fi
        ;;
      -e|--env)
        if [ -n "$2" ] && [[ "$2" != -* ]]; then EXTRA_ENV_VARS+=("$2"); shift 2; else echo "Error: Falta variable para -e."; show_exec_help; return 1; fi
        ;;
      -h|--help) show_exec_help; return 0;;
      *)
        # El primer argumento posicional es el nombre del contenedor.
        if [ -z "$TARGET_CONTAINER_ID_OR_NAME" ]; then
          TARGET_CONTAINER_ID_OR_NAME="$1"
          shift
        else
          # El resto de argumentos son el comando a ejecutar.
          COMMAND_TO_EXECUTE+=("$1")
          shift
        fi
        ;;
    esac
  done

  # --- Validaciones ---
  if [ -z "$TARGET_CONTAINER_ID_OR_NAME" ]; then
    echo "Error: Se debe especificar el nombre o ID del contenedor."
    show_exec_help
    return 1
  fi
  if [ ${#COMMAND_TO_EXECUTE[@]} -eq 0 ]; then
    echo "Error: Se debe especificar el comando a ejecutar."
    show_exec_help
    return 1
  fi
  if $DETACHED_MODE && ($INTERACTIVE_MODE || $ALLOCATE_TTY); then
    echo "Error: Las opciones -d (--detach) son mutuamente excluyentes con -i o -t."
    show_exec_help
    return 1
  fi
  # --- Fin Validaciones ---

  # 1. Buscar el contenedor en ejecución.
  local container_found_path=""
  if [ -d "$CONTAINERS_DIR/$TARGET_CONTAINER_ID_OR_NAME" ]; then
    container_found_path="$CONTAINERS_DIR/$TARGET_CONTAINER_ID_OR_NAME"
  else
    local full_name_match=$(find "$CONTAINERS_DIR" -maxdepth 1 -mindepth 1 -type d -name "${TARGET_CONTAINER_ID_OR_NAME}*" -print -quit 2>/dev/null)
    if [ -n "$full_name_match" ]; then
      container_found_path="$full_name_match"
    fi
  fi

  if [ -z "$container_found_path" ]; then
    echo "Error: Contenedor '$TARGET_CONTAINER_ID_OR_NAME' no encontrado."
    return 1
  fi

  local container_name=$(basename "$container_found_path")
  local current_status=$(is_running "$container_name")

  if [ "$current_status" == "Exited" ]; then
    echo "Error: El contenedor '$container_name' no está en ejecución. Usa 'start' para iniciarlo."
    return 1
  fi

  # 2. Leer metadatos del contenedor para obtener información del rootfs y la imagen.
  local METADATA_FILE="$container_found_path/metadata.json"
  if [ ! -f "$METADATA_FILE" ]; then
    echo "Error: Archivo de metadatos no encontrado para el contenedor '$container_name'. No se puede ejecutar el comando."
    return 1
  fi

  local container_rootfs=$(jq -r '.Paths.RootfsPath' "$METADATA_FILE")
  local parsed_distribution_name=$(jq -r '.Image.Name' "$METADATA_FILE" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
  local IMAGE_WORKDIR_FROM_METADATA=$(jq -r '.ContainerConfig.WorkingDir' "$METADATA_FILE") # Workdir original de la imagen
  
  # Si se especifica --workdir, tiene prioridad.
  local FINAL_WORKDIR="${CUSTOM_WORKDIR:-$IMAGE_WORKDIR_FROM_METADATA}" 
  if [ "$FINAL_WORKDIR" == "null" ]; then FINAL_WORKDIR="/root"; fi # Fallback seguro


  # 3. Construir el comando proot para la ejecución.
  unset LD_PRELOAD # ¡Crucial para evitar conflictos con termux-exec!

  local PROOT_COMMAND_ARRAY=(
    proot
    --link2symlink
    -0 # Por defecto ejecutamos como root.
    -r "$container_rootfs" 
    
    # Bind mounts esenciales (duplicados de run.sh para consistencia):
    -b /dev:/dev
    -b /proc:/proc
    -b /sys:/sys
    -b /data/data/com.termux/files/usr/tmp:/tmp 
    -b /data/data/com.termux:/data/data/com.termux 
    -b /:/host-rootfs 
    -b /sdcard
    -b /storage 
    -b /mnt
    -b /etc/resolv.conf:/etc/resolv.conf # Asegurar acceso a DNS (aunque se genera por el run inicial)
  )
  
  # Argumentos específicos de proot por distribución (para Alpine busybox):
  if [ "$parsed_distribution_name" == "alpine" ]; then
      PROOT_COMMAND_ARRAY+=("-b" "$container_rootfs/bin/busybox:/bin/sh")
  fi

  # WORKDIR para el comando exec
  PROOT_COMMAND_ARRAY+=("-w" "$FINAL_WORKDIR") 
  PROOT_COMMAND_ARRAY+=("--kill-on-exit") # Terminar este proceso proot al salir del comando exec.

  # Asignar usuario si es diferente de root (requiere que el usuario exista en el rootfs)
  if [ "$CUSTOM_USER" != "root" ]; then
      echo "Advertencia: La opción '--user' (-u) solo soporta 'root' directamente en proot básico."
      echo "Si necesita otro usuario, asegúrese de que el usuario exista en el contenedor y utilice 'su -l $CUSTOM_USER -c \"comando\"' como parte de su comando."
      # Por ahora, si no es root, se emitirá una advertencia y se seguirá como root.
  fi

  # Configurar entorno con /usr/bin/env -i
  PROOT_COMMAND_ARRAY+=("/usr/bin/env" "-i")
  PROOT_COMMAND_ARRAY+=(
    "HOME=/root"
    "PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/games:/usr/local/games"
    "TERM=$TERM" 
    "LANG=C.UTF-8"
  )

  # Añadir variables de entorno adicionales (-e)
  for env_var in "${EXTRA_ENV_VARS[@]}"; do
      PROOT_COMMAND_ARRAY+=("$env_var")
  done

  # El comando final a ejecutar
  PROOT_COMMAND_ARRAY+=("${COMMAND_TO_EXECUTE[@]}")

  # 4. Ejecutar el comando.
  echo "Ejecutando comando en contenedor '$container_name'..."

  local EXEC_LOG_FILE="$container_found_path/exec-$(date +%Y%m%d-%H%M%S).log"

  if $DETACHED_MODE; then
    echo "Comando ejecutándose en segundo plano (detached)."
    nohup "${PROOT_COMMAND_ARRAY[@]}" > "$EXEC_LOG_FILE" 2>&1 &
    local EXEC_PID=$!
    echo "Comando detached lanzado. PID del proceso Termux: $EXEC_PID"
    echo "Salida redirigida a: $EXEC_LOG_FILE"
  else
    # Ejecución interactiva/adjunta
    # proot maneja -i y -t cuando el shell se ejecuta directamente
    if $INTERACTIVE_MODE || $ALLOCATE_TTY; then
        echo "Ejecutando en modo interactivo."
        # No necesitamos -i/-t en proot, el comportamiento interactivo se gestiona por la terminal.
        # Si el comando es un shell (ej. /bin/bash), será interactivo.
        "${PROOT_COMMAND_ARRAY[@]}"
    else
        # No interactivo, salida adjunta.
        "${PROOT_COMMAND_ARRAY[@]}"
    fi
    echo "Comando finalizado."
  fi

  return 0
}

# Llama a la función principal con todos los argumentos pasados al script.
main_exec_logic "$@"