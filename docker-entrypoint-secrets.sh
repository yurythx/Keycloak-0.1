#!/bin/sh
# A imagem oficial do Keycloak NAO suporta nativamente o sufixo _FILE
# (diferente da imagem do Postgres). Este wrapper resolve isso: le os
# arquivos apontados por KC_DB_PASSWORD_FILE / KC_BOOTSTRAP_ADMIN_PASSWORD_FILE
# (montados via docker secrets em /run/secrets/*) e exporta as variaveis
# reais que o kc.sh espera, antes de iniciar o servidor.
set -e

if [ -n "$KC_DB_PASSWORD_FILE" ] && [ -f "$KC_DB_PASSWORD_FILE" ]; then
  KC_DB_PASSWORD="$(cat "$KC_DB_PASSWORD_FILE")"
  export KC_DB_PASSWORD
fi

if [ -n "$KC_BOOTSTRAP_ADMIN_PASSWORD_FILE" ] && [ -f "$KC_BOOTSTRAP_ADMIN_PASSWORD_FILE" ]; then
  KC_BOOTSTRAP_ADMIN_PASSWORD="$(cat "$KC_BOOTSTRAP_ADMIN_PASSWORD_FILE")"
  export KC_BOOTSTRAP_ADMIN_PASSWORD
fi

exec /opt/keycloak/bin/kc.sh "$@"
