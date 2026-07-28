# Etapa 5 — Go-Live, Operação e Monitoramento Contínuo

[← Etapa 4](04-integracao-sistemas.md) · [Índice](README.md) · Próximo: [Verificação End-to-End →](verificacao-final.md)

Última etapa antes do go-live: políticas de segurança do realm, backup
automatizado, e as ferramentas do dia a dia para operar a stack depois
que ela está em produção.

## Ações

### 1. Brute Force Detection
`Realm Settings → Security Defenses → Brute Force Detection` — ativar.

### 2. MFA obrigatório para TI/Direção
Regra de `Conditional OTP` (TOTP) para contas dos grupos administrativos.

### 3. Backup diário automatizado
```bash
crontab -e
```
```
0 2 * * * /opt/keycloak-stack/scripts/backup.sh >> /var/log/keycloak-backup.log 2>&1
```
O script já cuida de compressão, checagem de erro, retenção **e recusa
rodar se `BACKUP_DIR` estiver no mesmo disco da raiz do sistema**
(garante que o backup vai para armazenamento externo de verdade, não
só por convenção de nome de pasta — ver
[Monitoramento e Backup Externo](monitoramento.md)). Configure o
`BACKUP_DIR` (padrão `/mnt/backup_nfs`) como um ponto de montagem real
antes de agendar o cron. Detalhes em
[Referência de Scripts](scripts-referencia.md#scriptsbackupsh).

### Métricas para Zabbix/Prometheus
`KC_METRICS_ENABLED=true` (Keycloak) já vem ativado por padrão nesta
stack — nenhuma configuração extra necessária pra começar a coletar.
Endpoints, o que cada um realmente expõe (e o que não expõe, como sessões
ativas — cobertas por `scripts/session_stats.sh`) e receitas de
integração com Zabbix estão
em [Monitoramento e Backup Externo](monitoramento.md).

### 4. Rotação da senha do admin (`kc_admin`)

Troque a senha do bootstrap admin sempre que ela tiver circulado por um
canal que não seja o `secrets/kc_admin_password.txt` do próprio servidor
— chat, ticket, e-mail, print de tela. Depois de exposta, considere
comprometida e rotacione, mesmo que o canal pareça confiável.

**Opção 1 — via Admin Console** (recomendada em produção, não exige
recriar o contêiner):
`Users → kc_admin → Credentials → Reset password`.

**Opção 2 — regenerar o arquivo de secret e recriar o contêiner**:
```bash
rm secrets/kc_admin_password.txt
./setup.sh --yes                              # regenera so' o que falta
docker compose up -d --force-recreate keycloak
```
> `KC_BOOTSTRAP_ADMIN_PASSWORD` só é aplicada pelo Keycloak na **primeira
> inicialização** do realm `master` — se o realm já existe, a Opção 2
> troca o segredo no arquivo mas o Keycloak ignora no boot seguinte; use
> a Opção 1 nesse caso. A Opção 2 vale mesmo para ambientes ainda não
> inicializados (primeiro deploy) ou de homologação recriados do zero.

## Operação contínua

Depois do go-live, o dia a dia é operado por dois scripts (detalhes
completos em [Referência de Scripts](scripts-referencia.md)):

- **`./manage.sh`** — console interativo estilo TrueNAS: status ao vivo,
  logs, reiniciar/parar/iniciar serviços, atualizar, backup, teste de
  restauração, configurar LDAP, uso de recursos, shell num contêiner.
- **`./scripts/install_console_menu.sh`** (opcional) — faz o `manage.sh`
  aparecer automaticamente em todo login na VM (SSH ou console local),
  igual ao console de setup do TrueNAS. Requer `sudo`.

### Portainer (opcional)
Se habilitado no `.env` (`ENABLE_PORTAINER=true`, perguntado pelo
`setup.sh`), sobe junto com `./deploy.sh`, acessível em
`https://127.0.0.1:9443` via SSH tunnel/VPN. Detalhes e considerações de
segurança em [Referência de Scripts](scripts-referencia.md#portainer).

## Portão de Validação

- [ ] **Drill de restauração**: rodar `scripts/restore_test.sh` (restaura
      o backup mais recente em um contêiner Postgres descartável e
      isolado, valida que as tabelas foram restauradas) — deve terminar
      com `PASS`.
- [ ] **Rotação de logs**: confirmar que os contêineres estão com
      `max-size: 10m` / `max-file: 3` aplicados:
      ```bash
      docker inspect keycloak_server --format='{{json .HostConfig.LogConfig}}'
      ```
- [ ] **Porta de métricas (Keycloak 9000)**: acessível **apenas
      internamente** (rede Docker), nunca publicada no host nem exposta ao
      proxy reverso da prefeitura. Prometheus/Zabbix devem coletar a
      partir de dentro da mesma rede Docker ou via um agente rodando na
      própria VM (ver [Monitoramento](monitoramento.md)).
- [ ] **Backup em armazenamento externo**: rodar `scripts/backup.sh` uma
      vez e confirmar que ele **não** aborta com o aviso de "mesmo disco
      da raiz do sistema" — se abortar, `BACKUP_DIR` ainda não está
      apontando para um ponto de montagem externo de verdade.

---
Próximo: **[Verificação End-to-End →](verificacao-final.md)**
