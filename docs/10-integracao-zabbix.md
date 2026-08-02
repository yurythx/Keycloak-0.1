# Etapa 10 — Integração Zabbix ↔ Keycloak (SSO via SAML)

[← Etapa 9](09-vaultwarden-sso-producao.md) · [Índice](README.md)

Documenta a integração real entre o Keycloak (realm `Prefeitura`) e um
Zabbix 7.0, feita no mesmo servidor de homologação do GLPI
(`srvn8nglpi`, `192.168.0.181:8085`). Diferente do GLPI e do Vaultwarden
(que falam OIDC), **o Zabbix só suporta SAML 2.0** — protocolo
diferente, com seus próprios problemas.

## 1. Por que SAML, não OIDC

O Zabbix (open-source, versões 6.0+) implementa SSO só via SAML 2.0
(biblioteca `onelogin/php-saml`, embutida na imagem oficial). Não tem
suporte nativo a OIDC/OAuth2. Isso muda a configuração inteira em
relação ao GLPI/Vaultwarden: em vez de `client_id`/`client_secret` e
`redirect_uri`, é `Entity ID`, certificado X.509 pra assinatura, e ACS
(Assertion Consumer Service) URL.

## 2. Client SAML no Keycloak

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r Prefeitura \
    -s clientId='http://192.168.0.181:8085' \
    -s name='Zabbix' \
    -s protocol=saml \
    -s enabled=true \
    -s 'redirectUris=["http://192.168.0.181:8085/*"]' \
    -s 'attributes."saml_assertion_consumer_url_post"="http://192.168.0.181:8085/index_sso.php?acs"' \
    -s 'attributes."saml_single_logout_service_url_post"="http://192.168.0.181:8085/index_sso.php?sls"' \
    -s 'attributes."saml.assertion.signature"=true' \
    -s 'attributes."saml.server.signature"=true' \
    -s 'attributes."saml.client.signature"=false' \
    -s 'attributes."saml_force_name_id_format"=true' \
    -s 'attributes."saml_name_id_format"=username' \
    -s 'attributes."saml.authnstatement"=true'
```

Mappers necessários (mandam `username` e `groups` como atributos SAML —
o Zabbix usa os dois: um pra identificar o usuário, outro pra decidir
grupo/permissão no provisionamento automático):

```bash
# username - vira o nome de login no Zabbix
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients/<ID>/protocol-mappers/models -r Prefeitura \
    -s name=username -s protocol=saml -s protocolMapper=saml-user-property-mapper \
    -s 'config."user.attribute"=username' \
    -s 'config."attribute.name"=username' \
    -s 'config."attribute.nameformat"=Basic'

# groups - usado pro provisionamento automatico (secao 6)
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients/<ID>/protocol-mappers/models -r Prefeitura \
    -s name=groups -s protocol=saml -s protocolMapper=saml-group-membership-mapper \
    -s 'config."attribute.name"=groups' \
    -s 'config."single"=true' \
    -s 'config."full.path"=false' \
    -s 'config."attribute.nameformat"=Basic'
```

> **`single=true` no mapper de grupos não é opcional** — ver achado #2
> na seção 5.

**Remove o scope `role_list`** do client (vem por padrão em todo client
SAML novo) — ver achado #2, causa um bug real se deixado.
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients/<ID>/default-client-scopes -r Prefeitura
# acha o id do "role_list" na lista, depois:
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/clients/<ID>/default-client-scopes/<ID-DO-ROLE_LIST>"
```

Pega o certificado de assinatura do realm (necessário pro Zabbix
confiar nas respostas):
```bash
curl -s http://<KC-HOST>/realms/Prefeitura/protocol/saml/descriptor > descriptor.xml
# extrai o <ds:X509Certificate> de dentro de <md:KeyDescriptor use="signing">
# formata como PEM (BEGIN/END CERTIFICATE, 64 colunas)
```

## 3. Configurar o Zabbix

### 3.1. Certificado do IdP — precisa de volume persistente

A imagem oficial `zabbix/zabbix-web-nginx-pgsql` já vem com
`zabbix.conf.php` esperando o certificado em
`/etc/zabbix/web/certs/idp.crt` (resolvido via `resolve_file()`, que só
aceita um arquivo real em disco — não aceita o conteúdo do certificado
direto por variável de ambiente). **Sem volume mount, o certificado some
no próximo `--force-recreate`** — mesmo problema que já tínhamos visto
com o plugin do GLPI ([docs/07-integracao-glpi.md §3.1](07-integracao-glpi.md#31-⚠️-antes-de-tudo-garanta-que-varwwwglpiplugins-é-um-volume-persistente)).

```yaml
# docker-compose.yml do Zabbix
services:
  zabbix-web:
    volumes:
      - ./certs/idp.crt:/etc/zabbix/web/certs/idp.crt:ro
```

```bash
mkdir -p ./certs
# cola o certificado PEM obtido na secao 2 em ./certs/idp.crt
chmod 644 ./certs/idp.crt
docker compose up -d --force-recreate zabbix-web
```

### 3.2. Criar o SAML userdirectory (via API, não pela UI)

```bash
TOKEN=$(curl -s -X POST http://<ZABBIX-HOST>/api_jsonrpc.php -H 'Content-Type: application/json-rpc' \
    -d '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"<senha>"},"id":1}' \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"])')

curl -s -X POST http://<ZABBIX-HOST>/api_jsonrpc.php -H 'Content-Type: application/json-rpc' -d '{
  "jsonrpc":"2.0",
  "method":"userdirectory.create",
  "params":{
    "idp_type":2,
    "name":"Keycloak SSO",
    "idp_entityid":"https://<KC_HOSTNAME>/realms/Prefeitura",
    "sso_url":"https://<KC_HOSTNAME>/realms/Prefeitura/protocol/saml",
    "slo_url":"https://<KC_HOSTNAME>/realms/Prefeitura/protocol/saml",
    "username_attribute":"username",
    "sp_entityid":"http://192.168.0.181:8085",
    "nameid_format":"urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
    "sign_assertions":1,
    "sign_messages":0, "sign_authn_requests":0, "sign_logout_requests":0,
    "sign_logout_responses":0, "encrypt_nameid":0, "encrypt_assertions":0,
    "scim_status":0
  },
  "auth":"'"$TOKEN"'", "id":2
}'
# idp_type: 1=LDAP, 2=SAML (constante IDP_TYPE_SAML, ver include/defines.inc.php)
```

Habilita o método de autenticação:
```bash
curl -s -X POST .../api_jsonrpc.php -d '{
  "jsonrpc":"2.0","method":"authentication.update",
  "params":{"saml_auth_enabled":"1","saml_case_sensitive":"0"},
  "auth":"'"$TOKEN"'","id":3
}'
```

### 3.3. `baseurl` — nginx interno usa a porta errada

**Achado real**: o Nginx dentro do container do Zabbix constrói URLs
usando a porta em que ele mesmo escuta (`8080`, interna), não a porta
publicada no host (`8085`, externa) — mesmo o `Host` header do request
chegando certo. Isso quebra o `RelayState`/ACS do SAML (o SP manda um
`AssertionConsumerServiceURL` errado, e o Keycloak rejeita com
`invalid_redirect_uri`).

**Correção**, via a variável de ambiente que o próprio `zabbix.conf.php`
já prevê pra isso:
```yaml
# docker-compose.yml, environment: do zabbix-web
ZBX_SSO_SETTINGS: '{"baseurl": "http://192.168.0.181:8085"}'
```
```bash
docker compose up -d --force-recreate zabbix-web
```

## 4. Achados/bugs corrigidos

### 4.1. `baseurl` — coberto na seção 3.3

### 4.2. "Found an Attribute element with duplicated Name"

Erro que aparece **na resposta do ACS do Zabbix** (não no Keycloak) —
sintoma de assinatura SAML tecnicamente válida, mas rejeitada na
validação. Causa: todo client SAML novo no Keycloak vem com o scope
padrão **`role_list`**, que gera **um `<Attribute Name="Role">` por
role do usuário** (múltiplos elementos com o mesmo `Name`) em vez de um
único elemento com múltiplos `<AttributeValue>`. O parser
`onelogin/php-saml` do Zabbix rejeita isso como ambíguo/inválido.

**Correção**: remover o scope `role_list` do client (seção 2) — não
precisávamos de roles do Keycloak no Zabbix mesmo.

> **O mesmo problema pode acontecer com QUALQUER mapper multi-valor**
> (como o de `groups` que adicionamos depois) **se `single` não for
> `true`**. Sempre usar `single=true` em mappers SAML de múltiplos
> valores.

### 4.3. Duas flags separadas pra ligar o provisionamento automático (JIT)

Configurar `userdirectory.provision_status=1` **não é suficiente**.
Existe uma segunda flag, **global**, em `authentication.saml_jit_status`
— as duas precisam estar em `1` (código-fonte, `index_sso.php`):
```php
$provisioning_enabled = ($provisioning->isProvisioningEnabled()
    && CAuthenticationHelper::getPublic(CAuthenticationHelper::SAML_JIT_STATUS) == JIT_PROVISIONING_ENABLED);
```

```bash
curl -s -X POST .../api_jsonrpc.php -d '{
  "jsonrpc":"2.0","method":"authentication.update",
  "params":{"saml_jit_status":"1","disabled_usrgrpid":"9"},
  "auth":"'"$TOKEN"'","id":4
}'
```

### 4.4. `disabled_usrgrpid` obrigatório antes de ligar o JIT global

A API recusa `saml_jit_status=1` sem um "grupo de usuários
desprovisionados" configurado primeiro (`disabled_usrgrpid`) — é pra
onde o Zabbix move usuários que perdem acesso a todos os grupos
mapeados. Usamos o grupo embutido `Disabled` (`usrgrpid=9`).

### 4.5. Nomes de grupo do AD parecidos, mas diferentes

**Achado real**: `Departamento de Tecnologia da Informação` e
`Grupo Tecnologia da Informação` são **dois grupos diferentes** no AD
(nomes parecidos, membros diferentes). Mapear só um deles deixa quem
está no outro sem acesso, com o sintoma "fica pedindo pra reautenticar
sempre e volta pro login" (na real, cada tentativa completa o
handshake SAML certinho, mas o Zabbix nega por falta de grupo mapeado —
o "SSO" técnico funciona, só não sobra permissão nenhuma pro usuário).
Sempre conferir o nome **exato** do grupo com quem está testando, não
assumir pela semelhança do nome.

## 5. Provisionamento automático (JIT) — mapeamento final

```bash
curl -s -X POST .../api_jsonrpc.php -d '{
  "jsonrpc":"2.0",
  "method":"userdirectory.update",
  "params":{
    "userdirectoryid":"1",
    "group_name":"groups",
    "user_username":"username",
    "provision_status":1,
    "provision_groups":[
      {"name":"Grupo TI - Administradores","roleid":"3","user_groups":[{"usrgrpid":"7"}]},
      {"name":"Grupo Nucleo de TI","roleid":"3","user_groups":[{"usrgrpid":"7"}]},
      {"name":"Departamento de Tecnologia da Informação","roleid":"3","user_groups":[{"usrgrpid":"7"}]},
      {"name":"Grupo Tecnologia da Informação","roleid":"2","user_groups":[{"usrgrpid":"14"}]}
    ]
  },
  "auth":"'"$TOKEN"'", "id":5
}'
```

| Grupo AD | Grupo de usuário Zabbix | Role |
|---|---|---|
| `Grupo TI - Administradores` | Zabbix administrators (7) | Super admin (3) |
| `Grupo Nucleo de TI` | Zabbix administrators (7) | Super admin (3) |
| `Departamento de Tecnologia da Informação` | Zabbix administrators (7) | Super admin (3) |
| `Grupo Tecnologia da Informação` | TI - Monitoramento SSO (14) | Admin (2) |
| Qualquer outro | — | **Barrado** (comportamento correto — Zabbix é ferramenta de infra, não precisa de acesso geral) |

> `roleid`: 1=User, 2=Admin, 3=Super admin, 4=Guest (`role.get` pra
> confirmar no ambiente de destino, os IDs podem variar).
>
> Ao adicionar um usuário a um grupo do AD que já está mapeado, **não
> precisa mexer em nada aqui** — o Zabbix reavalia o mapeamento a cada
> login (JIT também atualiza contas já existentes, não só cria novas).

## 6. Testar sem senha real (fluxo SAML via impersonation)

Mais trabalhoso que o equivalente OIDC ([docs/07 §5](07-integracao-glpi.md#5-testar-sem-precisar-de-senha-real-de-ninguém))
porque o SAML devolve um formulário HTML auto-submit, não um simples
redirect com `code`. Passo a passo:

```bash
# 1. Impersonation (cookies de sessao do Keycloak, MESMO DOMINIO da SAMLRequest)
TOKEN=$(...)  # token de admin
USER_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/users?username=<usuario>&exact=true" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
curl -s -c /tmp/imp.txt -X POST -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/users/$USER_ID/impersonation" >/dev/null

# 2. Pega o SAMLRequest que o Zabbix gera (SP-initiated)
LOC=$(curl -s -i --max-redirs 0 http://192.168.0.181:8085/index_sso.php \
    | grep -i '^location:' | sed 's/^[Ll]ocation: //' | tr -d '\r')

# 3. CRITICO: troca o dominio publico pelo mesmo host usado no passo 1
#    (as cookies de impersonation so valem pro dominio onde foram geradas -
#    se aqui usar sso.rondonopolis.mt.gov.br mas as cookies forem de
#    127.0.0.1, a sessao NAO e reconhecida e cai na tela de login)
LOC_LOCAL=$(echo "$LOC" | sed 's#https://sso.rondonopolis.mt.gov.br#http://127.0.0.1:18443#')

# 4. Usa a sessao pra completar o login e pegar o SAMLResponse (form auto-submit)
RESPONSE_HTML=$(curl -s -b /tmp/imp.txt "$LOC_LOCAL")
echo "$RESPONSE_HTML" | grep -oP 'name="SAMLResponse" value="\K[^"]+' > /tmp/saml_resp_raw.txt
python3 -c "import html; print(html.unescape(open('/tmp/saml_resp_raw.txt').read().strip()))" > /tmp/saml_response.txt

# 5. Submete pro ACS do Zabbix - 302 = sucesso, 200 com "msg-bad" = negado/erro
curl -s -i --data-urlencode 'SAMLResponse@/tmp/saml_response.txt' \
    --data-urlencode "RelayState=http://192.168.0.181:8085/index_sso.php" \
    "http://192.168.0.181:8085/index_sso.php?acs" | head -1
```

Pra depurar o conteúdo da assertion (conferir atributos, achar
duplicidade tipo o achado #2):
```bash
cat /tmp/saml_response.txt | base64 -d | grep -oE '<saml:Attribute[^>]*Name="[^"]+"'
```

## 7. Achado à parte: contas desativadas no AD dentro dos grupos de TI

Durante os testes, várias contas dentro dos grupos de TI mapeados
estavam **desativadas no AD** (`clauber.inacio`, `giovane.marques`,
`carlos.vanzeli`, `pedro.soares`, `douglas.rezende`) — não impede a
integração (o Keycloak/AD que barra o login, corretamente), só vale
avisar quem administra o AD pra confirmar se isso é intencional.

## 8. Segurança do Zabbix — pendências fora do escopo desta integração

Achados durante o processo, não corrigidos (fora do escopo de "fazer o
SSO funcionar"):
- Login `Admin`/`zabbix` (senha padrão) ainda ativo
- Senha do Postgres com placeholder (`TrocarEssaSenhaAntesDeSubir123!`,
  não trocada antes do primeiro deploy)

## Portão de validação

- [ ] Client SAML no Keycloak sem o scope `role_list`
- [ ] Mapper de `groups` com `single=true`
- [ ] `ZBX_SSO_SETTINGS` com `baseurl` correto (bate com a porta
      publicada externamente, não a interna do container)
- [ ] Certificado do IdP em volume persistente, não gravado direto no
      container
- [ ] `saml_jit_status` (global) **e** `provision_status` (por
      diretório) ambos ligados
- [ ] `disabled_usrgrpid` configurado
- [ ] Testado com pelo menos um usuário de cada grupo mapeado — nome
      exato do grupo conferido, não assumido pela semelhança
- [ ] Confirmado que usuário **fora** de todos os grupos mapeados é
      negado (comportamento esperado, não falha)
