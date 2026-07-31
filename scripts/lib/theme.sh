#!/usr/bin/env bash
# Biblioteca visual compartilhada (tema "Matrix") para setup.sh e deploy.sh.
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/lib/theme.sh"

if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_DIM=$'\033[2;32m'
    C_GREEN=$'\033[0;32m'
    C_BGREEN=$'\033[1;32m'
    C_WHITE=$'\033[1;37m'
    C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m'
    C_CYAN=$'\033[1;36m'
else
    C_RESET=""; C_DIM=""; C_GREEN=""; C_BGREEN=""; C_WHITE=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

RULE_LINE="══════════════════════════════════════════════════════════════════════"

# --- animacao de abertura (chuva digital, puramente cosmetica) -------------
matrix_rain() {
    [ -t 1 ] || return 0
    [ "${NO_ANIM:-0}" = "1" ] && return 0
    local width=${COLUMNS:-72}
    (( width > 90 )) && width=90
    local rows=6
    local r c line ch
    for ((r = 0; r < rows; r++)); do
        line=""
        for ((c = 0; c < width; c++)); do
            if (( RANDOM % 7 == 0 )); then
                ch=$(( RANDOM % 2 ))
                line+="${ch}"
            else
                line+=" "
            fi
        done
        printf "%s%s%s\n" "${C_GREEN}" "${line}" "${C_RESET}"
        sleep 0.035
    done
}

# --- banner "KEYCLOAK" (largura fixa, gerado/validado a partir de glyphs) --
print_banner() {
    printf "%s\n" "${C_BGREEN}"
    cat <<'EOF'
██╗  ██╗ ███████╗ ██╗   ██╗  ██████╗ ██╗       ██████╗   █████╗  ██╗  ██╗
██║ ██╔╝ ██╔════╝ ╚██╗ ██╔╝ ██╔════╝ ██║      ██╔═══██╗ ██╔══██╗ ██║ ██╔╝
█████╔╝  █████╗    ╚████╔╝  ██║      ██║      ██║   ██║ ███████║ █████╔╝
██╔═██╗  ██╔══╝     ╚██╔╝   ██║      ██║      ██║   ██║ ██╔══██║ ██╔═██╗
██║  ██╗ ███████╗    ██║    ╚██████╗ ███████╗ ╚██████╔╝ ██║  ██║ ██║  ██╗
╚═╝  ╚═╝ ╚══════╝    ╚═╝     ╚═════╝ ╚══════╝  ╚═════╝  ╚═╝  ╚═╝ ╚═╝  ╚═╝
EOF
    printf "%s\n" "${C_RESET}"
}

# $1 = subtitulo (ex: "SETUP - Provisionamento Inicial")
print_header() {
    matrix_rain
    print_banner
    printf "%s%s%s\n" "${C_DIM}" "${RULE_LINE}" "${C_RESET}"
    printf "  %s%s%s\n" "${C_WHITE}" "$1" "${C_RESET}"
    printf "  %sSSO da Prefeitura -- Stack Keycloak / Postgres%s\n" "${C_DIM}" "${C_RESET}"
    printf "%s%s%s\n\n" "${C_DIM}" "${RULE_LINE}" "${C_RESET}"
}

step()    { printf "\n%s▶ %s%s\n" "${C_CYAN}" "$*" "${C_RESET}"; }
log_ok()  { printf "  %s[OK]%s   %s\n" "${C_GREEN}" "${C_RESET}" "$*"; }
log_info(){ printf "  %s[..]%s   %s\n" "${C_DIM}" "${C_RESET}" "$*"; }
log_warn(){ printf "  %s[!!]%s   %s\n" "${C_YELLOW}" "${C_RESET}" "$*"; }
log_err() { printf "  %s[XX]%s   %s\n" "${C_RED}" "${C_RESET}" "$*" >&2; }

die() { log_err "$*"; exit 1; }

# confirm "pergunta" [default: N]
confirm() {
    local prompt="$1" default="${2:-N}" ans hint
    if [ "${ASSUME_YES:-0}" = "1" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        [ "$default" = "Y" ] && return 0 || return 1
    fi
    hint="s/N"; [ "$default" = "Y" ] && hint="S/n"
    read -r -p "  ${C_YELLOW}?${C_RESET} ${prompt} [${hint}]: " ans
    ans="${ans:-$default}"
    case "$ans" in
        [sSyY]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ask "pergunta" "valor_padrao" -> devolve resposta via stdout
ask() {
    local prompt="$1" default="$2" ans
    if [ "${ASSUME_YES:-0}" = "1" ] || [ ! -t 0 ]; then
        printf "%s" "$default"
        return 0
    fi
    read -r -p "  ${C_CYAN}?${C_RESET} ${prompt} [${default}]: " ans
    printf "%s" "${ans:-$default}"
}

# ask_secret "pergunta" -> devolve resposta via stdout, sem ecoar no terminal
ask_secret() {
    local prompt="$1" ans
    if [ "${ASSUME_YES:-0}" = "1" ] || [ ! -t 0 ]; then
        printf ""
        return 0
    fi
    read -r -s -p "  ${C_CYAN}?${C_RESET} ${prompt}: " ans
    printf "\n" >&2
    printf "%s" "$ans"
}

print_panel() {
    # print_panel "TITULO" "linha1" "linha2" ...
    local title="$1"; shift
    printf "\n%s┌─ %s%s\n" "${C_GREEN}" "${title}" "${C_RESET}"
    for line in "$@"; do
        printf "%s│%s %s\n" "${C_GREEN}" "${C_RESET}" "${line}"
    done
    printf "%s└────────────────────────────────────────────────────────────%s\n" "${C_GREEN}" "${C_RESET}"
}

# --- painel de servicos (estilo "dashboard", tipo TrueNAS) -----------------
TABLE_RULE="────────────────────────────────────────────────────────────────────────────────────"

print_table_title() {
    printf "\n%s%s%s\n" "${C_DIM}" "${TABLE_RULE}" "${C_RESET}"
    printf "  %s%s%s\n" "${C_WHITE}" "$1" "${C_RESET}"
    printf "%s%s%s\n" "${C_DIM}" "${TABLE_RULE}" "${C_RESET}"
    printf "  %-15s %-10s %-42s %-20s\n" "SERVICO" "STATUS" "ACESSO" "REDE INTERNA"
    printf "  %s%s%s\n" "${C_DIM}" "${TABLE_RULE}" "${C_RESET}"
}

# table_row <nome> <status> <acesso> <rede-interna>
table_row() {
    local name="$1" status="$2" access="$3" internal="$4" status_color="${C_YELLOW}"
    case "$status" in
        healthy|ok|ativo|running) status_color="${C_GREEN}" ;;
        starting|restarting|sem-healthcheck) status_color="${C_YELLOW}" ;;
        unhealthy|exited|dead|ausente|parado) status_color="${C_RED}" ;;
    esac
    printf "  %-15s %s%-10s%s %-42s %-20s\n" "$name" "$status_color" "$status" "${C_RESET}" "$access" "$internal"
}

print_table_footer() {
    printf "%s%s%s\n" "${C_DIM}" "${TABLE_RULE}" "${C_RESET}"
}
