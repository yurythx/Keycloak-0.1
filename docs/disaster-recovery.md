# Restauração Completa (Desastre) — Reconstruindo a Stack do Zero

[← Índice](README.md)

Este documento cobre o cenário **"a VM sumiu/corrompeu, preciso reconstruir
tudo em uma VM nova"** — diferente de [`scripts/restore_test.sh`](scripts-referencia.md#scriptsrestore_testsh),
que só valida um dump `.sql.gz` isolado sem tocar em produção. Aqui o
objetivo é: sair de "nada" e chegar em "stack completa, com as mesmas
configurações e integrações de antes do desastre" (Keycloak + Postgres, e
opcionalmente Vaultwarden).

## O que você precisa ter em mãos

Do [armazenamento externo de backup](monitoramento.md#backup-externo-garantido-não-só-documentado)
(`BACKUP_DIR`, nunca a própria VM que morreu), pegue os arquivos mais
recentes gerados por [`scripts/backup.sh`](scripts-referencia.md#scriptsbackupsh):

| Arquivo | Conteúdo | Por que é indispensável |
|---|---|---|
| `config_<data>.tar.gz` | `.env`, `secrets/`, `certs/`, `themes/`, `docker-compose.yml`, `Dockerfile` | **Sem isso a reconstrução não funciona de verdade.** `.env`/`secrets/`/`certs/` nunca foram versionados no git (`.gitignore`) — só existiam na VM que se perdeu. Sem `secrets/vw_sso_client_secret.txt` batendo com o valor já gravado no dump do Keycloak, o SSO do Vaultwarden quebra mesmo com os dois bancos restaurados corretamente. Sem `certs/`, a federação LDAPS com o AD falha na validação do certificado. |
| `keycloak_<data>.sql.gz` | Dump lógico do Postgres do Keycloak | Realms, clients, grupos, mapeamento de federação AD, usuários locais — toda a configuração "de negócio" vive aqui, não em arquivo nenhum. |
| `vaultwarden_<data>.sql.gz` (se usa Vaultwarden) | Dump lógico do Postgres do Vaultwarden | Cofres, organizações, itens. |
| `vaultwarden_data_<data>.tar.gz` (se usa Vaultwarden) | `rsa_key.pem`, anexos, sends, cache de ícones | Sem a `rsa_key.pem`, alguns dados cifrados do Vaultwarden ficam **irrecuperáveis** mesmo com o dump do banco intacto. |

Confirme os quatro arquivos antes de começar — reconstruir com só os dumps
de banco e sem o `config_<data>.tar.gz` dá numa stack que sobe mas com
integrações quebradas (LDAPS, SSO do Vaultwarden) e senhas diferentes das
que os operadores já conhecem.

> ⚠️ **Este runbook ainda não foi validado ao vivo** (ao contrário do
> `restore_test.sh`, que roda automatizado e é parte do Portão de
> Validação da [Etapa 5](05-golive-operacao.md)). Antes de confiar nele
> num desastre real, rode um **drill completo** — os passos abaixo,
> numa VM descartável (ou até localmente) — e ajuste o que não bater.
> Trate isso como um rascunho testado por raciocínio, não por execução.

## Passo a passo

### 1. Provisionar a VM nova
Docker, Docker Compose, firewall, etc. — mesmos pré-requisitos de sempre,
ver [Etapa 0](00-pre-requisitos.md) e [Etapa 1](01-provisionamento.md).
**Não rode `./setup.sh` ainda** — ele existe pra *gerar* segredos novos em
um primeiro deploy; aqui você vai *restaurar* os segredos que já existiam,
não gerar outros.

### 2. Trazer o código e sobrepor com a configuração real
```bash
git clone https://github.com/yurythx/Keycloak-0.1.git
cd Keycloak-0.1

# sobrescreve .env, secrets/, certs/, themes/, docker-compose.yml e
# Dockerfile com o que realmente estava rodando em produção (inclusive
# qualquer ajuste feito direto na VM sem passar por commit)
tar xzf /caminho/do/backup/config_<data>.tar.gz -C .
```
O `git clone` sozinho já traz `docker-compose.yml`/`Dockerfile`/`themes/`
(estão versionados), mas o `tar xzf` por cima garante que bate
**exatamente** com o que estava em produção no momento do backup — inclui
`.env`/`secrets/`/`certs/`, que o git nunca teve.

### 3. Subir só o banco, restaurar os dumps, e só então o resto
A ordem importa: se o Keycloak subir primeiro contra um banco vazio, ele
inicializa um realm `master` novo — que depois entra em conflito com o
dump que você quer restaurar por cima.

```bash
docker compose up -d postgres
# espera ficar healthy
docker compose ps postgres

gunzip -c /caminho/do/backup/keycloak_<data>.sql.gz \
  | docker compose exec -T postgres psql -U "$(grep ^POSTGRES_USER= .env | cut -d= -f2)" \
      -d "$(grep ^POSTGRES_DB= .env | cut -d= -f2)"
```

Se usa Vaultwarden, mesmo padrão pro banco dele:
```bash
docker compose up -d vaultwarden-db
docker compose ps vaultwarden-db

gunzip -c /caminho/do/backup/vaultwarden_<data>.sql.gz \
  | docker compose exec -T vaultwarden-db psql -U "$(grep ^VW_POSTGRES_USER= .env | cut -d= -f2)" \
      -d "$(grep ^VW_POSTGRES_DB= .env | cut -d= -f2)"
```

E o volume de dados do Vaultwarden (precisa do container/volume já
existir antes de extrair dentro dele):
```bash
docker compose up -d vaultwarden
docker compose exec -T vaultwarden sh -c 'cd /data && tar xzf -' \
  < /caminho/do/backup/vaultwarden_data_<data>.tar.gz
docker compose restart vaultwarden
```

### 4. Subir o resto da stack
```bash
./deploy.sh
```

### 5. Validar (não presuma — confira cada integração)
- [ ] Login no realm `Prefeitura` funciona com um usuário federado do AD
      (confirma que `certs/` restaurou certo e a federação LDAPS está OK
      — ver [Etapa 3](03-federacao-ad.md)).
- [ ] `kc_admin` consegue logar no `/admin` com a senha de
      `secrets/kc_admin_password.txt` restaurada.
- [ ] Tema de login aparece certo (logo, cores) — confirma que `themes/`
      restaurou e o realm ainda aponta `loginTheme=prefeitura`.
- [ ] Se usa Vaultwarden: SSO do Vaultwarden loga sem erro de client
      secret (ver [docs/integracoes/vaultwarden.md](integracoes/vaultwarden.md))
      — é o teste mais direto de que `secrets/vw_sso_client_secret.txt`
      restaurado bate com o que já estava gravado no dump do banco do
      Keycloak.
- [ ] `scripts/backup.sh` roda limpo na VM nova (confirma que
      `BACKUP_DIR` foi remontado/reconfigurado — não presuma que o ponto
      de montagem externo sobrevive à troca de VM).

### 6. Apontar o proxy externo pra VM nova
Fora do escopo deste repositório (é infraestrutura da prefeitura, fora
desta stack) — atualizar o `upstream`/DNS do proxy reverso externo
(`sso.rondonopolis.mt.gov.br`) pro IP da VM nova. Ver
[docs/exemplo-nginx-proxy-externo.conf](exemplo-nginx-proxy-externo.conf)
como referência do que o proxy espera.

## O que este runbook não cobre

- **Portainer**: se usava (`ENABLE_PORTAINER=true`), o volume
  `portainer_data` (usuários/configuração do próprio Portainer) não é
  coberto pelo `backup.sh` — é secundário (só interface de administração),
  mas anote se fizer falta.
- **Métricas históricas** (Prometheus/Zabbix): não é responsabilidade
  desta stack, fica no lado do Zabbix/Prometheus.
- **Rollback parcial** (restaurar só um client ou um usuário sem sobrescrever
  o banco inteiro): este runbook é "tudo ou nada"; restauração seletiva
  exigiria `pg_restore` com filtro de tabela/schema, não coberto aqui.
