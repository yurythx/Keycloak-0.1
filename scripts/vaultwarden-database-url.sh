#!/bin/sh
# Sourced automaticamente pelo /start.sh da imagem vaultwarden/server
# (executa tudo em /etc/vaultwarden.d/*.sh antes de rodar o binario) -
# nao roda sozinho, nao precisa de +x. Monta o DATABASE_URL com a senha
# lida do Docker secret, pra ela nunca aparecer em texto plano no .env
# (mesmo motivo do POSTGRES_PASSWORD_FILE do Postgres/Keycloak, so' que
# o Vaultwarden nao aceita um "_FILE" nativo pra DATABASE_URL inteira).
export DATABASE_URL="postgresql://${VW_POSTGRES_USER}:$(cat /run/secrets/vw_postgres_password)@vaultwarden-db:5432/${VW_POSTGRES_DB}"
