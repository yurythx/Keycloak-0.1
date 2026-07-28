#!/usr/bin/env bash
# =============================================================================
# manage.sh - Console de gerenciamento interativo da stack (estilo TrueNAS)
#
# Menu ao vivo: status dos servicos, logs, reiniciar/parar/iniciar, backup,
# LDAP, uso de recursos, shell num container. So' pra uso interativo num
# terminal de verdade - nao e' pensado para automacao/CI (use deploy.sh
# para isso).
#
# Uso:
#   ./manage.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"
# shellcheck source=scripts/lib/services.sh
source "scripts/lib/services.sh"

[ -f docker-compose.yml ] || die "docker-compose.yml nao encontrado - rode este script na raiz do repositorio"
[ -f .env ] || die ".env nao encontrado - rode ./setup.sh primeiro"
command -v docker >/dev/null 2>&1 || die "Docker nao encontrado"

# Mesmo detalhe do deploy.sh: o Portainer e' um profile do Compose - sem
# isso exportado, "docker compose stop/start/restart" (sem nomear o
# servico) simplesmente ignora o Portainer, deixando ele orfao rodando
# (ou parado) fora de sincronia com o resto da stack.
if portainer_enabled; then
    export COMPOSE_PROFILES=portainer
fi

pause() {
    printf "\n  %sPressione Enter para continuar...%s" "${C_DIM}" "${C_RESET}"
    read -r _ || true
}

list_services() {
    docker compose ps --services 2>/dev/null
}

pick_service() {
    # pick_service "Titulo" [incluir_opcao_todos] -> devolve o nome via stdout, "" se invalido/cancelado
    local title="$1" with_all="${2:-0}"
    local -a services=()
    mapfile -t services < <(list_services)
    if [ "${#services[@]}" -eq 0 ]; then
        log_warn "Nenhum servico encontrado (a stack esta no ar?)" >&2
        return 1
    fi
    printf "\n  %s%s%s\n" "${C_WHITE}" "$title" "${C_RESET}" >&2
    [ "$with_all" = "1" ] && printf "   0) Todos\n" >&2
    local i=1
    for s in "${services[@]}"; do
        printf "  %2d) %s\n" "$i" "$s" >&2
        i=$((i + 1))
    done
    local choice idx
    choice=$(ask "Numero" "$([ "$with_all" = "1" ] && echo 0 || echo 1)")
    if [ "$with_all" = "1" ] && [ "$choice" = "0" ]; then
        printf "%s" "__ALL__"
        return 0
    fi
    idx=$((choice - 1))
    if [ "$idx" -ge 0 ] 2>/dev/null && [ "$idx" -lt "${#services[@]}" ] 2>/dev/null; then
        printf "%s" "${services[$idx]}"
        return 0
    fi
    log_err "Opcao invalida" >&2
    return 1
}

# -----------------------------------------------------------------------------
menu_logs() {
    local svc
    svc="$(pick_service "Ver logs de qual servico?" 1)" || { pause; return; }
    echo
    log_info "Modo follow - Ctrl+C para voltar ao menu"
    sleep 1
    if [ "$svc" = "__ALL__" ]; then
        docker compose logs -f --tail=100
    else
        docker compose logs -f --tail=100 "$svc"
    fi
    pause
}

menu_restart() {
    local svc
    svc="$(pick_service "Reiniciar qual servico?" 1)" || { pause; return; }
    # "up -d" em vez de "restart": "restart" reusa o container existente
    # com o ambiente que ele ja tinha na memoria, IGNORANDO qualquer
    # mudanca feita no .env desde entao (achado real em producao: troca
    # de dominio no .env + restart = continuou redirecionando pro
    # dominio antigo). "up -d" recria o container so' se algo no config
    # efetivo mudou - se nada mudou, e' um no-op seguro, entao serve tanto
    # pra "so' reiniciar" quanto pra "aplicar mudanca do .env".
    if [ "$svc" = "__ALL__" ]; then
        confirm "Reiniciar TODOS os servicos?" "N" || { log_info "Cancelado"; pause; return; }
        if docker compose up -d --force-recreate; then log_ok "Todos os servicos reiniciados"; else log_err "Falha ao reiniciar"; fi
    else
        if docker compose up -d --force-recreate "$svc"; then log_ok "'${svc}' reiniciado"; else log_err "Falha ao reiniciar '${svc}'"; fi
    fi
    pause
}

menu_stop() {
    confirm "Parar todos os contêineres (mantem os dados, sobe rapido de novo com a opcao Iniciar)?" "N" \
        || { log_info "Cancelado"; pause; return; }
    if docker compose stop; then log_ok "Stack parada"; else log_err "Falha ao parar a stack"; fi
    pause
}

menu_start() {
    local err
    if err="$(docker compose start 2>&1)"; then
        log_ok "Stack iniciada"
    else
        log_warn "Nao foi possivel iniciar (contêineres podem nao existir ainda)"
        log_info "Use a opcao 5 (Atualizar/redeploy) para criar a stack do zero"
        [ -n "$err" ] && log_err "$err"
    fi
    pause
}

menu_update() {
    confirm "Vai puxar a imagem mais recente do registry e reiniciar o Keycloak. Continuar?" "S" \
        || { log_info "Cancelado"; pause; return; }
    # MANAGE_SH_CONTEXT avisa o deploy.sh que ja estamos dentro do menu -
    # sem isso ele tentaria abrir um ./manage.sh novo ao final, aninhando.
    MANAGE_SH_CONTEXT=1 ./deploy.sh --no-menu || log_err "deploy.sh terminou com erro - veja a saida acima"
    pause
}

menu_backup() {
    if [ -x scripts/backup.sh ]; then
        ./scripts/backup.sh || log_err "Backup terminou com erro - veja a saida acima"
    else
        log_err "scripts/backup.sh nao encontrado ou sem permissao de execucao"
    fi
    pause
}

menu_restore_test() {
    if [ -x scripts/restore_test.sh ]; then
        ./scripts/restore_test.sh || log_err "Teste de restauracao terminou com erro - veja a saida acima"
    else
        log_err "scripts/restore_test.sh nao encontrado ou sem permissao de execucao"
    fi
    pause
}

menu_ldap() {
    if [ -x scripts/configure_ldap.sh ]; then
        ./scripts/configure_ldap.sh || log_err "configure_ldap.sh terminou com erro - veja a saida acima"
    else
        log_err "scripts/configure_ldap.sh nao encontrado ou sem permissao de execucao"
    fi
    pause
}

menu_stats() {
    local -a names=()
    mapfile -t names < <(docker compose ps --format '{{.Name}}' 2>/dev/null)
    if [ "${#names[@]}" -eq 0 ]; then
        log_warn "Nenhum contêiner rodando"
    else
        log_info "Modo ao vivo (estilo htop) - Ctrl+C para voltar ao menu"
        sleep 1
        docker stats "${names[@]}"
    fi
    pause
}

menu_shell() {
    local svc
    svc="$(pick_service "Abrir shell em qual contêiner?" 0)" || { pause; return; }
    log_info "Abrindo shell em '${svc}' (digite 'exit' para voltar ao menu)"
    docker compose exec "$svc" bash 2>/dev/null || docker compose exec "$svc" sh
    pause
}

# -----------------------------------------------------------------------------
show_menu() {
    printf "\n  %sO que deseja fazer?%s\n\n" "${C_WHITE}" "${C_RESET}"
    printf "   1) Ver logs\n"
    printf "   2) Reiniciar um servico\n"
    printf "   3) Parar a stack\n"
    printf "   4) Iniciar a stack\n"
    printf "   5) Atualizar (pull + redeploy)\n"
    printf "   6) Backup agora\n"
    printf "   7) Testar restauracao de backup\n"
    printf "   8) Configurar LDAP/AD\n"
    printf "   9) Uso de recursos (CPU/RAM)\n"
    printf "  10) Shell num contêiner\n"
    printf "  11) Atualizar esta tela\n"
    printf "   0) Sair\n"
}

while true; do
    [ -t 1 ] && clear
    print_header "PAINEL DE GERENCIAMENTO"
    print_services_panel
    show_menu
    CHOICE="$(ask "Escolha uma opcao" "11")"
    case "$CHOICE" in
        1) menu_logs ;;
        2) menu_restart ;;
        3) menu_stop ;;
        4) menu_start ;;
        5) menu_update ;;
        6) menu_backup ;;
        7) menu_restore_test ;;
        8) menu_ldap ;;
        9) menu_stats ;;
        10) menu_shell ;;
        11) : ;;
        0) printf "\n%sAte mais.%s\n\n" "${C_BGREEN}" "${C_RESET}"; exit 0 ;;
        *) log_err "Opcao invalida"; pause ;;
    esac
done
