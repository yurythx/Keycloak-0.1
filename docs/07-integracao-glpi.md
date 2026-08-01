# Etapa 7 — Integração GLPI ↔ Keycloak (SSO)

[← Etapa 6](06-vaultwarden.md) · [Índice](README.md)

Documenta a integração **real**, testada e funcionando, entre o Keycloak
desta stack (realm `Prefeitura`) e um GLPI via plugin OIDC — feita e
lapidada num ambiente de homologação (`srvn8nglpi`, GLPI 11.0.6, fora
desta stack/repositório, mas na mesma rede). Este documento existe pra
**replicar** a integração num ambiente novo (outra homologação, ou a
produção real em GLPI 10.0.3) sem precisar redescobrir os mesmos
problemas.

> **Diferença importante em relação à Etapa 4**: `docs/04-integracao-sistemas.md`
> descreve o plano original (client `glpi-chamados`, genérico). Este
> documento descreve o que **realmente funcionou na prática**, com um
> plugin, nome de client e configuração diferentes — use este aqui como
> referência de implementação real.

## 1. Visão geral da arquitetura

```
Usuário do AD
    │
    ▼
GLPI (plugin "singlesignon")  ──── OIDC ────▶  Keycloak (realm Prefeitura)
    │                                              │
    │ callback.php/provider/1                      │ client "glpi-sso"
    ▼                                              ▼
Cria/atualiza usuário local no GLPI          Autentica contra o AD (LDAPS)
(perfil padrão + campos mapeados)             já configurado no realm
```

- **Client no Keycloak**: `glpi-sso`, no realm `Prefeitura` (não `prefeitura`
  minúsculo — ver [docs/06-vaultwarden.md](06-vaultwarden.md) sobre por
  que o realm certo é o maiúsculo).
- **Plugin no GLPI**: [`edgardmessias/glpi-singlesignon`](https://github.com/edgardmessias/glpi-singlesignon)
  (nome interno/diretório: `singlesignon`). Suporta múltiplos "providers"
  (múltiplos IdPs), mas aqui só usamos um (Keycloak).
- **Versão do plugin depende da versão do GLPI**:
  - GLPI **11.0.0 – 11.0.99** → plugin **v2.0.x** (usamos v2.0.3)
  - GLPI **~10.0.5** → plugin **v1.4.0** (não testado por nós ainda —
    ver seção 8, produção real está em 10.0.3, próximo de 10.0.5 mas
    não exato)

## 2. Configurar o client no Keycloak

Via `kcadm.sh` (mesmo padrão de `scripts/configure_vaultwarden_sso.sh`,
mas sem script dedicado ainda — feito manualmente via API neste caso):

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master --user kc_admin \
    --password "$(cat secrets/kc_admin_password.txt)"

docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r Prefeitura \
    -s clientId=glpi-sso \
    -s name="GLPI" \
    -s enabled=true \
    -s publicClient=false \
    -s protocol=openid-connect \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=true \
    -s frontchannelLogout=true \
    -s 'redirectUris=["http://<HOST-DO-GLPI>:<PORTA>/plugins/singlesignon/front/callback.php/","http://<HOST-DO-GLPI>:<PORTA>/plugins/singlesignon/front/callback.php/provider/1","http://<HOST-DO-GLPI>:<PORTA>/plugins/singlesignon/front/callback.php/*"]' \
    -s 'webOrigins=["http://<HOST-DO-GLPI>:<PORTA>"]' \
    -s rootUrl="http://<HOST-DO-GLPI>:<PORTA>/" \
    -s adminUrl="http://<HOST-DO-GLPI>:<PORTA>/"
```

Pega o `id` do client criado e o secret:
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients -r Prefeitura \
    -q clientId=glpi-sso --fields id
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get "clients/<ID>/client-secret" -r Prefeitura
```

### 2.1. Mapper de grupos (opcional, pra segmentação futura)

Adiciona um claim `groups` no token com os grupos do AD do usuário (útil
se um dia quiser mapear grupo → perfil/entidade no GLPI — ver seção 7,
isso **não está implementado no plugin ainda**, só a informação chega,
falta o que fazer com ela):

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients/<ID>/protocol-mappers/models -r Prefeitura \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true'
```

### 2.2. Access Token Lifespan — **não pule isso**

**Achado real**: o padrão do Keycloak (`accessTokenLifespan` do realm,
geralmente **300s / 5 minutos**) é curto demais pra esse tipo de sessão
OIDC. Sintoma: erro tipo *"Cannot refresh access token, no refresh token
or api keys are stored"* no meio do uso (achamos isso originalmente no
Vaultwarden, mas é uma característica do token, não do app — vale
checar/aplicar no `glpi-sso` também caso apareça algo parecido).

Fix (override só nesse client, não no realm inteiro — não afeta outros
clients tipo o admin console):
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh update clients/<ID> -r Prefeitura \
    -s 'attributes."access.token.lifespan"=1800'
```

## 3. Instalar o plugin no GLPI

### 3.1. ⚠️ Antes de tudo: garanta que `/var/www/glpi/plugins` é um volume persistente

**Achado real (causa de um incidente nesta integração)**: a imagem
oficial `glpi/glpi` do Docker **não monta `/var/www/glpi/plugins` em
volume nenhum por padrão** — só `/var/glpi/config`, `/var/glpi/files` e
`/var/www/glpi/marketplace` costumam vir montados. Se o plugin for
instalado direto ali sem um bind mount, ele **some inteiro** na próxima
vez que o container for recriado (`docker compose up -d --force-recreate`
ou até um simples update de imagem) — porque esse caminho fica na camada
gravável do container, que é descartada no recreate.

No `docker-compose.yml` do GLPI, garanta isto **antes** de instalar
qualquer plugin:
```yaml
services:
  glpi:
    volumes:
      - ./glpi-prod/config:/var/glpi/config
      - ./glpi-prod/files:/var/glpi/files
      - ./glpi-prod/marketplace:/var/www/glpi/marketplace
      - ./glpi-prod/plugins:/var/www/glpi/plugins   # <- ADICIONAR ISSO
```

### 3.2. Baixar e instalar o plugin

```bash
mkdir -p ./glpi-prod/plugins
cd /tmp
curl -sL -o singlesignon.tgz \
    https://github.com/edgardmessias/glpi-singlesignon/releases/download/v2.0.3/singlesignon.tgz
    # GLPI ~10.0.5: trocar v2.0.3 por v1.4.0 no link acima

cd <pasta-do-docker-compose-do-glpi>/glpi-prod/plugins
tar xzf /tmp/singlesignon.tgz
chown -R www-data:www-data singlesignon
rm /tmp/singlesignon.tgz

# aplica o volume mount da secao 3.1 (se ainda nao tinha) e recria:
docker compose up -d --force-recreate glpi
```

Confirma que o plugin foi reconhecido e está habilitado:
```bash
docker exec glpi-app php bin/console glpi:plugin:list
# deve mostrar "singlesignon | Single Sign-on | 2.0.3 | Habilitado"
```

> Se o plugin **já existia antes** (reinstalação após perda de arquivos,
> como aconteceu aqui) e o estado dele já estava `Habilitado` no banco
> (tabela `glpi_plugins`), ele **reconecta sozinho** com a configuração
> anterior (client ID, secret, mapeamentos de campo) — não precisa
> reconfigurar nada na tela do plugin, só repor os arquivos.

### 3.3. Corrigir `session.cookie_samesite` — **bug crítico, sempre necessário**

**Achado real (causa raiz do "ação não permitida" / 403 no callback)**:
a imagem oficial do GLPI já vem com um arquivo `glpi.ini` em
`/usr/local/etc/php/conf.d/` contendo:
```ini
session.cookie_samesite = "Strict"
```

Isso **quebra o retorno do fluxo OIDC**: quando o Keycloak redireciona de
volta pro GLPI (`.../plugins/singlesignon/front/callback.php/...`), é um
redirect **cross-site** (domínio do Keycloak → domínio do GLPI) — o
navegador **não envia** cookies `SameSite=Strict` nesse tipo de
navegação. O GLPI recebe a volta sem reconhecer a sessão que ele mesmo
criou segundos antes, e responde **403 Forbidden**. O próprio código-fonte
do GLPI documenta isso (`src/Glpi/System/Requirement/SessionsSecurityConfiguration.php`):
> "For instance, it will break oauthsso/oauthimap plugins."

**Fix**: criar um arquivo de override que carregue **depois** do
`glpi.ini` (ordem alfabética — por isso o prefixo `zzz-`):

```bash
mkdir -p ./php-overrides
cat > ./php-overrides/zzz-cookie-samesite.ini << 'EOF'
session.cookie_samesite = "Lax"
EOF
```

E no `docker-compose.yml`:
```yaml
    volumes:
      - ./php-overrides/zzz-cookie-samesite.ini:/usr/local/etc/php/conf.d/zzz-cookie-samesite.ini:ro
```

Recriar o container e confirmar:
```bash
docker compose up -d --force-recreate glpi
docker exec glpi-app php -i | grep -i samesite
# esperado: session.cookie_samesite => Lax => Lax

curl -s -I http://127.0.0.1:<PORTA>/ | grep -i set-cookie
# esperado: ...SameSite=Lax (nunca Strict)
```

### 3.4. Configurar o provider dentro do GLPI

Pela tela **Configurar → Geral → Single Sign-on** (ou direto no banco, é
a mesma tabela `glpi_plugin_singlesignon_providers`):

| Campo | Valor usado |
|---|---|
| Tipo | Generic OAuth2 / OpenID Connect |
| Nome | `SSO` (evite nomes técnicos tipo "keycloack" — vira texto do botão: "Entrar com `<nome>`") |
| Client ID | `glpi-sso` |
| Client Secret | o secret pego no passo 2 |
| URL de autorização | `https://<KC_HOSTNAME>/realms/Prefeitura/protocol/openid-connect/auth` |
| URL de token | `https://<KC_HOSTNAME>/realms/Prefeitura/protocol/openid-connect/token` |
| URL de userinfo | `https://<KC_HOSTNAME>/realms/Prefeitura/protocol/openid-connect/userinfo` |
| Scope | `openid profile email` |
| Auto-registro | Ligado (cria a conta no primeiro login) |
| Perfil padrão | `Self-Service` (ver seção 6 sobre por que isso pode confundir testes com conta de admin) |
| Entidade padrão | Entidade raiz (não há segmentação por secretaria ainda — ver seção 7) |

Mapeamento de campos (tabela `glpi_plugin_singlesignon_providers_fields`,
JSONPath sobre o `userinfo`/id_token) — o que usamos e funcionou com o
AD desta prefeitura (que expõe `userPrincipalName`, não `mail`, ver
[docs/06-vaultwarden.md](06-vaultwarden.md) sobre esse achado):

| Campo GLPI | JSONPath (em ordem de prioridade) |
|---|---|
| id | `$.id`, `$.username`, `$.sub` |
| email | `$.email`, `$['e-mail']`, `$['email-address']`, `$.mail` |
| username | `$.userPrincipalName`, `$.login`, `$.username`, `$.id`, `$.name`, `$.displayName`, `$.preferred_username` |
| firstname | `$.givenName` |
| lastname | `$.surname` |
| fullname | `$.displayName` |
| avatar_url | `$.picture` |

## 4. Texto do botão de login

O texto vem literalmente de `sprintf('Login with %s', $provider['name'])`
(`src/LoginRenderer.php` do plugin). Pra virar "Entrar com SSO", o campo
**Nome** do provider (seção 3.4) precisa ser `SSO` — não tem opção de
customizar a frase inteira, só o nome que entra no `%s`.

## 5. Testar sem precisar de senha real de ninguém

Técnica usada pra validar o fluxo ponta a ponta sem digitar a senha de
um usuário de AD de verdade: **impersonation do Keycloak** (o admin
`kc_admin` consegue gerar uma sessão válida como qualquer usuário, sem
saber a senha dele).

```bash
# 1. Token de admin
TOKEN=$(curl -s -X POST http://<KC-HOST>/realms/master/protocol/openid-connect/token \
    -d client_id=admin-cli -d grant_type=password -d username=kc_admin -d password="$(cat secrets/kc_admin_password.txt)" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

# 2. ID do usuario de teste
USER_ID=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/users?username=<usuario>&exact=true" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')

# 3. Impersonate -> grava cookies de sessao
curl -s -c /tmp/imp.txt -X POST -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/users/$USER_ID/impersonation" >/dev/null

# 4. Usa a sessao pra completar o /auth do client glpi-sso (sem tela de login)
curl -s -i -b /tmp/imp.txt --max-redirs 0 \
    "http://<KC-HOST>/realms/Prefeitura/protocol/openid-connect/auth?client_id=glpi-sso&response_type=code&scope=openid%20email%20profile&redirect_uri=<REDIRECT_URI_ENCODED>&state=teste" \
    | grep -i '^location:'
# a Location: tem o "code" real, de um login de verdade

# 5. Troca o code pelo token (pra inspecionar os claims, ex: conferir se "email" veio preenchido)
curl -s -X POST http://<KC-HOST>/realms/Prefeitura/protocol/openid-connect/token \
    -d grant_type=authorization_code -d code=<CODE-DO-PASSO-4> \
    -d redirect_uri=<REDIRECT_URI> -d client_id=glpi-sso -d client_secret=<SECRET> \
    | python3 -c 'import sys,json,base64; d=json.load(sys.stdin); idt=d["id_token"]; p=idt.split(".")[1]; p+="="*(-len(p)%4); print(json.loads(base64.urlsafe_b64decode(p)))'
```

## 6. Comportamento esperado (não são bugs)

- **Sessão única entre apps**: depois de logar via SSO uma vez, entrar
  em outro serviço integrado (Vaultwarden, outro sistema) não pede
  senha de novo — a sessão é do Keycloak, não de cada app. Pra trocar de
  usuário: aba anônima, ou encerrar a sessão em
  `https://<KC_HOSTNAME>/realms/Prefeitura/account`, ou limpar cookies
  do domínio do Keycloak. "Sair" de dentro do GLPI normalmente só
  encerra a sessão do GLPI, não a do Keycloak.
- **Perfil `Self-Service` em conta nova**: é o único perfil GLPI com
  `interface = helpdesk` (todos os outros usam `interface = central`) —
  é uma tela completamente diferente e mais simples, não é "central com
  menos direito". Se uma conta de teste que precisa de acesso de admin
  cair nesse perfil por padrão, pode parecer erro de permissão
  ("ação não é permitida") quando na real é só o perfil errado pra quem
  está logando.

## 7. Limitações conhecidas (não implementado)

- **Sem segmentação por secretaria**: só existe a "Entidade raiz" no
  GLPI. Criar entidades por secretaria (Saúde, Educação, etc.) e mapear
  automaticamente por grupo do AD é um projeto à parte — o plugin não
  tem gancho nativo pra isso (só suporta 1 perfil + 1 entidade padrão
  pra todo mundo, ou entidade por domínio de e-mail, que **parou de
  funcionar** depois que passamos a usar `userPrincipalName` como e-mail,
  já que todo mundo passa a ter o mesmo domínio `@<dominio>.local`).
- **Claim `groups` chega no token mas não é usado**: configuramos o
  mapper (seção 2.1) pensando nisso, mas o plugin não lê esse claim.
  Usar isso pra automatizar perfil/entidade por grupo exigiria escrever
  um hook/plugin companheiro em PHP (projeto futuro, não iniciado).
- **Higiene de credenciais**: no ambiente de homologação, o `.env` do
  GLPI tinha valores de placeholder (`change_me`) que **não batiam** com
  a senha real do banco em uso (a real estava só dentro de
  `/var/glpi/config/config_db.php`, dentro do container). Ao replicar,
  confirme que o `.env` reflete a senha real, ou documente onde ela
  realmente está.

## 8. Nota sobre a produção (GLPI 10.0.3)

A produção real está em **GLPI 10.0.3**, versão diferente da homologação
onde esta integração foi validada (11.0.6). Isso significa:
- Usar o plugin **v1.4.0** (não v2.0.3) — compatibilidade declarada como
  "~10.0.5", **não testada por nós** contra 10.0.3 exatamente. Testar
  antes de confiar.
- O bug do `session.cookie_samesite` (seção 3.3) só se aplica se a
  produção também rodar a imagem Docker oficial do GLPI — se for uma
  instalação tradicional (Apache/PHP direto no SO), o `glpi.ini` que
  causa o problema pode não existir; **conferir o `session.cookie_samesite`
  efetivo de qualquer forma** (`php -i | grep samesite` ou
  `phpinfo()`), independente de como o GLPI está instalado lá.
- Recomendação: montar um segundo ambiente de homologação **na mesma
  versão da produção (10.0.3)** antes de aplicar isso na produção de
  verdade — replicar esta integração ali primeiro, usando este documento
  como roteiro, e só then aplicar na produção.

## Portão de validação

- [ ] Client `glpi-sso` criado no realm `Prefeitura`, com `access.token.lifespan`
      maior que 300s
- [ ] `/var/www/glpi/plugins` é volume persistente (sobrevive a
      `docker compose up -d --force-recreate glpi`)
- [ ] `session.cookie_samesite` efetivo é `Lax` (nunca `Strict`)
- [ ] Plugin aparece "Habilitado" em `php bin/console glpi:plugin:list`
- [ ] Login SSO completo testado (idealmente com usuário real, não só
      impersonation) — sem 403, sem "ação não permitida" inesperado
- [ ] Texto do botão revisado (campo "Nome" do provider, não deixar
      nome técnico tipo "keycloack")
