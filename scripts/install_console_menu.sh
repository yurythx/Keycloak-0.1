#!/usr/bin/env bash
# =============================================================================
# install_console_menu.sh - Faz o ./manage.sh aparecer automaticamente em
# todo login interativo na VM (SSH ou console local/hypervisor) - igual ao
# console de setup do TrueNAS.
#
# Mexe em /etc/profile.d/ (config do sistema, fora deste repositorio) -
# por isso e' um script separado e explicito, nao algo que roda escondido
# dentro do setup.sh. Precisa de root. Idempotente e reversivel.
#
# Como funciona: /etc/profile.d/*.sh roda automaticamente em todo shell de
# LOGIN interativo - cobre SSH (ssh usuario@vm) e o console local (agetty/
# systemd) ao mesmo tempo, sem precisar de dois mecanismos separados.
# Sessoes NAO-interativas (ssh vm "comando", scp, rsync, ansible) nao
# passam por /etc/profile.d - a automacao continua funcionando normal.
#
# Escape hatch: escolher "0) Sair" no menu devolve o terminal pro shell
# normal (o menu roda como subprocesso, nao substitui o shell). Para pular
# o menu numa conexao especifica sem desinstalar o hook:
#   ssh usuario@vm bash --noprofile --norc
#
# Uso:
#   sudo ./scripts/install_console_menu.sh              instala
#   sudo ./scripts/install_console_menu.sh --uninstall   remove
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

HOOK_FILE="/etc/profile.d/keycloak-manage-menu.sh"

install_hook() {
    [ "$(id -u)" = "0" ] || die "Precisa rodar como root: sudo ./scripts/install_console_menu.sh"
    [ -x "${SCRIPT_DIR}/manage.sh" ] || die "manage.sh nao encontrado/executavel em ${SCRIPT_DIR}"

    cat > "$HOOK_FILE" <<EOF
# Instalado por ${SCRIPT_DIR}/scripts/install_console_menu.sh em $(date '+%F %T')
# Mostra o console de gerenciamento da stack Keycloak em todo login
# interativo (SSH ou console local). Escolha "0) Sair" para cair no shell
# normal. Sessoes nao-interativas (ssh host comando, scp, rsync, ansible)
# NAO disparam isso - profile.d so roda em shell de login interativo.
if [ -t 0 ] && [ -x "${SCRIPT_DIR}/manage.sh" ]; then
    ( cd "${SCRIPT_DIR}" && ./manage.sh )
fi
EOF
    chmod 644 "$HOOK_FILE"
    log_ok "Hook instalado em ${HOOK_FILE}"
    log_info "Vale para SSH e para o console local (mesmo mecanismo, /etc/profile.d)"
    log_info "Para pular o menu numa conexao especifica: ssh usuario@vm bash --noprofile --norc"
    log_info "Para desinstalar: sudo ./scripts/install_console_menu.sh --uninstall"
}

uninstall_hook() {
    [ "$(id -u)" = "0" ] || die "Precisa rodar como root: sudo ./scripts/install_console_menu.sh --uninstall"
    if [ -f "$HOOK_FILE" ]; then
        rm -f "$HOOK_FILE"
        log_ok "Hook removido de ${HOOK_FILE}"
    else
        log_info "Hook nao estava instalado - nada a fazer"
    fi
}

case "${1:-}" in
    --uninstall) uninstall_hook ;;
    "") install_hook ;;
    -h|--help)
        echo "Uso: sudo ./scripts/install_console_menu.sh [--uninstall]"
        exit 0
        ;;
    *) die "Argumento desconhecido: $1 (use --help)" ;;
esac
