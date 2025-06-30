# Termux-Container

> Un gestor de contenedores ligero para Termux, impulsado por PRoot.

## 📝 Descripción

Termux-Container es una herramienta de línea de comandos que te permite crear, ejecutar, gestionar y construir contenedores ligeros de Linux (como Ubuntu y Alpine) directamente en tu entorno Termux de Android, utilizando la tecnología PRoot. Ofrece una experiencia similar a Docker para entornos no-root.

## 🚀 Instalación

Sigue estos pasos para instalar y configurar Termux-Container en tu Termux:

1.  **Asegúrate de tener Termux instalado:** Descárgalo desde F-Droid para la mejor experiencia.
2.  **Instala dependencias en Termux:**
    ```bash
    pkg update && pkg upgrade
    pkg install proot wget tar coreutils findutils procps jq
    ```
3.  **Clona el repositorio (o descarga los scripts):**
    ```bash
    git clone https://github.com/tu_usuario/termux-container.git # Cambia esto a tu repositorio real
    cd termux-container
    ```
4.  **Da permisos de ejecución a los scripts:**
    ```bash
    chmod +x main.sh scripts/*.sh
    ```

## 💡 Uso

Aquí tienes algunos ejemplos de cómo usar Termux-Container para gestionar tus contenedores:

Puedes usar `./termux-container help` para ver todos los comandos disponibles. Aquí algunos ejemplos clave:

### Descargar una imagen base
```bash
./termux-container pull ubuntu:22.04.3 # Descarga Ubuntu 22.04.3 LTS
./termux-container pull alpine:3.22.0 # Descarga Alpine 3.22.0
```

### Ejecutar un contenedor (interactivo)
```bash
./termux-container run -it ubuntu:22.04.3 /bin/bash
```

### Ejecutar un contenedor en segundo plano (detached)
```bash
./termux-container run -d --name my_nginx_server my_custom_nginx:latest # Reemplaza con tu imagen Nginx
```

### Listar contenedores en ejecución o todos
```bash
./termux-container ps
./termux-container ps -a
```

### Detener un contenedor
```bash
./termux-container stop my_nginx_server
```

### Reiniciar un contenedor
```bash
./termux-container restart my_nginx_server
```

### Eliminar un contenedor (usar -f para forzar si está en ejecución)
```bash
./termux-container rm my_nginx_server
./termux-container rm -f $(./termux-container ps -aq) # Elimina todos los contenedores detenidos
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
./termux-container build -t my_custom_image:latest ./my_build_context
```


## 🤝 Contribución

Las contribuciones son bienvenidas. Por favor, abre un 'issue' para cualquier error o sugerencia.

## 📄 Licencia

Este proyecto está bajo la licencia MIT.

---
Generado con `generate_readme.sh`
