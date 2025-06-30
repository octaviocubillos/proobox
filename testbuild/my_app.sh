i#!/bin/bash
echo "¡Hola desde mi aplicación personalizada en el contenedor!"
echo "Variables de entorno recibidas:"
env | grep MY_VAR
echo "Archivo de host montado en /app_data:"
ls /app_data 2>/dev/null
