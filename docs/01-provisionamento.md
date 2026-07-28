# Etapa 1 — Provisionamento de Infraestrutura e Subida da Stack

[← Etapa 0](00-pre-requisitos.md) · [Índice](README.md) · Próxima etapa: [Etapa 2 →](02-configuracao-keycloak.md)

Sobe a stack pela primeira vez: Ubuntu Server, Docker, os scripts de
automação (`setup.sh` + `deploy.sh`), e os quatro portões que provam que a
infraestrutura está correta antes de mexer em qualquer configuração do
Keycloak.

## Ações

### 1. Provisionar a VM
Ubuntu Server 24.04 LTS, sem interface gráfica, sem aaPanel. Instalar
Docker Engine + plugin Docker Compose v2.

### 2. Clonar o repositório e rodar o setup
```bash
git clone <url-do-repositorio> /opt/keycloak-stack
cd /opt/keycloak-stack
./setup.sh
```
`./setup.sh` cria `certs/`, `secrets/`, gera o `.env` de forma interativa
(pergunta domínio, IP do proxy reverso da prefeitura, porta de exposição
do Keycloak, dados do AD, se quer o Portainer) e os segredos de 32
caracteres em `secrets/*.txt`. É idempotente — pode rodar de novo sem
sobrescrever nada que já existe. Detalhes de todas as flags em
[Referência de Scripts](scripts-referencia.md#setupsh).

> O bit de execução dos scripts já vem certo do `git clone` (versionado no
> próprio git). Se por algum motivo não estiver executável (ex.: baixou um
> `.zip` em vez de clonar), rode uma vez:
> `chmod +x setup.sh deploy.sh manage.sh scripts/*.sh scripts/lib/*.sh`

### 3. Apontar o proxy reverso da prefeitura
Esta stack não termina TLS nem faz redirect — isso é responsabilidade do
servidor web/proxy reverso que a prefeitura já opera, fora dela. Depois do
`./setup.sh`, confirme com quem administra aquele servidor:
- Que ele encaminha `https://<KC_HOSTNAME>` para
  `http://<IP-da-VM>:<KEYCLOAK_PORT>` (HTTP puro — o Keycloak não fala TLS
  diretamente).
- Que ele envia os headers `X-Forwarded-Proto`, `X-Forwarded-Host` e
  `X-Forwarded-For` corretos (senão o Keycloak gera link `http://` nos
  fluxos OIDC — ver [Referência de Scripts](scripts-referencia.md#proxy-reverso-externo)).
- Que `PROXY_TRUSTED_ADDRESSES` no `.env` está com o IP real desse proxy
  (não o valor de exemplo) e que o firewall da VM só libera
  `KEYCLOAK_PORT` para esse IP.

O único arquivo ainda copiado manualmente nesta etapa é:
- `certs/ad-ca.pem` — CA do Active Directory, pro Keycloak confiar no
  LDAPS (pode ser feito já aqui ou só na [Etapa 3](03-federacao-ad.md)).

### 4. Subir a stack
```bash
./deploy.sh
```
Isso puxa a imagem do Keycloak já publicada pelo CI (ver
[CI/CD e Registry](ci-cd.md)) e sobe tudo — **sem buildar nada na VM**.
Ao final, mostra um painel com o status de cada serviço, URL de acesso e
IP:porta interno.

> Se o pipeline de CI ainda não rodou nenhuma vez (primeiro deploy antes
> do primeiro `push` para `main`), use `./deploy.sh --build` para buildar
> localmente como alternativa temporária.

## Portão de Validação

- [ ] **Status dos contêineres**: `docker compose ps` mostra `keycloak_db`
      e `keycloak_server` como `healthy`.
- [ ] **Isolamento de rede**: tentar conectar na porta 5432 a partir de
      outra máquina da rede local — a conexão deve ser **recusada**
      (Postgres não publica porta no host e a rede `backend` é
      `internal: true`).
- [ ] **Keycloak local**: `curl http://127.0.0.1:<KEYCLOAK_PORT>/realms/master/.well-known/openid-configuration`
      na própria VM responde `200`. `./deploy.sh` já faz essa checagem
      automaticamente ao final do deploy.
- [ ] **Handshake TLS via proxy da prefeitura**: acessar
      `https://sso.rondonopolis.mt.gov.br/` no navegador (a partir de fora
      da VM) — tela de login do Keycloak carrega sem avisos de certificado.
      Se falhar, o problema está no proxy externo ou no encaminhamento pra
      `KEYCLOAK_PORT`, não nesta stack.
- [ ] **Liveness/readiness**: `/health/live` e `/health/ready` ficam na
      *management port* (9000) do Keycloak por padrão — **não** na porta
      pública `KEYCLOAK_PORT`, e essa porta **não é exposta** no host
      (evita vazar `/metrics` publicamente). Valide a saúde real assim, não
      pelo navegador:
      ```bash
      docker compose ps          # coluna STATUS deve mostrar "healthy"
      docker inspect --format='{{json .State.Health}}' keycloak_server
      ```

---
Próxima etapa: **[Etapa 2 — Configuração Básica do Keycloak →](02-configuracao-keycloak.md)**
