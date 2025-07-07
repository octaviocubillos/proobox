# ProoBox

> Un gestor de contenedores ligero para Termux, impulsado por PRoot.

## 📝 Descripción

ProoBox es una herramienta de línea de comandos que te permite crear, ejecutar, gestionar y construir contenedores ligeros de Linux (como Ubuntu y Alpine) directamente en tu entorno Termux de Android, utilizando la tecnología PRoot. Ofrece una experiencia similar a Docker para entornos no-root.

## 🚀 Instalación

Sigue estos pasos para instalar y configurar ProoBox en tu Termux:

1.  **Asegúrate de tener Termux instalado:** Descárgalo desde F-Droid para la mejor experiencia.
2.  **Instala dependencias en Termux:**
    ```bash
    pkg update && pkg upgrade
    pkg install proot wget tar coreutils findutils procps jq
    ```
3.  **Clona el repositorio (o descarga los scripts):**
    ```bash
    git clone https://github.com/tu_usuario/proobox.git # Cambia esto a tu repositorio real
    cd proobox
    ```
4.  **Da permisos de ejecución a los scripts:**
    ```bash
    chmod +x main.sh scripts/*.sh
    ```

## 💡 Uso

Aquí tienes algunos ejemplos de cómo usar ProoBox para gestionar tus contenedores:

Puedes usar `./proobox help` para ver todos los comandos disponibles. Aquí algunos ejemplos clave:

### Descargar una imagen base
```bash
./proobox pull ubuntu:22.04.3 # Descarga Ubuntu 22.04.3 LTS
./proobox pull alpine:3.22.0 # Descarga Alpine 3.22.0
```

### Ejecutar un contenedor (interactivo)
```bash
./proobox run -it ubuntu:22.04.3 /bin/bash
```

### Ejecutar un contenedor en segundo plano (detached)
```bash
./proobox run -d --name my_nginx_server my_custom_nginx:latest # Reemplaza con tu imagen Nginx
```

### Listar contenedores en ejecución o todos
```bash
./proobox ps
./proobox ps -a
```

### Detener un contenedor
```bash
./proobox stop my_nginx_server
```

### Reiniciar un contenedor
```bash
./proobox restart my_nginx_server
```

### Eliminar un contenedor (usar -f para forzar si está en ejecución)
```bash
./proobox rm my_nginx_server
./proobox rm -f $(./proobox ps -aq) # Elimina todos los contenedores detenidos
```

### Construir una imagen personalizada desde un Buildfile
Crea un archivo `Buildfile` en tu directorio actual (ej. `./my_build_context/Buildfile`):
```dockerfile
FROM ubuntu:22.04.3
RUN apt update && apt install -y curl
COPY my_script.sh /usr/local/bin/my_script
CMD ["/usr/local/bin/my_script"]
```
Luego, construye tu imagen:
```bash
./proobox build -t my_custom_image:latest ./my_build_context
```


## 🤝 Contribución

Las contribuciones son bienvenidas. Por favor, abre un 'issue' para cualquier error o sugerencia.

## 📄 Licencia

Este proyecto está bajo la licencia MIT.

