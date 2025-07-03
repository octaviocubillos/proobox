#!/bin/sh
# Script para contar segundos y mostrar el PID

echo "--- Iniciando contador de segundos ---"
echo "PID del script: $$" # PID del proceso shell actual
echo "Contando hasta 1000 segundos..."

for i in $(seq 1 1000); do
  echo "Segundo $i de 1000"
  sleep 1
done

echo "--- Contador finalizado ---"