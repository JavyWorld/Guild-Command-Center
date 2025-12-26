# Guild Activity Tracker

Guild Activity Tracker es un addon de World of Warcraft enfocado en monitorizar la actividad de chat de hermandad, generar estadísticas temporales y ofrecer utilidades rápidas para la gestión de miembros. Este repositorio contiene el código completo del addon listo para instalarse en la carpeta `Interface/AddOns`.

## Características principales
- **Conteo de actividad en el chat de hermandad**: registra cada mensaje recibido, manteniendo totales y marcas de tiempo por jugador.
- **Escaneo del roster y estados en línea**: sincroniza rangos, nombres y estado online para priorizar la visualización.
- **Botón de minimapa y comando `/gat`**: accesos rápidos para abrir la interfaz principal o las opciones.
- **Ventana de jugadores faltantes**: identifica entradas almacenadas que ya no están en el roster y permite limpiarlas.
- **Snapshots y tendencias**: captura periódica del roster, de conexiones y puntuación M+ para graficar tendencias en el tiempo.
- **Auto-archivado**: limpia días antiguos y jugadores inactivos según una ventana configurable.
- **Exportación**: soporte para exportar datos almacenados para procesarlos externamente.

## Requisitos
- World of Warcraft Retail (probado con interfaz `100207`).
- Permisos para colocar archivos en `World of Warcraft/_retail_/Interface/AddOns`.

## Instalación
1. Descarga o clona este repositorio.
2. Copia la carpeta `Guild-Command-Center` dentro de `World of Warcraft/_retail_/Interface/AddOns/`.
3. Reinicia el cliente o recarga la interfaz con `/reload`.

## Uso rápido
- **Abrir la UI**: haz clic izquierdo en el botón del minimapa o escribe `/gat` en el chat.
- **Abrir las opciones**: clic derecho en el botón del minimapa.
- **Filtrar actividad**: usa los controles de la tabla principal para ordenar por mensajes, online, rango o reciente.
- **Revisar jugadores faltantes**: abre la ventana "Jugadores Faltantes" desde la interfaz principal para limpiar entradas obsoletas.

## Configuración y datos
- **Orden y filtros**: el addon guarda la preferencia de orden en la base de datos de guardado (`SavedVariables`).
- **Auto-archivado**: activa la limpieza automática y define la cantidad de días a conservar en las opciones.
- **Snapshots**: las capturas automáticas del roster se realizan cada pocos minutos y también al abrir la UI, en el logout o al actualizar el roster.
- **Exportación**: el módulo `export.lua` prepara los datos para que puedan consumirse desde herramientas externas.

## Estructura del proyecto
- `core.lua`: inicialización del addon, eventos base y comando `/gat`.
- `events.lua`: escucha del chat de hermandad y sincronización del roster.
- `data.lua`: lógica de almacenamiento, ordenado, normalización de nombres y auto-archivado.
- `ui.lua`, `filters_ui.lua`, `graph.lua`, `trends.lua`: componentes de la interfaz, filtros, gráficas y tendencias.
- `minimap.lua`: botón de minimapa y accesos directos.
- `stats.lua`: captura periódica de actividad del roster y estadísticas de conexión.
- `export.lua`: utilidades para extraer datos.
- `media/`: recursos gráficos (logo, icono de minimapa).

## Desarrollo
- El addon usa variables guardadas bajo el nombre `GuildActivityTrackerDB`.
- Las funciones evitan envolver importaciones en bloques `pcall` o `try/catch`, siguiendo las convenciones de Lua en addons.
- Para probar cambios, coloca la carpeta del proyecto en el directorio de AddOns, habilita "Guild Activity Tracker" en el gestor de addons y utiliza `/reload` tras cada modificación.

## Licencia
Este proyecto es mantenido por la comunidad. Si añades mejoras o arreglos, envía un pull request describiendo los cambios.
