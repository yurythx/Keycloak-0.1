#!/usr/bin/env bash
# =============================================================================
# diagnose_502.sh - Diagnostico de "502 Bad Gateway" reportado pelo proxy
# reverso externo da prefeitura (fora desta stack).
#
# Roda NESTA VM (onde o Keycloak esta publicado) e responde a unica pergunta
# que importa antes de mexer em qualquer outra coisa: "o problema esta nesta
# stack, ou esta na borda (firewall/proxy externo)?"
#
# Uso:
#   ./scripts/diagnose_502.sh                 # checagens locais
#   ./scripts/diagnose_502.sh <IP-do-proxy>    # tambem confere se esse IP
#                                                especifico tem rota liberada
#                                                no firewall local (ufw)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

[ -f .env ] || die ".env nao encontrado - rode este script na raiz do repositorio, apos ./setup.sh"

PROXY_IP="${1:-}"

KEYCLOAK_BIND_V="$(grep -E '^KEYCLOAK_BIND=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KEYCLOAK_PORT_V="$(grep -E '^KEYCLOAK_PORT=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
PROXY_TRUSTED_V="$(grep -E '^PROXY_TRUSTED_ADDRESSES=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KC_HOSTNAME_V="$(grep -E '^KC_HOSTNAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KEYCLOAK_BIND_V="${KEYCLOAK_BIND_V:-0.0.0.0}"
KEYCLOAK_PORT_V="${KEYCLOAK_PORT_V:-18443}"
CHECK_HOST="$KEYCLOAK_BIND_V"
[ "$CHECK_HOST" = "0.0.0.0" ] && CHECK_HOST="127.0.0.1"

print_header "DIAGNOSTICO - Erro 502 no proxy externo"
log_info "KC_HOSTNAME=${KC_HOSTNAME_V:-<vazio>}  KEYCLOAK_BIND=${KEYCLOAK_BIND_V}  KEYCLOAK_PORT=${KEYCLOAK_PORT_V}"

# -----------------------------------------------------------------------------
step "1) Contêiner do Keycloak"
# -----------------------------------------------------------------------------
STATE="$(docker inspect --format='{{.State.Status}}' keycloak_server 2>/dev/null || echo ausente)"
HEALTH="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' keycloak_server 2>/dev/null || echo ausente)"
if [ "$STATE" = "ausente" ]; then
    log_err "Contêiner 'keycloak_server' nao existe - rode ./deploy.sh"
    KC_UP=0
elif [ "$STATE" != "running" ]; then
    log_err "Contêiner 'keycloak_server' existe mas esta '${STATE}' - veja 'docker compose logs keycloak'"
    KC_UP=0
elif [ "$HEALTH" = "unhealthy" ]; then
    log_err "Contêiner rodando mas healthcheck 'unhealthy' - veja 'docker compose logs keycloak'"
    KC_UP=0
else
    log_ok "keycloak_server: ${STATE} / ${HEALTH}"
    KC_UP=1
fi

# -----------------------------------------------------------------------------
step "2) Keycloak responde localmente (antes de qualquer proxy)"
# -----------------------------------------------------------------------------
LOCAL_OK=0
if command -v curl >/dev/null 2>&1; then
    CODE="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://${CHECK_HOST}:${KEYCLOAK_PORT_V}/realms/master/.well-known/openid-configuration" 2>/dev/null || echo 000)"
    if [ "$CODE" = "200" ]; then
        log_ok "http://${CHECK_HOST}:${KEYCLOAK_PORT_V}/realms/master/.well-known/openid-configuration -> HTTP 200"
        LOCAL_OK=1
    else
        log_err "http://${CHECK_HOST}:${KEYCLOAK_PORT_V}/... -> HTTP ${CODE} (esperado 200)"
    fi
else
    log_warn "curl nao encontrado - pulei este teste"
fi

# -----------------------------------------------------------------------------
step "3) Porta ${KEYCLOAK_PORT_V} realmente publicada no host, no endereco certo"
# -----------------------------------------------------------------------------
PORT_LISTEN=""
if command -v ss >/dev/null 2>&1; then
    PORT_LISTEN="$(ss -tlnp 2>/dev/null | awk -v p=":${KEYCLOAK_PORT_V}" '$4 ~ p {print}')"
fi
if [ -n "$PORT_LISTEN" ]; then
    log_ok "Porta ${KEYCLOAK_PORT_V} em LISTEN:"
    printf "        %s\n" "$PORT_LISTEN"
    if echo "$PORT_LISTEN" | grep -q "127.0.0.1:${KEYCLOAK_PORT_V}"; then
        log_err "Esta escutando so' em 127.0.0.1 - o proxy externo (noutra maquina) NAO consegue alcancar. Confira KEYCLOAK_BIND no .env (deveria ser 0.0.0.0) e rode ./deploy.sh de novo"
    fi
else
    log_warn "Nao consegui confirmar via 'ss' (ausente ou sem permissao) - confira manualmente: ss -tlnp | grep ${KEYCLOAK_PORT_V}"
fi

# -----------------------------------------------------------------------------
step "4) Firewall LOCAL desta VM (ufw)"
# -----------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS="$(ufw status 2>/dev/null | head -1)"
    log_info "ufw: ${UFW_STATUS:-nao foi possivel checar (precisa de sudo?)}"
    if echo "$UFW_STATUS" | grep -qi "inactive"; then
        log_warn "ufw inativo - se o BT-Panel/aaPanel ou outro firewall de borda tambem estiver desativado, a porta ${KEYCLOAK_PORT_V} pode estar acessivel pra qualquer IP (risco), ou bloqueada em outra camada (o proprio 502)"
    else
        if ufw status 2>/dev/null | grep -q "${KEYCLOAK_PORT_V}"; then
            log_ok "Existe alguma regra ufw mencionando a porta ${KEYCLOAK_PORT_V}:"
            ufw status numbered 2>/dev/null | grep "${KEYCLOAK_PORT_V}" | sed 's/^/        /'
        else
            log_err "Nenhuma regra ufw pra porta ${KEYCLOAK_PORT_V} encontrada - se o ufw estiver 'active' com policy padrao deny, e' provavel causa do 502 (o proxy externo nem consegue conectar)"
        fi
    fi
else
    log_info "ufw nao instalado nesta VM - se o aaPanel usa firewalld/iptables direto, confira manualmente"
fi
log_warn "LEMBRETE (aaPanel): o painel do BT/aaPanel tem sua PROPRIA aba de Seguranca/Firewall, independente do ufw/iptables do SO. Uma regra so' no SO nao basta se a porta ${KEYCLOAK_PORT_V} nao estiver tambem liberada la' dentro do painel aaPanel desta VM."
log_warn "Se a VM estiver numa nuvem (AWS/Azure/GCP/provedor local com 'Security Group'/'Grupo de Seguranca'), confira TAMBEM essa camada - ela bloqueia antes mesmo do ufw/aaPanel verem o pacote."

if [ -n "$PROXY_IP" ]; then
    step "4b) Regra especifica para o IP do proxy informado (${PROXY_IP})"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "${PROXY_IP}"; then
            log_ok "Ha' regra ufw citando ${PROXY_IP}"
        else
            log_warn "Nenhuma regra ufw citando ${PROXY_IP} especificamente - considere: sudo ufw allow from ${PROXY_IP} to any port ${KEYCLOAK_PORT_V} proto tcp"
        fi
    fi
fi

# -----------------------------------------------------------------------------
step "5) PROXY_TRUSTED_ADDRESSES (nao causa 502, mas quebra o fluxo OIDC se errado)"
# -----------------------------------------------------------------------------
if [ -z "$PROXY_TRUSTED_V" ]; then
    log_err "PROXY_TRUSTED_ADDRESSES vazio no .env - preencha com o IP/CIDR real do proxy da prefeitura"
elif [ "$PROXY_TRUSTED_V" = "172.16.0.0/12" ]; then
    log_warn "PROXY_TRUSTED_ADDRESSES ainda esta na faixa generica de exemplo (172.16.0.0/12) - troque pelo IP real do proxy externo em .env (nao causa o 502, mas gera link http:// em vez de https:// nos fluxos OIDC depois que o 502 for resolvido)"
else
    log_ok "PROXY_TRUSTED_ADDRESSES=${PROXY_TRUSTED_V}"
fi

# -----------------------------------------------------------------------------
step "Veredito"
# -----------------------------------------------------------------------------
if [ "$KC_UP" = "1" ] && [ "$LOCAL_OK" = "1" ]; then
    print_panel "O Keycloak esta OK nesta VM" \
        "O contêiner esta saudavel e responde em http://${CHECK_HOST}:${KEYCLOAK_PORT_V} localmente." \
        "Logo, o 502 NAO esta sendo causado por esta stack - o problema esta" \
        "entre o proxy externo e esta VM. Nessa ordem, verifique:" \
        " 1. Do servidor do PROXY, rode:" \
        "      curl -v http://<IP-DESTA-VM>:${KEYCLOAK_PORT_V}/realms/master/.well-known/openid-configuration" \
        "    'Connection refused'/timeout = firewall (ufw, aaPanel desta VM," \
        "    ou Security Group da nuvem) bloqueando o IP do proxy." \
        " 2. Confira o vhost/site do proxy no aaPanel DO OUTRO servidor:" \
        "    proxy_pass deve ser http://<IP-desta-VM>:${KEYCLOAK_PORT_V} (HTTP" \
        "    puro, NUNCA https - o Keycloak so' fala HTTP nesta porta)." \
        " 3. proxy_buffer_size/proxy_buffers pequenos demais no Nginx do proxy" \
        "    tambem geram 502 ('upstream sent too big header') com Keycloak," \
        "    que usa cookies/headers maiores que o padrao - ver" \
        "    docs/exemplo-nginx-proxy-externo.conf." \
        " 4. Ver docs/scripts-referencia.md#proxy-reverso-externo para o" \
        "    checklist completo."
elif [ "$KC_UP" = "1" ] && [ "$LOCAL_OK" = "0" ]; then
    print_panel "Contêiner saudavel, mas nao respondeu no endpoint HTTP" \
        "Incomum - confira 'docker compose logs keycloak' e se KEYCLOAK_BIND/" \
        "KEYCLOAK_PORT no .env realmente batem com o que foi publicado" \
        "(item 3 acima)."
else
    print_panel "O problema ESTA nesta stack" \
        "O contêiner do Keycloak nao esta saudavel/rodando. Resolva isso" \
        "primeiro ('docker compose logs keycloak', ./deploy.sh) antes de" \
        "investigar o proxy externo - o 502 e' esperado enquanto o backend" \
        "nao responde."
fi
