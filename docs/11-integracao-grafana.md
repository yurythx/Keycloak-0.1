# Etapa 11 — Integração Grafana ↔ Keycloak (SSO via OIDC)

[← Etapa 10](10-integracao-zabbix.md) · [Índice](README.md)

Documenta a integração real entre o Keycloak (realm `Prefeitura`) e um
Grafana OSS (`grafana/grafana-oss`), rodando no mesmo servidor do
Zabbix (`srvn8nglpi`, `192.168.0.181:3030`, stack em
`/home/dti/zabbix/docker-compose.yml`) — instalado com o plugin
`alexanderzobnin-zabbix-app` pra virar o painel de dashboards em cima
dos dados do Zabbix.

## 1. Por que foi mais rápido que as outras três

Diferente do GLPI (plugin externo) e do Zabbix (SAML), o Grafana OSS já
tem **suporte nativo a OIDC genérico** embutido, e o
`docker-compose.yml` já vinha com todas as variáveis
`GF_AUTH_GENERIC_OAUTH_*` pré-cadastradas (vazias/desligadas) —
alguém já tinha deixado o terreno pronto. Só faltou:
1. Preencher os valores no `.env`.
2. Adicionar duas variáveis que **não** vinham pré-cadastradas
   (`GF_SERVER_ROOT_URL` e `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH`/`_STRICT`)
   direto no `docker-compose.yml`.
3. Corrigir um bug (seção 3) que apareceu mesmo assim.

## 2. Client OIDC no Keycloak

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r Prefeitura \
    -s clientId=grafana \
    -s name='Grafana' \
    -s protocol=openid-connect \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s frontchannelLogout=true \
    -s 'redirectUris=["http://192.168.0.181:3030/login/generic_oauth"]' \
    -s 'webOrigins=["http://192.168.0.181:3030"]' \
    -s rootUrl='http://192.168.0.181:3030/' \
    -s 'attributes."access.token.lifespan"=1800'
```

> `access.token.lifespan=1800` aplicado **desde a criação** — é o bug
> que já tínhamos achado com o Vaultwarden
> ([docs/09 §4](09-vaultwarden-sso-producao.md#4-causa-raiz-3-access-token-expira-em-5-minutos-sem-refresh-funcional)),
> aplicado preventivamente em vez de esperar o sintoma aparecer de
> novo.

Mapper de grupos (necessário pro provisionamento automático por grupo
do AD, seção 4):
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients/<ID>/protocol-mappers/models -r Prefeitura \
    -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true'
```

Pega o secret:
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients/<ID>/client-secret -r Prefeitura
```

## 3. Achado: `GF_SERVER_ROOT_URL` — mesma classe de bug do Zabbix

**Sintoma**: o redirect pro Keycloak saía com
`redirect_uri=http://localhost:3000/login/generic_oauth` — o Grafana
usa `http://localhost:3000/` como base **por padrão** (a porta interna
do container, `3000`) pra montar essa URL, ignorando a porta publicada
externamente (`3030`). Isso não bate com o `redirectUris` cadastrado no
client do Keycloak, e travaria com `invalid_redirect_uri` — exatamente
o mesmo tipo de problema do `baseurl` do Zabbix
([docs/10 §3.3 e §4.1](10-integracao-zabbix.md#33-baseurl--nginx-interno-usa-a-porta-errada)),
causa raiz diferente (aqui é o Grafana que nunca soube sua própria URL
pública, não um proxy interno), mesma categoria de sintoma.

**Correção**: `GF_SERVER_ROOT_URL` não vinha pré-cadastrado no
`docker-compose.yml` — precisou ser adicionado:
```yaml
# docker-compose.yml, environment: do grafana
GF_SERVER_ROOT_URL: ${GF_SERVER_ROOT_URL:-http://localhost:3000/}
```
```bash
# .env
GF_SERVER_ROOT_URL=http://192.168.0.181:3030/
```

> **Lição pras próximas integrações**: sempre que uma ferramenta expõe
> uma "URL pública/base configurável" (Grafana: `root_url`; Zabbix:
> `baseurl`; e potencialmente qualquer outra coisa nova), **configurar
> isso explicitamente de cara**, antes mesmo de testar — em vez de
> esperar o sintoma de `redirect_uri` errado aparecer de novo.

## 4. Provisionamento automático por grupo do AD

Ao contrário do Zabbix (que tem uma estrutura de "user directory" +
"provision groups" dedicada) e do GLPI (que não tem nada disso), o
Grafana faz o mapeamento de grupo → papel (role) via uma expressão
**JMESPath** só, direto na variável de ambiente
`GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH` — mais simples de escrever,
mas tudo numa linha só, então fica menos legível:

```bash
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH=contains(groups[*], 'Grupo TI - Administradores') && 'Admin' || contains(groups[*], 'Grupo Nucleo de TI') && 'Admin' || contains(groups[*], 'Departamento de Tecnologia da Informação') && 'Admin' || contains(groups[*], 'Grupo Tecnologia da Informação') && 'Editor'
GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT=true
```

| Grupo AD | Papel no Grafana (org "Main") |
|---|---|
| `Grupo TI - Administradores` | Admin |
| `Grupo Nucleo de TI` | Admin |
| `Departamento de Tecnologia da Informação` | Admin |
| `Grupo Tecnologia da Informação` | Editor |
| Qualquer outro | **Login recusado** (`ROLE_ATTRIBUTE_STRICT=true` — se a expressão não bater com nada, o Grafana rejeita o login em vez de criar conta sem papel definido) |

Mesmos quatro grupos usados no mapeamento do Zabbix
([docs/10 §5](10-integracao-zabbix.md#5-provisionamento-automático-jit--mapeamento-final))
— reaproveitado de propósito, pra manter a régua de acesso consistente
entre as ferramentas de infraestrutura.

> Papéis do Grafana (nível de organização): `None`, `Viewer`, `Editor`,
> `Admin`. Existe também `GrafanaAdmin` (superadmin, acesso a
> configurações globais da instância, não só da org) — não usado aqui.

## 5. Testar sem senha real (fluxo OIDC via impersonation)

Mais simples que o do Zabbix (SAML) — parecido com o GLPI/Vaultwarden,
mas o Grafana tem uma cookie própria (`oauth_state`) que precisa ser
carregada da chamada inicial:

```bash
# 1. Impersonation no Keycloak
TOKEN=$(...)
USER_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/users?username=<usuario>&exact=true" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
curl -s -c /tmp/imp.txt -X POST -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/users/$USER_ID/impersonation" >/dev/null

# 2. Chama o Grafana - ele gera o redirect pro Keycloak E grava um cookie proprio (oauth_state)
LOC=$(curl -s -i -c /tmp/grafana_cookies.txt --max-redirs 0 http://192.168.0.181:3030/login/generic_oauth \
    | grep -i '^location:' | sed 's/^[Ll]ocation: //' | tr -d '\r')

# 3. Completa a autenticacao no Keycloak com a sessao impersonada (mesmo dominio das cookies!)
LOC_LOCAL=$(echo "$LOC" | sed 's#https://sso.rondonopolis.mt.gov.br#http://127.0.0.1:18443#')
CODE_LOC=$(curl -s -i -b /tmp/imp.txt --max-redirs 0 "$LOC_LOCAL" \
    | grep -i '^location:' | sed 's/^[Ll]ocation: //' | tr -d '\r')

# 4. Volta pro Grafana com o code, usando o cookie oauth_state do passo 2
#    "Location: /" = sucesso. Location de volta pro /login = negado (ROLE_ATTRIBUTE_STRICT bateu, sem grupo valido)
curl -s -i -b /tmp/grafana_cookies.txt --max-redirs 0 "$CODE_LOC" | head -5
```

Conferir o resultado direto pela API (login como `admin`):
```bash
curl -s -c /tmp/gf_admin.txt -X POST -H 'Content-Type: application/json' \
    -d '{"user":"admin","password":"<senha-admin>"}' http://192.168.0.181:3030/login
curl -s -b /tmp/gf_admin.txt http://192.168.0.181:3030/api/org/users   # confere o "role" de cada usuario
```

## 6. Achados de segurança — fora do escopo desta integração

Mesmo padrão dos outros três achados (não corrigido, só registrado):
- `GF_SECURITY_ADMIN_USER=admin` / `GF_SECURITY_ADMIN_PASSWORD=admin`
  — login padrão do Grafana ainda ativo.
- Mesma senha placeholder do Postgres (`SuaSenhaSeguraAqui123!`)
  compartilhada com o banco do Zabbix nesta stack.

## Portão de validação

- [ ] Client OIDC no Keycloak com `access.token.lifespan` > 300s desde
      a criação
- [ ] `GF_SERVER_ROOT_URL` configurado com o endereço público real
      (não `localhost:3000`)
- [ ] `redirect_uri` do primeiro redirect (`/login/generic_oauth`)
      bate exatamente com o `redirectUris` do client no Keycloak
- [ ] `GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT=true` — testado que
      usuário fora de todos os grupos mapeados é **recusado**, não
      criado com papel `None`/vazio
- [ ] Testado com pelo menos um usuário de cada grupo mapeado,
      `role` confirmado via `/api/org/users`
