#!/usr/bin/env bash
# Funcoes compartilhadas para consultar e exibir o status dos servicos da
# stack (usadas por deploy.sh e manage.sh). Depende de scripts/lib/theme.sh
# ja estar carregado (table_row, print_table_title, etc).

container_ip() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null | awk '{print $1}'
}

host_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || true
}

# service_status <container> -> healthy|unhealthy|starting|running|exited|ausente
service_status() {
    local name="$1" state health
    state="$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null)" || { echo "ausente"; return; }
    health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$name" 2>/dev/null)"
    if [ "$health" != "-" ]; then
        echo "$health"
    else
        echo "$state"
    fi
}

portainer_enabled() {
    grep -qE '^ENABLE_PORTAINER=true' .env 2>/dev/null
}

# print_services_panel - le o .env e o estado atual dos conteineres e
# desenha o painel "STACK NO AR" (status ao vivo, nao um valor fixo).
print_services_panel() {
    local kc_hostname host_ip_v keycloak_ip postgres_ip portainer_bind portainer_ip keycloak_bind keycloak_port keycloak_addr

    kc_hostname="$(grep -E '^KC_HOSTNAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    host_ip_v="$(host_ip)"
    host_ip_v="${host_ip_v:-<IP-da-VM>}"
    keycloak_ip="$(container_ip keycloak_server)"
    postgres_ip="$(container_ip keycloak_db)"
    keycloak_bind="$(grep -E '^KEYCLOAK_BIND=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    keycloak_port="$(grep -E '^KEYCLOAK_PORT=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    keycloak_addr="${keycloak_bind:-0.0.0.0}"
    [ "$keycloak_addr" = "0.0.0.0" ] && keycloak_addr="$host_ip_v"

    print_table_title "STACK NO AR"
    table_row "keycloak" "$(service_status keycloak_server)" "${kc_hostname:-https://<KC_HOSTNAME>}/admin [proxy -> ${keycloak_addr}:${keycloak_port:-18443}]" "${keycloak_ip:-?}:8080 (interno)"
    table_row "postgres" "$(service_status keycloak_db)"     "sem acesso externo"                          "${postgres_ip:-?}:5432 (interno)"
    if portainer_enabled; then
        portainer_bind="$(grep -E '^PORTAINER_BIND=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
        portainer_ip="$(container_ip portainer)"
        table_row "portainer" "$(service_status portainer)" "https://${portainer_bind:-127.0.0.1}:9443" "${portainer_ip:-?}:9443"
    fi
    print_table_footer
}
