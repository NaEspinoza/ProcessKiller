# ProcessKiller.sh

Script interactivo para Linux que localiza y termina procesos por **nombre** o **puerto de red**, enviando señales `SIGTERM (15)` o `SIGKILL (9)` en bucle hasta que el proceso desaparece del sistema, con verificación final mediante `netstat`.

---

## Requisitos

| Herramienta | Uso | Paquete |
|---|---|---|
| `bash` ≥ 4.0 | Intérprete | preinstalado |
| `pgrep` / `ps` | Buscar procesos por nombre | `procps` |
| `ss` | Buscar PIDs por puerto (primario) | `iproute2` |
| `lsof` | Buscar PIDs por puerto (fallback) | `lsof` |
| `netstat` | Verificación final | `net-tools` |

> `ss` y `lsof` son **opcionales pero recomendados** para búsqueda por puerto. `netstat` es opcional para la verificación final; el script avisa si no está disponible.

```bash
# Instalar todo de una vez (Debian/Ubuntu)
sudo apt install iproute2 lsof net-tools procps
```

---

## Instalación

```bash
chmod +x PK.sh
./PK.sh          # usuario normal
sudo ./PK.sh     # procesos de root u otros usuarios
```

No requiere instalación ni dependencias externas de Python/Node.

---

## Flujo de ejecución

```
┌─────────────────────────────────────────────────────────┐
│  1. Modo de búsqueda     nombre | puerto                │
│  2. Búsqueda inicial     muestra tabla PID/usuario/cmd  │
│  3. Elección de señal    SIGTERM | SIGKILL | Cascada    │
│  4. Confirmación         resumen + [s/N]                │
│  5. Loop de kill         repite hasta /proc vacío       │
│  6. Verificación final   netstat -putona / -tunalp      │
└─────────────────────────────────────────────────────────┘
```

### Paso 1 — Modo de búsqueda

- **Por nombre:** usa `pgrep -f <patrón>` para coincidir contra la línea de comando completa. Soporta nombres parciales, rutas y argumentos (ej: `python`, `gunicorn`, `/opt/myapp`).
- **Por puerto:** intenta primero `ss -tlnp sport = :<puerto>` extrayendo `pid=N`; si no obtiene resultados, recurre a `lsof -ti :<puerto>`. Valida rango 1–65535.

El propio PID del script siempre se excluye de los resultados.

### Paso 5 — Loop de kill

En cada iteración:
1. Re-escanea los PIDs activos (evita operar sobre PIDs ya muertos).
2. Verifica existencia en `/proc/<pid>` antes de enviar la señal.
3. Llama a `kill -<señal> <pid>` y reporta éxito o falta de permisos.
4. Duerme `POLL_INTERVAL` segundos (por defecto: 1s) antes del siguiente ciclo.

**Modo Cascada:** envía SIGTERM primero y, si tras el loop aún quedan procesos, escala automáticamente a SIGKILL.

### Paso 6 — Verificación final con netstat

Ejecuta ambas variantes y muestra la salida cruda:

```bash
netstat -putona | grep "<objetivo>"
netstat -tunalp | grep "<objetivo>"
```

Veredicto:

| Resultado | Significado |
|---|---|
| Sin salida en ambas | `✔ LIMPIO` — proceso terminado |
| Con salida | `⚠ RASTRO DETECTADO` — puede ser `TIME_WAIT`/`CLOSE_WAIT` (normal en TCP) o proceso relanzado |

> **Nota:** entradas en `TIME_WAIT` son normales; el kernel las retiene ~60 s para evitar colisiones de paquetes tardíos.

---

## Señales disponibles

| Opción | Señal | Comportamiento |
|---|---|---|
| `1` | `SIGTERM (15)` | Solicita cierre graceful; el proceso puede atrapar y limpiar |
| `2` | `SIGKILL (9)` | Fuerza terminación inmediata; no puede ser ignorada |
| `3` | Cascada | SIGTERM → espera loop → SIGKILL si sobrevive |

---

## Variables de configuración

Al inicio del script:

```bash
POLL_INTERVAL=1   # segundos entre cada comprobación del loop
```

---

## Ejemplos de uso

```bash
# Matar un servidor nginx por nombre
./PK.sh
# → opción 1 (nombre) → "nginx" → SIGTERM

# Liberar el puerto 8080 ocupado por cualquier proceso
sudo ./PK.sh
# → opción 2 (puerto) → "8080" → SIGKILL

# Proceso resistente que relanza workers
sudo ./PK.sh
# → opción 1 → "gunicorn" → Cascada
```

---

## Notas de seguridad

- Siempre solicita **confirmación explícita** antes de enviar señales.
- Si el usuario no tiene permisos sobre un PID, emite una advertencia y continúa con los demás.
- Procesos propiedad de `root` requieren ejecutar el script con `sudo`.
- `SIGKILL` no puede ser capturada, ignorada ni diferida por ningún proceso en espacio de usuario.

---

## Autor

Nazareno Alejandro Espinoza
