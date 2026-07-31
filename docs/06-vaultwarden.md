# Etapa 6 — Vaultwarden (Cofre de Senhas)

[← Etapa 5](05-golive-operacao.md) · [Índice](README.md) · Próximo: [Verificação End-to-End →](verificacao-final.md)

Sobe o Vaultwarden (servidor compatível com clientes Bitwarden) em
`https://cofre.rondonopolis.mt.gov.br`, como uma segunda stack dentro do
mesmo `docker-compose.yml` — banco, rede e segredos próprios, isolada do
Keycloak. Junto com o Keycloak, é um dos dois pilares de segurança desta
infraestrutura, então esta etapa tem o mesmo rigor das anteriores:
autorregistro fica **desligado por padrão**, contas são criadas
manualmente pelo administrador, e o login já nasce integrado ao SSO do
Keycloak (**ligado por padrão** nesta prefeitura).

## Ações

### 1. Provisionamento
Já coberto pelo `./setup.sh` da [Etapa 1](01-provisionamento.md) — ele
pergunta (ou, se o `.env` já existir de uma versão anterior sem
Vaultwarden, adiciona com os padrões e avisa pra você conferir):

- `VW_POSTGRES_DB` / `VW_POSTGRES_USER` — nome do banco e usuário
  (senha nunca fica em `.env`, vai para `secrets/vw_postgres_password.txt`).
- `VAULTWARDEN_BIND` / `VAULTWARDEN_HTTP_PORT` / `VAULTWARDEN_WS_PORT` —
  IP:porta do host onde o Vaultwarden fica exposto pro proxy reverso da
  prefeitura encaminhar (mesmo modelo do `KEYCLOAK_BIND`/`KEYCLOAK_PORT`).
- `VAULTWARDEN_DOMAIN` — URL pública do cofre (`https://cofre.rondonopolis.mt.gov.br`),
  **obrigatória** (`setup.sh` insiste até você preencher, mesmo
  tratamento do `PROXY_TRUSTED_ADDRESSES`). Achado real testando esta
  stack: com essa variável vazia o Vaultwarden não sobe com
  funcionalidade limitada — ele **recusa iniciar**
  (`DOMAIN variable needs to contain the protocol`) e fica em
  crash-loop.

`./setup.sh` também gera `secrets/vw_postgres_password.txt` e
`secrets/vw_admin_token.txt` (32 caracteres cada, mesma rotina dos
segredos do Keycloak).

### 2. Apontar o proxy reverso da prefeitura
Mesmo modelo da [Etapa 1](01-provisionamento.md#3-apontar-o-proxy-reverso-da-prefeitura):
confirme com quem administra o proxy externo que ele encaminha o
domínio/subdomínio do cofre para `http://<IP-da-VM>:<VAULTWARDEN_HTTP_PORT>`
(HTTP puro) e para `http://<IP-da-VM>:<VAULTWARDEN_WS_PORT>` (WebSocket,
usado pela sincronização em tempo real entre dispositivos) — ver
[`docs/exemplo-nginx-proxy-externo.conf`](exemplo-nginx-proxy-externo.conf)
como referência de vhost.

> **Diferença importante em relação ao Keycloak**: o Vaultwarden usa
> `IP_HEADER: X-Forwarded-For` para saber o IP real do cliente (exibido
> no histórico de login), mas — diferente do
> `PROXY_TRUSTED_ADDRESSES`/`KC_PROXY_TRUSTED_ADDRESSES` do Keycloak —
> ele **não valida de qual endereço o header veio**. O firewall
> restringindo `VAULTWARDEN_HTTP_PORT`/`VAULTWARDEN_WS_PORT` apenas ao
> IP do proxy da prefeitura é a única proteção contra isso; sem essa
> regra, qualquer um que alcance a porta diretamente pode forjar o IP
> que aparece no histórico de login/auditoria do cofre.

### 3. Subir o serviço
```bash
./deploy.sh
```
Sobe Keycloak e Vaultwarden juntos (mesma stack). Ao final, o painel de
serviços mostra `vaultwarden` e `vaultwarden-db` com o status de saúde, e
o script valida localmente `http://<VAULTWARDEN_BIND>:<VAULTWARDEN_HTTP_PORT>/alive`
antes do proxy externo entrar em cena — mesma lógica do Keycloak.

### 4. Autorregistro desligado — criar a primeira conta pelo admin
`SIGNUPS_ALLOWED` vem **fixo em `false`** no `docker-compose.yml` (não é
variável de `.env` de propósito, pra não regredir silenciosamente numa
edição futura) — achado de uma revisão de segurança: sem isso, qualquer
pessoa que alcance a URL pública cria conta própria no cofre da
prefeitura sem aprovação nenhuma, e o padrão do Vaultwarden é
autorregistro **aberto**.

Duas formas de criar conta, sem precisar de SMTP configurado:

**Opção 1 — convite pelo painel admin** (recomendada pro dia a dia):
1. Pegue o token do admin:
   ```bash
   cat secrets/vw_admin_token.txt
   ```
2. Acesse `https://cofre.rondonopolis.mt.gov.br/admin`, entre com esse
   token.
3. Aba **Users** → **Invite User** → informe o e-mail da pessoa.
4. Sem SMTP configurado, o Vaultwarden não envia e-mail nenhum — o link
   de convite/definição de senha aparece na própria tela do painel
   admin (ou em `docker compose logs vaultwarden`, dependendo da
   versão). Repasse esse link manualmente à pessoa (chat interno,
   ticket) pra ela definir a senha mestra.

**Opção 2 — conta com senha já definida** (usada pra provisionar a conta
`suporte` inicial): o fluxo normal de registro do Bitwarden calcula a
criptografia (derivação da chave mestra, chave simétrica do usuário, par
de chaves RSA) **no navegador**, então não dá pra simplesmente inserir
usuário/senha no banco. `scripts/vaultwarden_create_user.py` replica
essa criptografia (testado ponta a ponta: cria a conta e depois
consegue logar de verdade com a senha informada) — mas só funciona com
`SIGNUPS_ALLOWED=true` no momento da execução:

```bash
# 1. Ligar autorregistro temporariamente
sed -i 's/SIGNUPS_ALLOWED: "false"/SIGNUPS_ALLOWED: "true"/' docker-compose.yml
docker compose up -d --force-recreate vaultwarden

# 2. Criar a conta (troque a senha por uma definitiva antes de rodar em producao)
python3 scripts/vaultwarden_create_user.py https://cofre.rondonopolis.mt.gov.br \
    suporte@rondonopolis.mt.gov.br "suporte123" "Suporte TI"

# 3. Desligar autorregistro de novo - NAO pular este passo
sed -i 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' docker-compose.yml
docker compose up -d --force-recreate vaultwarden
```

> **`suporte123` é uma senha temporária e compartilhada — troque assim
> que alguém logar pela primeira vez.** Uma senha fixa e previsível
> numa conta que dá acesso ao cofre inteiro da prefeitura é exatamente
> o tipo de coisa que a Opção 1 (convite individual) evita; use a
> Opção 2 só pra provisionamento inicial, não como padrão pra contas
> novas.

> Se no futuro for necessário abrir autorregistro pra um grupo
> controlado (ex.: um domínio de e-mail específico da prefeitura, de
> forma permanente), isso é uma mudança deliberada no
> `docker-compose.yml` (`SIGNUPS_ALLOWED: "true"` + `SIGNUPS_VERIFY:
> "true"` + SMTP configurado + `SIGNUPS_DOMAINS_WHITELIST`) — diferente
> da janela curta e proposital da Opção 2 acima.

### 5. SSO — login via Keycloak (ligado por padrão)

O Vaultwarden desta versão fala OpenID Connect nativamente e autentica
contra **o mesmo Keycloak** desta stack (realm `prefeitura`, client
`vaultwarden`), em vez de senha local — `VAULTWARDEN_SSO_ENABLED=true`
já vem assim no `.env.example`. **Mas o client precisa existir de
verdade no Keycloak antes do primeiro deploy com SSO ligado** — sem
isso, `deploy.sh` recusa subir (ver preflight abaixo), o que é
intencional: melhor um erro claro do que o Vaultwarden em crash-loop
por `SSO_AUTHORITY`/secret vazios (achado real testando esta stack).

> **O que o SSO cobre e o que não cobre**: só o *login* (prova de quem é
> o usuário). A senha mestra/chave de criptografia do cofre continua
> sendo definida por cada usuário, separada do Keycloak — o SSO não
> elimina isso, é assim que o Bitwarden/Vaultwarden garante que nem o
> servidor consegue ler os dados guardados. Mantenha o login local
> habilitado pra pelo menos a conta admin (não crie ela via SSO), como
> plano B se o Keycloak ficar fora do ar.

**Caminho mais fácil — assistente pelo `manage.sh`:**
```bash
./manage.sh
# opção 10) Configurar SSO do Vaultwarden (client Keycloak)
```
Pergunta o realm e o client ID (com Enter pra manter o padrão), cria ou
atualiza o client no Keycloak automaticamente, **busca o secret direto
da API** (sem precisar copiar/colar — elimina o erro mais comum desse
processo), grava em `secrets/vw_sso_client_secret.txt`, atualiza o
`.env` e já recria o Vaultwarden. Ao final mostra o redirect URI/web
origin cadastrados, pra conferência.

**Ou manualmente**, via `kcadm.sh` (realm `prefeitura` — ainda não
existe? crie primeiro, ver [Etapa 2](02-configuracao-keycloak.md)):
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master --user kc_admin \
    --password "$(cat secrets/kc_admin_password.txt)"

docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r prefeitura \
    -s clientId=vaultwarden \
    -s enabled=true \
    -s publicClient=false \
    -s protocol=openid-connect \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s 'redirectUris=["https://cofre.rondonopolis.mt.gov.br/identity/connect/oidc-signin"]' \
    -s 'webOrigins=["https://cofre.rondonopolis.mt.gov.br"]'

# Pega o UUID do client criado, depois o secret dele
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients -r prefeitura \
    -q clientId=vaultwarden --fields id
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get "clients/<UUID-ACIMA>/client-secret" -r prefeitura
```
Ou pelo Admin Console: realm `prefeitura` → Clients → Create client →
mesmos valores acima (Client authentication **On**, Standard flow
**On**, Direct access grants pode desligar, redirect URI **exato**, sem
barra a mais/a menos — o Keycloak rejeita a autorização se não bater
com o que está cadastrado). Depois, cole o secret manualmente:
```bash
echo "<CLIENT_SECRET_DO_PASSO_ANTERIOR>" > secrets/vw_sso_client_secret.txt
docker compose up -d --force-recreate vaultwarden
```
As demais variáveis (`VAULTWARDEN_SSO_ENABLED`, `VAULTWARDEN_SSO_AUTHORITY`,
`VAULTWARDEN_SSO_CLIENT_ID`) já vêm certas no `.env` gerado pelo
`setup.sh` — só falta esse secret pra completar.

> **Achado real**: `VAULTWARDEN_SSO_AUTHORITY` precisa apontar pro
> **mesmo domínio/esquema** configurado em `KC_HOSTNAME` do Keycloak,
> exatamente. O Vaultwarden valida o `issuer` retornado pelo documento
> de descoberta OIDC contra a URL que ele usou pra buscar esse
> documento — se forem diferentes (ex.: `KC_HOSTNAME` público mas
> `SSO_AUTHORITY` apontando pra um atalho de rede interna), ele rejeita
> com `unexpected issuer URI` e devolve 400, mesmo com client/secret
> certos. Testado e confirmado durante o desenvolvimento desta stack.

**Testar**: acesse `https://cofre.rondonopolis.mt.gov.br`, opção
"Enterprise Single Sign-On" na tela de login, deve redirecionar pro
Keycloak, autenticar, e voltar logado no Vaultwarden. Ou, mais rápido,
`./manage.sh` → opção 11 (Verificar integração Vaultwarden ↔ Keycloak) —
confirma configuração, contêineres saudáveis, e o fluxo real de redirect
com PKCE, sem precisar abrir o navegador.

> Validado durante o desenvolvimento desta stack: o fluxo completo
> (Vaultwarden → redirect pro Keycloak com `client_id`/`redirect_uri`/PKCE
> corretos → login → código de autorização entregue de volta) funciona
> ponta a ponta contra um client OIDC de teste, incluindo o cenário de
> falha (issuer não batendo) sendo corretamente rejeitado. Ainda assim,
> teste de novo depois de criar o client de produção — o secret e o
> `VAULTWARDEN_DOMAIN` reais são únicos desse ambiente.

### 6. Backup e restore
`scripts/backup.sh` (mesmo cron da [Etapa 5](05-golive-operacao.md))
já cobre o Vaultwarden automaticamente — gera três arquivos por
execução:

- `keycloak_<data>.sql.gz` — banco do Keycloak (já existia).
- `vaultwarden_<data>.sql.gz` — banco do Vaultwarden.
- `vaultwarden_data_<data>.tar.gz` — o volume `/data` do contêiner
  Vaultwarden (`rsa_key.pem`, anexos, sends, cache de ícones). **Sem
  esse arquivo**, mesmo restaurando o dump do banco corretamente, dados
  cifrados que dependem da chave RSA da instância ficam irrecuperáveis
  — não é opcional, é parte do backup real do cofre.

`scripts/restore_test.sh` reconhece os dumps `keycloak_*` e
`vaultwarden_*` automaticamente (pega o mais recente de qualquer um dos
dois, ou aceite o caminho como argumento) e testa a restauração num
Postgres descartável, igual já fazia para o Keycloak. Ele **não** valida
o `.tar.gz` do volume de dados (não é um dump SQL) — confira esse
arquivo manualmente com `tar tzf <arquivo>` de vez em quando.

## Portão de Validação

- [ ] **Status dos contêineres**: `docker compose ps` mostra
      `vaultwarden` e `vaultwarden_db` como `healthy`.
- [ ] **Isolamento de rede**: `vaultwarden-db` não tem `ports:` no
      compose e a rede `vw_backend` é `internal: true` — tentar
      conectar na porta 5432 dela a partir de outra máquina da rede
      local deve ser **recusado**, mesma checagem já feita pro Postgres
      do Keycloak na [Etapa 1](01-provisionamento.md#portão-de-validação).
- [ ] **Autorregistro bloqueado**: com a stack fora do ar pro público
      (ou testando localmente contra `127.0.0.1:<VAULTWARDEN_HTTP_PORT>`),
      tentar criar uma conta pela tela normal de "Create Account" do
      cliente/web vault deve **falhar**.
- [ ] **Painel admin protegido**: acessar `/admin` sem o token não deve
      dar acesso ao painel (só à tela de login dele).
- [ ] **Primeira conta funcional**: convidar um usuário de teste pelo
      painel admin, completar a definição de senha mestra pelo link, e
      confirmar login normal no web vault.
- [ ] **Conta `suporte` provisionada**: `suporte@rondonopolis.mt.gov.br`
      criada via `scripts/vaultwarden_create_user.py` (Opção 2 da seção 4
      acima) consegue logar com a senha temporária — e a senha já foi
      trocada por uma definitiva, não fica com `suporte123` em produção.
- [ ] **Backup cobre os três artefatos**: rodar `scripts/backup.sh`
      manualmente e confirmar que gerou `keycloak_*.sql.gz`,
      `vaultwarden_*.sql.gz` **e** `vaultwarden_data_*.tar.gz` no
      `BACKUP_DIR`.
- [ ] **Restore testado**: `scripts/restore_test.sh` termina com `PASS`
      tanto pro dump mais recente do Keycloak quanto pro do Vaultwarden
      (rode passando o caminho de cada um explicitamente pra testar os
      dois, já que por padrão ele só pega o mais recente entre eles).
- [ ] **Se SSO estiver ligado**: login via "Enterprise Single Sign-On"
      completa o fluxo (redireciona pro Keycloak, autentica, volta
      logado) usando o client/secret **reais** de produção — o teste
      feito durante o desenvolvimento desta stack usou um client
      descartável, não substitui validar com o de verdade.

---
Próximo: **[Verificação End-to-End →](verificacao-final.md)**
