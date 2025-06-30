#!/data/data/com.termux/files/usr/bin/bash

# Este script se encarga de eliminar contenedores.

# --- Variables de Configuración Global ---
CONTAINERS_DIR="$HOME/.termux-container/containers"

# --- Funciones de Utilidad ---
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

# Determina si un proceso proot está en ejecución para un contenedor dado.
# Reutiliza la lógica de ps.sh para mantener la consistencia.
is_running() {
    local container_name="$1"
    local rootfs_path_escaped=$(echo "$CONTAINERS_DIR/$container_name/rootfs" | sed 's/\//\\\//g')
    if pgrep -f "proot.*-r $rootfs_path_escaped" >/dev/null; then
        echo "Running"
    else
        echo "Exited"
    fi
}

# --- Lógica Principal del Script rm.sh ---
main_rm_logic() {
  local FORCE_REMOVE=false
  local REMOVE_LINK=false # Marcador de posición, ya que no gestionamos enlaces externos explícitamente así.
  local REMOVE_VOLUME=false # Indica si eliminar el directorio completo del contenedor.
  local CONTAINERS_TO_REMOVE=() # Array para almacenar los nombres/IDs de contenedores a eliminar.

  show_rm_help() {
    echo "Uso: rm.sh [opciones] <nombre_o_id_del_contenedor> [...]"
    echo ""
    echo "Elimina uno o más contenedores."
    echo ""
    echo "Opciones:"
    echo "  -f, --force            Fuerza la eliminación de un contenedor en ejecución, deteniéndolo primero."
    echo "  -l, --link             Nota: Esta opción no tiene un efecto directo en la implementación actual (sin enlaces explícitos)."
    echo "  -v, --volume           Elimina los volúmenes (datos del contenedor) asociados con el contenedor."
    echo ""
    echo "Ejemplos:"
    echo "  ./termux-container rm my_app"
    echo "  ./termux-container rm -f my_running_app"
    echo "  ./termux-container rm -v my_app"
    echo "  ./termux-container rm -f \$(./termux-container ps -aq) # Elimina todos los contenedores detenidos."
  }

  # Parseo de opciones
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -f|--force)
        FORCE_REMOVE=true
        shift
        ;;
      -l|--link)
        REMOVE_LINK=true
        shift
        ;;
      -v|--volume)
        REMOVE_VOLUME=true
        shift
        ;;
      -h|--help)
        show_rm_help
        return 0
        ;;
      *) # Argumentos restantes son los nombres/IDs de los contenedores
        CONTAINERS_TO_REMOVE+=("$1")
        shift
        ;;
    esac
  done

  if [ ${#CONTAINERS_TO_REMOVE[@]} -eq 0 ]; then
    echo "Error: Se debe especificar al menos un contenedor para eliminar."
    show_rm_help
    return 1
  fi

  # Procesar cada contenedor a eliminar
  for target_container in "${CONTAINERS_TO_REMOVE[@]}"; do
    local container_found_path=""
    
    # Buscar el contenedor por nombre completo o por ID corto
    if [ -d "$CONTAINERS_DIR/$target_container" ]; then
      container_found_path="$CONTAINERS_DIR/$target_container"
    else
      # Intentar buscar por ID corto (primeros 12 chars del nombre del directorio)
      local full_name_match=$(find "$CONTAINERS_DIR" -maxdepth 1 -mindepth 1 -type d -name "${target_container}*" -print -quit 2>/dev/null)
      if [ -n "$full_name_match" ]; then
        container_found_path="$full_name_match"
      else
        echo "Error: Contenedor '$target_container' no encontrado."
        continue # Pasar al siguiente contenedor
      fi
    fi

    local container_name=$(basename "$container_found_path")
    local container_status=$(is_running "$container_name")

    echo "Intentando eliminar contenedor: '$container_name' (ID corto: ${container_name:0:12})"

    if [ "$container_status" == "Running" ]; then
      if $FORCE_REMOVE; then
        echo "Contenedor '$container_name' está en ejecución. Forzando detención..."
        local proot_pids=$(pgrep -f "proot.*-r $(echo "$CONTAINERS_DIR/$container_name/rootfs" | sed 's/\//\\\//g')")
        if [ -n "$proot_pids" ]; then
            echo "Matando procesos proot asociados (PIDs: $proot_pids)..."
            kill $proot_pids 2>/dev/null
            sleep 1 
            if pgrep -f "proot.*-r $(echo "$CONTAINERS_DIR/$container_name/rootfs" | sed 's/\//\\\//g')" >/dev/null; then
                echo "Advertencia: Algunos procesos proot no terminaron. Intentando kill -9."
                kill -9 $proot_pids 2>/dev/null
                sleep 1
            fi
        fi
        local container_status_after_kill=$(is_running "$container_name")
        if [ "$container_status_after_kill" == "Running" ]; then
            echo "Error: No se pudo detener completamente el contenedor '$container_name'. No se eliminará."
            continue
        else
            echo "Contenedor '$container_name' detenido."
        fi
      else
        echo "Error: Contenedor '$container_name' está en ejecución. Usa '-f' para forzar la eliminación."
        continue # Pasar al siguiente contenedor
      fi
    fi

    # Eliminar el directorio del contenedor
    echo "Eliminando directorio del contenedor: '$container_found_path'..."
    rm -rf "$container_found_path"
    if [ $? -eq 0 ]; then
      echo "Contenedor '$container_name' eliminado correctamente."
    else
      echo "Error: Falló la eliminación del directorio del contenedor '$container_name'."
    fi

    if $REMOVE_VOLUME; then
        echo "Nota: La opción '-v' ('--volume') elimina los datos del contenedor, que ya se incluyen en la eliminación del directorio raíz del contenedor."
    fi
    if $REMOVE_LINK; then
        echo "Nota: La opción '-l' ('--link') no tiene un efecto directo en esta implementación, ya que no se gestionan enlaces separados para contenedores."
    fi

  done
}

# Llama a la función principal con todos los argumentos pasados al script.
main_rm_logic "$@"