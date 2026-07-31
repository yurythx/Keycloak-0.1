# Referência de Scripts

[← Índice](README.md)

Todos os scripts do repositório são idempotentes, com checagens de
pré-voo, e não fazem nenhuma ação destrutiva por padrão (as poucas que
são destrutivas exigem confirmação explícita ou uma flag adicional). O
bit de execução é versionado no próprio git — `git clone` em Linux já
entrega tudo executável.

| Script | Para que serve | Uso |
|---|---|---|
| [`setup.sh`](#setupsh) | Provisionamento inicial (segredos, certs, `.env`) | Etapa 1, uma vez |
| [`deploy.sh`](#deploysh) | Sobe/atualiza a stack | Etapa 1 em diante, a cada deploy |
| [`manage.sh`](#managesh) | Console de gerenciamento do dia a dia | Operação contínua |
| [`scripts/configure_ldap.sh`](#scriptsconfigure_ldapsh) | Federação com o AD | Etapa 3 |
| [`scripts/install_console_menu.sh`](#scriptsinstall_console_menush) | Menu automático no login | Opcional, uma vez |
| [`scripts/backup.sh`](#scriptsbackupsh) | Backup lógico do Postgres (Keycloak e Vaultwarden) + dados do Vaultwarden | Etapa 5, via cron |
| [`scripts/restore_test.sh`](#scriptsrestore_testsh) | Drill de restauração | Etapa 5, sob demanda |
| [`scripts/session_stats.sh`](#scriptssession_statssh) | Sessões ativas (API Admin) | Monitoramento, sob demanda ou via Zabbix |
| [`scripts/diagnose_502.sh`](#scriptsdiagnose_502sh) | Diagnóstico de 502 no proxy externo | Troubleshooting, sob demanda |
| [`scripts/vaultwarden_create_user.py`](#scriptsvaultwarden_create_userpy) | Cria conta no Vaultwarden com senha pré-definida | Etapa 6, provisionamento inicial |

---

## `setup.sh`

Prepara o terreno: valida Docker/Compose/openssl, cria `secrets/` e
`certs/`, gera o `.env` (interativo) e os segredos de 32 caracteres.
**Nunca sobrescreve** segredo já existente — para reconfigurar do zero,
apague o `.env`/arquivo específico antes.

```bash
./setup.sh                 # interativo
./setup.sh --yes           # aceita os padrões sem perguntar (CI/automação)
./setup.sh --no-anim       # desativa a animação de abertura
```

Segredos gerados são **alfanuméricos puros** (sem `+`, `/`, `=`) de
propósito: segredos base64 "crus" quebram testes com `curl -d` sem
`--data-urlencode` (ver nota na [Etapa 2](02-configuracao-keycloak.md)).

Durante a execução, pergunta também se você quer habilitar o
[Portainer](#portainer) — grava a resposta em `ENABLE_PORTAINER` no
`.env` — e pede o IP do proxy reverso da prefeitura, a porta e o bind de
exposição do Keycloak no host (ver [Proxy reverso externo](#proxy-reverso-externo)).

> **Não há arquivo de certificado pra gerenciar nesta stack.** TLS é
> responsabilidade do servidor web/proxy reverso que a prefeitura já
> opera, fora daqui — o Keycloak só fala HTTP puro. Se o navegador
> recusar acesso a um domínio que ele já visitou antes via HTTPS com
> HSTS ativo (sem oferecer "Avançado → Continuar"), isso é comportamento
> do proxy externo (que envia `Strict-Transport-Security`), não desta
> stack — limpe em `chrome://net-internals/#hsts` → "Delete domain
> security policies" pra testar de novo.

---

## `deploy.sh`

Roda as checagens de pré-voo, puxa a imagem do Keycloak já construída e
escaneada pelo CI (ver [CI/CD e Registry](ci-cd.md)), sobe a stack e
aguarda os contêineres ficarem `healthy`. Ao final, mostra o painel de
serviços (status ao vivo, URL, IP:porta) e um resumo do deploy. Se algo
falhar, imprime os últimos logs automaticamente.

```bash
./deploy.sh                  # modo produção: pull do registry + up -d
./deploy.sh --build           # builda a imagem localmente (dev/homologação,
                               # sem depender do registry)
./deploy.sh --no-pull         # usa a imagem já em cache local, sem baixar de novo
./deploy.sh --configure-ldap  # roda scripts/configure_ldap.sh após a stack subir
./deploy.sh --logs            # segue os logs após o deploy ter sucesso
./deploy.sh --no-menu         # nao abre o ./manage.sh ao final (so' o deploy)
./deploy.sh --down            # derruba a stack (preserva o volume do Postgres)
./deploy.sh --down --purge    # derruba E apaga o volume do Postgres (destrutivo!)
./deploy.sh --timeout 300     # tempo máximo de espera pelos healthchecks (padrão 240s)
./deploy.sh --help            # todas as opções
```

O Portainer (se `ENABLE_PORTAINER=true` no `.env`) é ativado/desativado
automaticamente via profile do Compose — não precisa de flag para isso.

> **Checagem de conflito de porta**: antes de subir a stack, o
> `deploy.sh` confere se `KEYCLOAK_PORT` (e `9443`, se o Portainer estiver
> ativado) já está ocupada por **outro processo, fora desta stack**
> nesta máquina — falha cedo com uma mensagem clara em vez do erro
> genérico do Docker (`bind: address already in use`). Um redeploy
> normal (a própria stack já rodando) não dispara isso — a checagem
> só considera conflito real se o contêiner desta stack ainda não
> existir e a porta já estiver em uso mesmo assim.

Em **sessão interativa** (terminal de verdade), ao final de um deploy com
sucesso o [`./manage.sh`](#managesh) abre automaticamente, pra você já
cair direto no console de gerenciamento. Use `--no-menu` pra desativar
numa execução específica. Em automação/CI (sem terminal associado) isso
nunca acontece — a checagem é feita via `[ -t 0 ] && [ -t 1 ]`, então
scripts e pipelines não ficam presos esperando um menu.

---

## `manage.sh`

Console interativo (estilo o console de setup do TrueNAS) para operar a
stack no dia a dia, sem precisar decorar comandos `docker compose`:

```bash
./manage.sh
```

A cada tela, mostra o banner e o painel de serviços com **status ao
vivo** (consultado na hora — reflete o estado real, não uma foto de
quando o deploy terminou):

| # | Opção | O que faz |
|---|---|---|
| 1 | Ver logs | Escolhe um serviço (ou todos) e segue os logs (`Ctrl+C` volta ao menu) |
| 2 | Reiniciar um serviço | `docker compose up -d --force-recreate` num serviço específico ou em todos — recria o contêiner (não é um `restart` simples), então também aplica qualquer mudança feita no `.env` desde a última subida |
| 3 | Parar a stack | `docker compose stop` — mantém os dados, sobe rápido de novo |
| 4 | Iniciar a stack | `docker compose start` (contêineres já criados) |
| 5 | Atualizar | Roda `./deploy.sh` (pull da imagem mais recente + redeploy) |
| 6 | Backup agora | Roda `scripts/backup.sh` |
| 7 | Testar restauração de backup | Roda `scripts/restore_test.sh` |
| 8 | Configurar LDAP/AD | Roda `scripts/configure_ldap.sh` |
| 9 | Uso de recursos | `docker stats` **ao vivo** (estilo `htop`) de todos os contêineres — atualiza continuamente até `Ctrl+C` |
| 10 | Shell num contêiner | Abre um shell interativo (`bash`, com fallback pra `sh`) — útil para debug pontual |
| 11 | Atualizar esta tela | Redesenha o painel sem executar nada |
| 0 | Sair | Fecha o menu (a stack continua rodando normalmente) |

Só para uso interativo num terminal de verdade (não roda em CI/automação
— para isso use `deploy.sh` direto). Ativa automaticamente o profile do
Portainer (se habilitado) para que Parar/Iniciar/Reiniciar cubram o
Portainer também, não só o Keycloak/Postgres.

> **`docker compose restart` vs `docker compose up -d` — pegadinha real**:
> `restart` reusa o contêiner que já existe, com o ambiente que ele já
> tinha carregado na memória desde que subiu — **não relê o `.env`**. Se
> você editou o `.env` (ex.: trocou `KC_HOSTNAME`) e só der `restart`, a
> mudança **não** é aplicada, mesmo o contêiner reiniciando sem erro. Use
> sempre `docker compose up -d` (ou `./deploy.sh`, ou a opção 2 do
> `manage.sh`) depois de editar o `.env` — `up -d` recria o contêiner só
> se algo no config efetivo mudou (senão é um no-op seguro). Achado real
> em produção: trocar `KC_HOSTNAME` no `.env` e dar `restart` deixou o
> Keycloak redirecionando pro domínio antigo indefinidamente.

### `scripts/install_console_menu.sh`

Por padrão o `manage.sh` só aparece quando você roda ele manualmente.
Este script faz o menu aparecer **automaticamente toda vez que alguém
logar na VM** (via SSH ou no console local do hypervisor/nuvem):

```bash
sudo ./scripts/install_console_menu.sh              # instala
sudo ./scripts/install_console_menu.sh --uninstall   # remove
```

Como funciona: instala um hook em
`/etc/profile.d/keycloak-manage-menu.sh`, que o Linux roda
automaticamente em todo **shell de login interativo** — cobre SSH e o
console local com o mesmo mecanismo, sem precisar de duas instalações
separadas. Escolher **"0) Sair"** no menu não fecha a sessão: devolve o
terminal pro shell normal (é um subprocesso, não substitui o shell).

**Sessões não-interativas continuam normais**: `ssh vm "comando"`, `scp`,
`rsync`, Ansible etc. não passam por `/etc/profile.d` — só shells de
*login* interativos disparam o hook. Confirmado com um teste real (SSH de
verdade contra um contêiner com `sshd`, chave pública) antes deste script
ser incorporado ao repositório: login interativo mostra o menu e depois
cai no shell normal; `ssh vm "echo x"` não mostra nada. Para pular o menu
numa sessão específica sem desinstalar:
```bash
ssh usuario@vm bash --noprofile --norc
```

> Requer `sudo` porque grava em `/etc/profile.d/` (fora deste
> repositório, afeta todo login na VM). É o único script deste projeto
> que mexe em configuração do sistema — todos os outros vivem inteiramente
> dentro da pasta do repositório.

---

## Proxy reverso externo

Esta stack não tem proxy reverso próprio — TLS, redirect HTTP→HTTPS e
balanceamento de carga ficam a cargo do servidor web que a prefeitura já
opera, fora do `docker-compose.yml`. O Keycloak só publica **HTTP puro**
na porta do host definida em `KEYCLOAK_PORT` (padrão `18443`), via
`ports:` no serviço `keycloak` — sem nenhum contêiner de proxy no meio.

Três variáveis no `.env` controlam essa borda:

| Variável | Para que serve | Padrão |
|---|---|---|
| `KEYCLOAK_BIND` | IP local onde a porta é publicada (`0.0.0.0` se o proxy da prefeitura estiver noutra máquina; `127.0.0.1` se for na mesma) | `0.0.0.0` |
| `KEYCLOAK_PORT` | Porta do host que o proxy da prefeitura deve encaminhar | `18443` |
| `PROXY_TRUSTED_ADDRESSES` | IP/CIDR do proxy da prefeitura — só headers `X-Forwarded-*` vindos daqui são aceitos pelo Keycloak (`KC_PROXY_TRUSTED_ADDRESSES`) | *(obrigatório, sem padrão)* |

`setup.sh` pergunta os três interativamente e valida que
`PROXY_TRUSTED_ADDRESSES` não ficou vazio. **Sem essa variável apontando
pro IP real do proxy, o Keycloak não confia no `X-Forwarded-Proto` e
gera link `http://` em vez de `https://` nos fluxos OIDC** — sintoma
clássico dessa configuração faltando.

### O que passou a ser responsabilidade do proxy da prefeitura

Antes coberto por um Traefik dentro da stack, agora precisa estar
configurado no servidor externo:

- **Terminar TLS** e encaminhar em HTTP puro pra
  `http://<IP-da-VM>:<KEYCLOAK_PORT>`.
- **Redirect HTTP→HTTPS**.
- **Enviar `X-Forwarded-Proto`, `X-Forwarded-Host` e `X-Forwarded-For`**
  corretos — sem isso o Keycloak não reconhece a requisição como HTTPS
  (ver acima).
- **Headers de segurança** (`Strict-Transport-Security`,
  `X-Frame-Options: SAMEORIGIN` — não `DENY`, o Keycloak usa um iframe
  same-origin pro "status iframe" de SSO/SLO —, `X-Content-Type-Options:
  nosniff`).

### Firewall

O único acesso externo à VM que esta stack precisa é
`KEYCLOAK_PORT`, **restrito ao IP do proxy da prefeitura** (não aberto
pra internet nem pra rede inteira) — configurar isso no firewall de
borda (iptables/ufw), fora do escopo desta stack.

### Troubleshooting

O `deploy.sh` faz uma checagem local pós-deploy (`curl` com retry contra
`http://<KEYCLOAK_BIND>:<KEYCLOAK_PORT>/realms/master/.well-known/openid-configuration`)
— isso só valida que o **contêiner** está respondendo, não o caminho
completo via proxy externo. Se o Keycloak responde localmente mas o
domínio público não carrega, o problema está no proxy da prefeitura
(regra de encaminhamento, TLS ou firewall), não nesta stack. Se o
domínio carrega mas os links do fluxo OIDC saem em `http://`, revise
`PROXY_TRUSTED_ADDRESSES` e os headers `X-Forwarded-*` (seção acima).

#### Erro 502 Bad Gateway (proxy externo → esta stack)

Cenário comum quando as duas VMs (Keycloak e proxy/roteador da
prefeitura) são servidores aaPanel separados: o Keycloak sobe saudável e
fala com o Postgres normalmente, mas o domínio público retorna **502**.
Como o `502` é gerado pelo Nginx do *outro* servidor (não por esta
stack) quando ele não consegue obter uma resposta válida do backend, o
diagnóstico precisa separar as duas pontas:

1. Rode `./scripts/diagnose_502.sh` **nesta VM** (a do Keycloak) — ele
   confere, nessa ordem: contêiner saudável, resposta local em
   `http://127.0.0.1:<KEYCLOAK_PORT>/...`, se a porta está de fato em
   `LISTEN` no endereço certo (`0.0.0.0`, não só `127.0.0.1`), regras de
   `ufw` para `KEYCLOAK_PORT`, e o estado de `PROXY_TRUSTED_ADDRESSES`.
   Também disponível no `./manage.sh` (opção "Diagnosticar erro 502").
   Passe o IP do proxy como argumento (`./scripts/diagnose_502.sh
   <IP-do-proxy>`) para conferir se há regra de firewall específica pra
   ele.
2. **Se o script confirmar que o Keycloak responde localmente**, o
   problema não está nesta stack — os suspeitos, em ordem de frequência:
   - **Firewall desta VM bloqueando o IP do proxy.** Atenção: no
     aaPanel isso é **duas camadas independentes** — o firewall do SO
     (`ufw`/`iptables`) **e** a aba própria de Segurança/Firewall do
     painel aaPanel. Liberar só uma das duas não basta. Se a VM estiver
     em nuvem, o Security Group/Grupo de Segurança do provedor é uma
     terceira camada, checada antes das outras duas.
   - **Vhost do proxy (no aaPanel do *outro* servidor) apontando errado**
     — `proxy_pass` precisa ser `http://<IP-desta-VM>:<KEYCLOAK_PORT>`
     (HTTP puro; usar `https://` aqui derruba a conexão porque o
     Keycloak não fala TLS nessa porta) ou porta divergente do
     `KEYCLOAK_PORT` real em `.env`.
   - **Buffers de resposta pequenos no Nginx do proxy.** O Keycloak gera
     headers/cookies maiores que o padrão do Nginx (sessão, múltiplos
     realms/clients, SAML) — buffer padrão (4k/8k) causa `upstream sent
     too big header while reading response header from upstream` no log
     de erro do Nginx do proxy, que aparece pro usuário como 502. Ver
     [`docs/exemplo-nginx-proxy-externo.conf`](exemplo-nginx-proxy-externo.conf)
     para um vhost de referência já com `proxy_buffer_size`/
     `proxy_buffers` ajustados e os headers `X-Forwarded-*` corretos.
   - Confirme rodando **do servidor do proxy**: `curl -v
     http://<IP-desta-VM>:<KEYCLOAK_PORT>/realms/master/.well-known/openid-configuration`
     — timeout/connection refused aponta pro firewall; resposta 200 mas
     502 no navegador aponta pro vhost/buffers do proxy.
3. **Se o script apontar o contêiner como não saudável**, o problema
   está aqui — resolva com `docker compose logs keycloak` /
   `docs/01-provisionamento.md` antes de investigar o proxy: 502 é
   esperado enquanto o backend não responde de verdade.

---

## Portainer

Gerenciador visual do Docker, opcional. Ativado perguntando no
`setup.sh` (grava `ENABLE_PORTAINER` no `.env`) ou editando o `.env`
manualmente.

> **Atenção de segurança**: o Portainer precisa de acesso de leitura e
> escrita ao socket do Docker do host pra funcionar — isso equivale a
> acesso root na VM (quem controla o Docker controla todos os
> contêineres, inclusive o do Postgres). Por isso o bind padrão é
> `PORTAINER_BIND=127.0.0.1` — só acessível via SSH tunnel ou VPN da
> prefeitura:
> ```bash
> ssh -L 9443:127.0.0.1:9443 usuario@vm-da-prefeitura
> # depois acesse https://localhost:9443 no seu navegador
> ```
> Só mude `PORTAINER_BIND` para `0.0.0.0` (expõe na rede) se o firewall
> da prefeitura já filtrar quem chega na porta 9443 — nunca exponha
> direto na internet.

No primeiro acesso, o Portainer pede pra você criar o usuário admin dele
(senha própria, separada da do Keycloak) e usa um certificado
autoassinado que ele mesmo gera — o aviso de segurança do navegador
nesse primeiro acesso é esperado.

A imagem oficial do Portainer é baseada em `scratch` (sem shell, sem
`wget`/`curl`) — por isso ela não tem um `HEALTHCHECK` do Docker; o
`deploy.sh`/`manage.sh` tratam a ausência de healthcheck como "contêiner
rodando normalmente".

---

## `scripts/configure_ldap.sh`

Automatiza a [Etapa 3](03-federacao-ad.md) (federação com o Active
Directory) via `kcadm.sh` — CLI administrativo do próprio Keycloak,
chamado por dentro do contêiner, sem expor nenhuma porta administrativa
extra. Idempotente: rodar de novo atualiza a configuração existente em
vez de duplicar.

```bash
./deploy.sh --configure-ldap        # roda depois da stack subir healthy
./scripts/configure_ldap.sh         # ou direto, se a stack já estiver no ar
./scripts/configure_ldap.sh --yes   # aceita os padrões sem perguntar
```

Pergunta interativamente: realm, Connection URL, Bind DN, senha da conta
de bind (gravada em `secrets/ldap_bind_password.txt`, nunca em texto
plano no `.env`), Users DN e Groups DN — com valores padrão derivados de
`AD_DOMAIN`/`AD_DC_HOSTNAME` do `.env`. Cria o provider LDAP (vendor AD,
`READ_ONLY`, LDAPS) e o `group-ldap-mapper`, depois dispara o
"Synchronize all users".

> Os portões de validação completos (Test Connection, Test
> Authentication, login real de um servidor) continuam manuais — o
> script cobre a criação/atualização da configuração, não substitui a
> validação final. Ver [Etapa 3](03-federacao-ad.md#portão-de-validação).

Se o realm informado ainda não existir, o script cria um realm vazio
(sem grupos/clients) e avisa que a [Etapa 2](02-configuracao-keycloak.md)
ainda precisa ser feita à parte.

---

## `scripts/backup.sh`

Backup lógico diário dos bancos do Keycloak **e** do Vaultwarden (via
`pg_dump`, um dump `.sql.gz` para cada), mais um `.tar.gz` do volume de
dados do Vaultwarden (`rsa_key.pem`, anexos, sends, cache de ícones —
sem isso, dados cifrados ficam irrecuperáveis mesmo com o dump do banco
intacto, ver [Etapa 6](06-vaultwarden.md)). Compressão, checagem de erro
e retenção configurável em todos os artefatos.

```bash
./scripts/backup.sh
BACKUP_DIR=/mnt/outro/lugar RETENTION_DAYS=30 ./scripts/backup.sh
```

Gera três arquivos por execução: `keycloak_<data>.sql.gz`,
`vaultwarden_<data>.sql.gz` e `vaultwarden_data_<data>.tar.gz`. Se
qualquer um dos três falhar, o script continua tentando os demais mas
termina com código de saída != 0 (não mascara falha parcial).

Uso recomendado via cron (ver [Etapa 5](05-golive-operacao.md)):
```
0 2 * * * /opt/keycloak-stack/scripts/backup.sh >> /var/log/keycloak-backup.log 2>&1
```

Variáveis de ambiente: `BACKUP_DIR` (padrão `/mnt/backup_nfs`),
`RETENTION_DAYS` (padrão `14`), `REQUIRE_EXTERNAL_BACKUP` (padrão `1`).

> **Recusa rodar se `BACKUP_DIR` estiver no mesmo disco da raiz do
> sistema** (compara via `stat -c %d`, não só se é um "mountpoint"
> exato — cobre também uma subpasta dentro do ponto de montagem
> externo). Sem isso, se o NFS/disco externo nunca tivesse sido montado
> (ou caísse), o script continuaria escrevendo silenciosamente no disco
> local até enchê-lo — o próprio risco que o backup existe pra mitigar.
> `REQUIRE_EXTERNAL_BACKUP=0` permite prosseguir mesmo assim (só
> homologação/teste, nunca produção). Testado ao vivo nos dois ramos —
> ver [Monitoramento e Backup Externo](monitoramento.md).

---

## `scripts/restore_test.sh`

Drill de restauração: restaura o dump mais recente (ou um especificado)
num contêiner Postgres **descartável e isolado**, valida a integridade
dos dados, e remove o contêiner de teste ao final — sem tocar no banco de
produção em nenhum momento. Reconhece tanto os dumps `keycloak_*.sql.gz`
quanto `vaultwarden_*.sql.gz` que o `backup.sh` gera — sem argumento,
pega o mais recente entre os dois; passe o caminho explicitamente pra
testar os dois exatamente.

```bash
./scripts/restore_test.sh                       # usa o dump mais recente (qualquer um) em $BACKUP_DIR
./scripts/restore_test.sh /caminho/para/keycloak_20260101_020000.sql.gz
./scripts/restore_test.sh /caminho/para/vaultwarden_20260101_020000.sql.gz
```

Sai com `PASS` e a contagem de tabelas restauradas se tudo der certo, ou
mensagem de erro clara se o dump estiver corrompido ou a restauração
falhar. **Não** valida o `vaultwarden_data_*.tar.gz` (não é um dump SQL)
— confira esse arquivo manualmente com `tar tzf <arquivo>`.

---

## `scripts/session_stats.sh`

Sessões ativas por client, via API Admin do Keycloak
(`GET /admin/realms/{realm}/client-session-stats`) — o `/metrics`
nativo do Keycloak não expõe contagem de sessões, só métricas de
infraestrutura (ver [Monitoramento](monitoramento.md) para o porquê).

```bash
./scripts/session_stats.sh                    # tabela do realm "prefeitura"
./scripts/session_stats.sh master              # tabela de outro realm
./scripts/session_stats.sh prefeitura --total  # so' o numero (Zabbix UserParameter)
```

Mesmo padrão de autenticação via `kcadm.sh` já usado em
`scripts/configure_ldap.sh`. Testado ao vivo: autenticação real,
consulta ao realm `master`, tabela e modo `--total` conferidos.

---

## `scripts/diagnose_502.sh`

Diagnóstico de "502 Bad Gateway" reportado pelo proxy reverso externo.
Roda **nesta VM** (a do Keycloak) e responde a única pergunta que
importa antes de mexer em qualquer outra coisa: "o problema está nesta
stack, ou está na borda (firewall/proxy externo)?" — checa contêiner
saudável, resposta HTTP local, porta publicada no endereço certo,
regras de `ufw`, e o estado de `PROXY_TRUSTED_ADDRESSES`.

```bash
./scripts/diagnose_502.sh                 # checagens locais
./scripts/diagnose_502.sh <IP-do-proxy>   # tambem confere regra de firewall pra esse IP
```

Ver [checklist completo de 502](scripts-referencia.md#erro-502-bad-gateway-proxy-externo--esta-stack)
mais acima e [`docs/exemplo-nginx-proxy-externo.conf`](exemplo-nginx-proxy-externo.conf).

---

## `scripts/vaultwarden_create_user.py`

Cria uma conta no Vaultwarden com senha mestra **pré-definida**,
replicando em Python a criptografia client-side do Bitwarden (PBKDF2
pra derivar a chave mestra, HKDF pra "esticar" ela, AES-256-CBC +
HMAC-SHA256 pra proteger a chave simétrica do usuário e o par de chaves
RSA — o servidor nunca vê a senha em texto claro nem os dados
descriptografados). Usado pra provisionar a conta `suporte` inicial do
Vaultwarden sem depender do fluxo de convite por link (ver
[Etapa 6](06-vaultwarden.md#4-autorregistro-desligado--criar-a-primeira-conta-pelo-admin)).

Só funciona com `SIGNUPS_ALLOWED=true` no `docker-compose.yml` no
momento da execução — o próprio Vaultwarden recusa registrar se
estiver desligado (comportamento correto, é a mesma proteção contra
autorregistro público da Etapa 6). Requer `pip install cryptography`.

```bash
sed -i 's/SIGNUPS_ALLOWED: "false"/SIGNUPS_ALLOWED: "true"/' docker-compose.yml
docker compose up -d --force-recreate vaultwarden

python3 scripts/vaultwarden_create_user.py https://cofre.rondonopolis.mt.gov.br \
    suporte@rondonopolis.mt.gov.br "SenhaForte123!" "Suporte TI"

sed -i 's/SIGNUPS_ALLOWED: "true"/SIGNUPS_ALLOWED: "false"/' docker-compose.yml
docker compose up -d --force-recreate vaultwarden
```

Testado ao vivo durante o desenvolvimento desta stack: conta criada e,
na sequência, login real conferido (token de acesso emitido) com a
senha informada — inclusive depois de `SIGNUPS_ALLOWED` voltar pra
`false` (a restrição só afeta registro de conta nova, não login de
conta existente).
