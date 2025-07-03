#!/data/data/com.termux/files/usr/bin/bash

# Este script es el punto de entrada principal para el gestor de contenedores PRooBox.
# Delega las operaciones a los scripts específicos en la carpeta 'scripts/'.

# --- Variables de Configuración Global ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

# --- Funciones de Utilidad Global ---
# La función command_exists ahora se carga desde scripts/utils.sh en cada script individual.
# Aquí solo se define si main.sh mismo necesitara usarla, pero por lo general, solo delega.
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

# --- Lógica Principal del Script ---

# Muestra el mensaje de ayuda general del programa.
show_help() {
  echo "Uso: ./proobox [comando]"
  echo ""
  echo "Comandos disponibles:"
  echo "  pull <imagen>[:<version>]  Descarga una imagen de contenedor (ej: ubuntu:22.04.3, alpine)."
  echo "  image [subcomando]        Gestiona imágenes (ls, rm, tag)."
  echo "  run [opciones] <imagen>[:<version>] [comando] [...] Ejecuta un contenedor."
  echo "  ps [opciones]             Muestra los contenedores (en ejecución o todos)."
  echo "  rm [opciones] <nombre_o_id> [...] Elimina uno o más contenedores."
  echo "  start <nombre_o_id>       Inicia un contenedor existente."
  echo "  stop [opciones] <nombre_o_id>    Detiene un contenedor en ejecución."
  echo "  restart [opciones] <nombre_o_id> Reinicia un contenedor."
  echo "  build [opciones] <ruta_contexto> Construye una imagen a partir de un Buildfile."
  echo "  push <nombre_de_la_imagen>[:<etiqueta>] Sube una imagen a un repositorio personal." # NUEVO: push
  echo "  exec [opciones] <nombre_o_id> <comando> [...] Ejecuta un comando en un contenedor en ejecución."
  echo "  logs [opciones] <nombre_o_id>    Muestra los registros de un contenedor."
  echo "  help                      Muestra esta ayuda."
  echo ""
  echo "Ejemplos:"
  echo "  ./proobox pull ubuntu:22.04.3"
  echo "  ./proobox run -d --name my_server ubuntu:22.04.3 sleep 3600"
  echo "  ./proobox exec my_server ls -l /var/log"
  echo "  ./proobox exec -it my_server /bin/bash"
  echo "  ./proobox stop my_server"
  echo "  ./proobox restart my_server"
  echo "  ./proobox logs my_server"
  echo "  ./proobox build -t my_custom_app:latest ."
  echo "  ./proobox push my_custom_app:latest" # NUEVO: Ejemplo de push
}

# Si no se proporcionan argumentos al script, muestra la ayuda y sale.
if [ -z "$1" ]; then
  show_help
  exit 0
fi

# Procesa el comando principal pasado como primer argumento.
case "$1" in
  pull)
    # Verifica si se proporcionó el argumento de la imagen.
    if [ -z "$2" ]; then
      echo "Error: Se esperaba imagen en formato 'distribucion:version' o 'distribucion'. Ej: pull ubuntu:22.04.3" >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'pull.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/pull.sh" ]; then
      "$SCRIPTS_DIR/pull.sh" "${@:2}" 
    else
      echo "Error: Script de pull '$SCRIPTS_DIR/pull.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  image)
    # Ejecuta el script 'image.sh' pasándole los argumentos del subcomando.
    if [ -f "$SCRIPTS_DIR/image.sh" ]; then
      "$SCRIPTS_DIR/image.sh" "${@:2}" 
    else
      echo "Error: Script de gestión de imágenes '$SCRIPTS_DIR/image.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  run)
    # Verifica si se proporcionó el argumento de la imagen.
    if [ -z "$2" ]; then
      echo "Error: Se esperaba imagen en formato 'distribucion:version' o 'distribucion'. Ej: run ubuntu:22.04.3" >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'run.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/run.sh" ]; then
      "$SCRIPTS_DIR/run.sh" "${@:2}" 
    else
      echo "Error: Script de ejecución de contenedores '$SCRIPTS_DIR/run.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  ps)
    # Ejecuta el script 'ps.sh' pasándole los argumentos de las opciones.
    if [ -f "$SCRIPTS_DIR/ps.sh" ]; then
      "$SCRIPTS_DIR/ps.sh" "${@:2}" 
    else
      echo "Error: Script 'ps.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  rm)
    if [ -z "$2" ]; then 
      echo "Error: Se debe especificar al menos un contenedor para eliminar." >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'rm.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/rm.sh" ]; then
      "$SCRIPTS_DIR/rm.sh" "${@:2}" 
    else
      echo "Error: Script 'rm.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  start) 
    if [ -z "$2" ]; then
      echo "Error: Se debe especificar el nombre o ID del contenedor a iniciar." >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'start.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/start.sh" ]; then
      "$SCRIPTS_DIR/start.sh" "${@:2}" 
    else
      echo "Error: Script 'start.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  stop) 
    if [ -z "$2" ]; then
      echo "Error: Se debe especificar el nombre o ID del contenedor a detener." >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'stop.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/stop.sh" ]; then
      "$SCRIPTS_DIR/stop.sh" "${@:2}" 
    else
      echo "Error: Script 'stop.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  restart) 
    if [ -z "$2" ]; then
      echo "Error: Se debe especificar el nombre o ID del contenedor a reiniciar." >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'restart.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/restart.sh" ]; then
      "$SCRIPTS_DIR/restart.sh" "${@:2}"
    else
      echo "Error: Script 'restart.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  build)
    if [ -z "$2" ]; then
      echo "Error: Se requiere un directorio de contexto para el comando 'build'." >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'build.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/build.sh" ]; then
      "$SCRIPTS_DIR/build.sh" "${@:2}"
    else
      echo "Error: Script 'build.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  push) # NUEVO: push
    if [ -z "$2" ]; then
      echo "Error: Se debe especificar el nombre de la imagen a subir." >&2
      show_help
      exit 1
    fi
    if [ -f "$SCRIPTS_DIR/push.sh" ]; then
      "$SCRIPTS_DIR/push.sh" "${@:2}"
    else
      echo "Error: Script 'push.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  exec) 
    if [ -z "$2" ]; then
      echo "Error: Se debe especificar el nombre o ID del contenedor para 'exec'." >&2
      show_help
      exit 1
    fi
    # Ejecuta el script 'exec.sh' pasándole el resto de los argumentos.
    if [ -f "$SCRIPTS_DIR/exec.sh" ]; then
      "$SCRIPTS_DIR/exec.sh" "${@:2}"
    else
      echo "Error: Script 'exec.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  logs) # logs
    if [ -z "$2" ]; then
      echo "Error: Se debe especificar el nombre o ID del contenedor para 'logs'." >&2
      show_help
      exit 1
    fi
    if [ -f "$SCRIPTS_DIR/logs.sh" ]; then
      "$SCRIPTS_DIR/logs.sh" "${@:2}"
    else
      echo "Error: Script 'logs.sh' no encontrado." >&2
      exit 1
    fi
    ;;
  help)
    show_help
    ;;
  *) # Si el comando no es reconocido.
    echo "Error: Comando desconocido: $1" >&2
    show_help
    exit 1
    ;;
esac