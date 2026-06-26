#!/usr/bin/env bash
# ============================================================
#  processkill.sh — Termina procesos por nombre o puerto
#  Señal:  SIGTERM (15) o SIGKILL (9)  según elección del usuario
#  Loop:   repite hasta que el proceso desaparece del sistema
# ============================================================

set -euo pipefail

# ─── Colores y estilos ─────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Constantes ─────────────────────────────────────────────
POLL_INTERVAL=1   # segundos entre cada comprobación
POLL_I2=2

# ─── Funciones de UI ─────────────────────────────────────────
banner() {
    echo
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║        ${MAGENTA}⚡  ProcessKill  ⚡${CYAN}               ║${RESET}"
    echo -e "${BOLD}${CYAN}║   ${DIM}Terminator de procesos Linux v1.1${RESET}${BOLD}${CYAN}     ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}"
    echo
}

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

separador() { echo -e "${DIM}────────────────────────────────────────────${RESET}"; }

# ─── Dependencias opcionales ─────────────────────────────────
check_deps() {
    local missing=()
    for cmd in lsof ss netstat; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Comandos opcionales no encontrados: ${missing[*]}"
        [[ " ${missing[*]} " =~ " netstat " ]] && \
            warn "netstat ausente — instala con: sudo apt install net-tools"
        warn "Algunas funciones pueden ser limitadas."
    fi
}

# ─── Obtener PIDs por nombre de proceso ──────────────────────
pids_por_nombre() {
    local nombre="$1"
    # pgrep evita coincidir con este mismo script
    pgrep -f "$nombre" 2>/dev/null | grep -v "^$$\$" || true
}

# ─── Obtener PIDs por puerto ──────────────────────────────────
pids_por_puerto() {
    local puerto="$1"
    local pids=()

    # Intentar con ss (iproute2)
    if command -v ss &>/dev/null; then
        while IFS= read -r pid; do
            [[ -n "$pid" && "$pid" != "$$" ]] && pids+=("$pid")
        done < <(ss -tlnp "sport = :${puerto}" 2>/dev/null \
                    | grep -oP 'pid=\K[0-9]+' || true)
    fi

    # Intentar con lsof como fallback
    if [[ ${#pids[@]} -eq 0 ]] && command -v lsof &>/dev/null; then
        while IFS= read -r pid; do
            [[ -n "$pid" && "$pid" != "$$" ]] && pids+=("$pid")
        done < <(lsof -ti :"$puerto" 2>/dev/null || true)
    fi

    printf '%s\n' "${pids[@]}" | sort -u
}

# ─── Mostrar tabla de procesos encontrados ────────────────────
mostrar_procesos() {
    local -a pids=("$@")
    echo
    echo -e "${BOLD}  PID       USUARIO       PROCESO${RESET}"
    separador
    for pid in "${pids[@]}"; do
        if [[ -d "/proc/$pid" ]]; then
            local cmd usuario
            cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "???")
            usuario=$(ps -p "$pid" -o user= 2>/dev/null || echo "???")
            printf "  ${YELLOW}%-9s${RESET} %-13s %s\n" "$pid" "$usuario" "$cmd"
        fi
    done
    separador
    echo
}

# ─── Enviar señal a una lista de PIDs ────────────────────────
enviar_senal() {
    local signal="$1"
    shift
    local -a pids=("$@")
    local enviados=0

    for pid in "${pids[@]}"; do
        if [[ -d "/proc/$pid" ]]; then
            if kill -"$signal" "$pid" 2>/dev/null; then
                ok "Señal $signal enviada → PID ${YELLOW}$pid${RESET}"
                (( enviados++ )) || true
            else
                warn "Sin permisos para matar PID $pid (¿necesitas sudo?)"
            fi
        fi
    done
    return $enviados
}

# ─── Verificar si quedan procesos vivos ──────────────────────
quedan_procesos() {
    local modo="$1"
    local objetivo="$2"
    local pids

    if [[ "$modo" == "nombre" ]]; then
        pids=$(pids_por_nombre "$objetivo")
    else
        pids=$(pids_por_puerto "$objetivo")
    fi

    [[ -n "$pids" ]]
}

# ─── Bucle principal de terminación ──────────────────────────
loop_hasta_muerte() {
    local modo="$1"
    local objetivo="$2"
    local signal="$3"
    local sig_nombre="$4"
    local intento=0

    echo
    info "Iniciando loop de terminación con ${BOLD}${RED}$sig_nombre${RESET}..."
    separador

    while quedan_procesos "$modo" "$objetivo"; do
        (( intento++ )) || true
        local pids_arr=()

        if [[ "$modo" == "nombre" ]]; then
            mapfile -t pids_arr < <(pids_por_nombre "$objetivo")
        else
            mapfile -t pids_arr < <(pids_por_puerto "$objetivo")
        fi

        if [[ ${#pids_arr[@]} -eq 0 ]]; then
            break
        fi

        echo -e "${BOLD}${MAGENTA}[ Intento #$intento ]${RESET} Procesos activos: ${#pids_arr[@]}"
        mostrar_procesos "${pids_arr[@]}"
        enviar_senal "$signal" "${pids_arr[@]}" || true

        echo -e "${DIM}Esperando ${POLL_INTERVAL}s...${RESET}"
        sleep "$POLL_INTERVAL"
    done

    echo
    ok "✓ No quedan procesos activos para ${BOLD}\"$objetivo\"${RESET}."
    echo
}

# ─── Verificación final con netstat ──────────────────────────
# Ejecuta ambas variantes de netstat y muestra si queda rastro
# del objetivo (por nombre o número de puerto) en las conexiones.
verificacion_final_netstat() {
    local objetivo="$1"

    echo
    separador
    echo -e "${BOLD}${CYAN}[ VERIFICACIÓN FINAL — netstat ]${RESET}"
    separador

    if ! command -v netstat &>/dev/null; then
        warn "netstat no está instalado. Omitiendo verificación."
        warn "Para instalarlo: ${BOLD}sudo apt install net-tools${RESET}"
        separador
        echo
        return 0
    fi

    # ── Ejecutar ambas variantes ───────────────────────────────
    local cmd1="netstat -putona"
    local cmd2="netstat -tunalp"
    local salida1 salida2

    sleep "$POLL_I2"

    echo -e "${DIM}Comando 1:${RESET} ${BOLD}$cmd1 | grep \"$objetivo\"${RESET}"
    salida1=$(eval "$cmd1" 2>/dev/null | grep --color=never "$objetivo" || true)

    echo -e "${DIM}Comando 2:${RESET} ${BOLD}$cmd2 | grep \"$objetivo\"${RESET}"
    salida2=$(eval "$cmd2" 2>/dev/null | grep --color=never "$objetivo" || true)

    echo
    # ── Evaluar resultados ─────────────────────────────────────
    local encontrado=0

    if [[ -n "$salida1" ]]; then
        (( encontrado++ )) || true
        echo -e "${YELLOW}▶ Resultado de ${BOLD}$cmd1${RESET}${YELLOW}:${RESET}"
        echo "$salida1" | while IFS= read -r linea; do
            echo -e "  ${DIM}$linea${RESET}"
        done
        echo
    fi

    if [[ -n "$salida2" ]]; then
        (( encontrado++ )) || true
        echo -e "${YELLOW}▶ Resultado de ${BOLD}$cmd2${RESET}${YELLOW}:${RESET}"
        echo "$salida2" | while IFS= read -r linea; do
            echo -e "  ${DIM}$linea${RESET}"
        done
        echo
    fi

    # ── Veredicto final ────────────────────────────────────────
    separador
    if [[ $encontrado -eq 0 ]]; then
        echo -e "  ${BOLD}${GREEN}✔  LIMPIO${RESET} — \"$objetivo\" no aparece en netstat."
        echo -e "  ${DIM}El proceso fue terminado correctamente.${RESET}"
    else
        echo -e "  ${BOLD}${RED}⚠  RASTRO DETECTADO${RESET} — \"$objetivo\" sigue visible en netstat."
        echo -e "  ${DIM}Puede ser una conexión en estado TIME_WAIT/CLOSE_WAIT (normal)${RESET}"
        echo -e "  ${DIM}o un proceso que se reinició. Revisa manualmente.${RESET}"
    fi
    separador
    echo
}

# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════
main() {
    banner
    check_deps

    # ── 1. Modo de búsqueda ────────────────────────────────────
    echo -e "${BOLD}¿Cómo deseas identificar el proceso?${RESET}"
    echo -e "  ${CYAN}1)${RESET} Por nombre (o patrón de proceso)"
    echo -e "  ${CYAN}2)${RESET} Por puerto de red"
    echo
    local modo_num
    read -rp "$(echo -e "${BOLD}Opción [1/2]:${RESET} ")" modo_num

    local modo objetivo
    case "$modo_num" in
        1)
            modo="nombre"
            echo
            read -rp "$(echo -e "${BOLD}Nombre/patrón del proceso:${RESET} ")" objetivo
            [[ -z "$objetivo" ]] && die "El nombre no puede estar vacío."
            ;;
        2)
            modo="puerto"
            echo
            read -rp "$(echo -e "${BOLD}Número de puerto:${RESET} ")" objetivo
            [[ -z "$objetivo" ]] && die "El puerto no puede estar vacío."
            [[ "$objetivo" =~ ^[0-9]+$ ]] || die "El puerto debe ser un número."
            (( objetivo >= 1 && objetivo <= 65535 )) || die "Puerto fuera de rango (1-65535)."
            ;;
        *)
            die "Opción inválida."
            ;;
    esac

    # ── 2. Búsqueda inicial ────────────────────────────────────
    echo
    info "Buscando procesos para ${BOLD}\"$objetivo\"${RESET} (modo: $modo)..."

    local pids_iniciales=()
    if [[ "$modo" == "nombre" ]]; then
        mapfile -t pids_iniciales < <(pids_por_nombre "$objetivo")
    else
        mapfile -t pids_iniciales < <(pids_por_puerto "$objetivo")
    fi

    if [[ ${#pids_iniciales[@]} -eq 0 ]]; then
        warn "No se encontró ningún proceso para ${BOLD}\"$objetivo\"${RESET}."
        exit 0
    fi

    echo -e "${GREEN}Procesos encontrados: ${BOLD}${#pids_iniciales[@]}${RESET}"
    mostrar_procesos "${pids_iniciales[@]}"

    # ── 3. Elección de señal ───────────────────────────────────
    echo -e "${BOLD}¿Qué señal deseas enviar?${RESET}"
    echo -e "  ${CYAN}1)${RESET} ${YELLOW}SIGTERM${RESET} (kill -15) — solicita cierre graceful"
    echo -e "  ${CYAN}2)${RESET} ${RED}SIGKILL${RESET} (kill -9)  — fuerza terminación inmediata"
    echo -e "  ${CYAN}3)${RESET} ${MAGENTA}Cascada${RESET}          — intenta SIGTERM primero, luego SIGKILL"
    echo
    local sig_num
    read -rp "$(echo -e "${BOLD}Opción [1/2/3]:${RESET} ")" sig_num

    local signal sig_nombre
    case "$sig_num" in
        1) signal=15; sig_nombre="SIGTERM (15)" ;;
        2) signal=9;  sig_nombre="SIGKILL (9)"  ;;
        3) signal=99; sig_nombre="CASCADA"       ;;  # marcador especial
        *) die "Opción inválida." ;;
    esac

    # ── 4. Confirmación ────────────────────────────────────────
    separador
    echo -e "${BOLD}${RED}⚠  Resumen de acción${RESET}"
    echo -e "   Objetivo : ${BOLD}$objetivo${RESET}  (modo: $modo)"
    echo -e "   Señal    : ${BOLD}$sig_nombre${RESET}"
    echo -e "   PIDs     : ${YELLOW}${pids_iniciales[*]}${RESET}"
    separador
    echo
    local confirm
    read -rp "$(echo -e "${BOLD}¿Confirmar? [s/N]:${RESET} ")" confirm
    [[ "${confirm,,}" =~ ^(s|si|sí|y|yes)$ ]] || { info "Operación cancelada."; exit 0; }

    # ── 5. Ejecución ───────────────────────────────────────────
    echo
    if [[ $signal -eq 99 ]]; then
        # Modo cascada: SIGTERM primero
        echo -e "${MAGENTA}[ CASCADA ] Fase 1: SIGTERM...${RESET}"
        loop_hasta_muerte "$modo" "$objetivo" 15 "SIGTERM (15)"

        # Comprobar si sobrevivió
        if quedan_procesos "$modo" "$objetivo"; then
            warn "Proceso resistente detectado. Escalando a SIGKILL..."
            sleep 1
            echo -e "${RED}[ CASCADA ] Fase 2: SIGKILL...${RESET}"
            loop_hasta_muerte "$modo" "$objetivo" 9 "SIGKILL (9)"
        fi
    else
        loop_hasta_muerte "$modo" "$objetivo" "$signal" "$sig_nombre"
    fi

    echo -e "${BOLD}${GREEN}✔ Proceso completado.${RESET}"
    echo

    # ── 6. Verificación final con netstat ──────────────────────
    verificacion_final_netstat "$objetivo"
}
main "$@"
