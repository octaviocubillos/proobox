#!/data/data/com.termux/files/usr/bin/bash

# Este script contiene funciones de utilidad comunes utilizadas por otros scripts del gestor.

# Función para verificar si un comando existe en el PATH del sistema.
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

# Puedes añadir otras funciones de utilidad aquí en el futuro.