# Monitoramento (Métricas para Zabbix/Prometheus) e Backup Externo

[← Índice](README.md)

Cobre duas coisas: quais métricas a stack expõe de verdade (e quais
**não** expõe, apesar de parecerem óbvias) para consumo por
Zabbix/Prometheus, e a garantia de que o backup do Postgres não cai
silenciosamente no disco local da VM.

## O que existe de verdade — verificado ao vivo, não por suposição

Antes de documentar qualquer endpoint, cada um foi testado contra a
stack rodando de verdade (`curl`/consulta real, não literatura oficial
lida por cima). Dois achados corrigiram uma expectativa inicial errada:

> **`keycloak_logins_total` / `keycloak_failed_login_attempts` não
> existem** nas métricas nativas do Keycloak, mesmo com
> `KC_METRICS_ENABLED=true` (já habilitado neste projeto). Esses nomes
> vêm de uma extensão SPI de **terceiros** (`keycloak-metrics-spi`,
> não mantida pela Red Hat/comunidade oficial do Keycloak) — decidiu-se
> **não instalar essa extensão** aqui, pelo risco de manutenção e
> incompatibilidade a cada major do Keycloak. Confirmado inspecionando
> `serverinfo` do Keycloak 26.7.0: os únicos `eventsListener` disponíveis
> são `workflow-event-listener`, `jboss-logging` e `email` — nenhum
> "metrics listener".
>
> **Sessões ativas também não aparecem no `/metrics`** (só existe
> `keycloak_session_expiration_task_seconds`, que é a duração da
> rotina de limpeza de sessões expiradas, não uma contagem de sessões
> ativas). A contagem real vem de outro lugar — a API Admin (ver
> [Sessões ativas](#sessões-ativas-scriptssession_statssh) abaixo).

O que **existe e cobre a necessidade real** (login com falha, tempo de
resposta), confirmado gerando um login real e um login com senha errada
de propósito e checando o `/metrics` antes/depois:

```
http_server_requests_seconds_count{method="POST",outcome="SUCCESS",status="200",uri="/realms/{realm}/protocol/{protocol}/token"} 7.0
http_server_requests_seconds_count{method="POST",outcome="CLIENT_ERROR",status="400",uri="/realms/{realm}/protocol/{protocol}/token"} 1.0
```

Ou seja: **login com sucesso e com falha são visíveis via `status` e
`outcome`** na mesma métrica genérica de requisições HTTP — não precisa
de contador dedicado. `http_server_requests_seconds_sum` /
`_count` (e os `_bucket` do histograma) dão o **tempo de resposta**.

## Onde estão os endpoints (internos, nunca publicados)

Mesma postura de segurança já usada pra `/health` do Keycloak — porta de
métricas **nunca** exposta em `ports:` nem exposta ao proxy reverso da
prefeitura, só alcançável de dentro da rede Docker (Zabbix/Prometheus
coletando de um agente/contêiner na mesma rede, ou da própria VM via IP
interno do contêiner):

| O quê | Onde | Formato |
|---|---|---|
| Keycloak (JVM, DB pool, HTTP, sessão) | `http://<ip-interno-do-keycloak>:9000/metrics` | Prometheus |

`KC_METRICS_ENABLED=true` já vem habilitado no `docker-compose.yml`. As
métricas do antigo proxy Traefik (requisições/latência do proxy) não
existem mais nesta stack — se precisar dessa camada, o servidor
web/proxy reverso da prefeitura provavelmente já expõe as próprias
métricas (confirme com quem o administra).

Pra descobrir o IP interno do contêiner numa VM real:
```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' keycloak_server
```

### Integração com Zabbix

Zabbix 6.4+ tem suporte nativo a métricas Prometheus (item tipo "Agente
HTTP" com passo de pré-processamento "Prometheus pattern") — aponte
direto pro endpoint interno acima, sem precisar de nenhum exportador
adicional. Para Zabbix mais antigo, um item externo/`UserParameter` que
roda `curl -s http://<ip>:9000/metrics | grep ...` no host da VM
(alcança o IP do contêiner diretamente, sem publicar porta) resolve
igual.

## Sessões ativas (`scripts/session_stats.sh`)

Como o `/metrics` não expõe contagem de sessões, este script consulta a
API Admin do Keycloak (`GET /admin/realms/{realm}/client-session-stats`,
endpoint real, confirmado ao vivo) via `kcadm.sh` dentro do contêiner —
mesmo padrão de autenticação já usado por `scripts/configure_ldap.sh`.

```bash
./scripts/session_stats.sh                  # tabela do realm "Prefeitura"
./scripts/session_stats.sh master            # tabela de outro realm
./scripts/session_stats.sh prefeitura --total  # so' o numero (Zabbix)
```

Testado ao vivo: autenticou como `kc_admin`, consultou o realm `master`
(3 sessões ativas do `admin-cli` nesta sessão de testes) e confirmou que
`--total` devolve só o número puro, pronto pra virar um item externo ou
`UserParameter` do Zabbix:
```
# /etc/zabbix/zabbix_agentd.d/keycloak.conf (no host da VM)
UserParameter=keycloak.sessions.active,/opt/keycloak-stack/scripts/session_stats.sh prefeitura --total
```

## Backup externo (garantido, não só documentado)

`scripts/backup.sh` sempre apontou por padrão pra `BACKUP_DIR=/mnt/backup_nfs`,
mas nada impedia que, se esse ponto de montagem nunca tivesse sido
configurado (ou caísse), o script continuasse escrevendo silenciosamente
no disco local da VM até enchê-lo — exatamente o risco que o backup
existe pra mitigar. Agora o script **compara o device do `BACKUP_DIR`
com o device da raiz (`/`)** (via `stat -c %d`) antes de gerar qualquer
dump, e **aborta** se forem o mesmo disco:

```
[..] AVISO: BACKUP_DIR (/mnt/backup_nfs) esta no mesmo disco da raiz do sistema - NAO e' armazenamento externo
[..] ERRO: abortando para nao arriscar encher o disco da VM. Monte um armazenamento externo ...
```

Testado ao vivo nos dois ramos: com um `BACKUP_DIR` no mesmo disco da
raiz (aborta, `exit 1`, nenhum dump gerado) e com
`REQUIRE_EXTERNAL_BACKUP=0` (prossegue e gera um dump real, comprimido e
válido — usar só em homologação/teste, nunca em produção). Compara por
**device**, não só se é um "mountpoint" exato — cobre também o caso de
`BACKUP_DIR` ser uma subpasta dentro do ponto de montagem externo.

## Rotação de logs do Docker

`x-logging` (`max-size: "10m"`, `max-file: "3"`) já está aplicado nos
serviços do `docker-compose.yml` (`postgres`, `keycloak`, `portainer`) —
confirmado revisando o arquivo, nada para corrigir. Validação em produção:
```bash
docker inspect keycloak_server --format='{{json .HostConfig.LogConfig}}'
```
(ver também [Etapa 5](05-golive-operacao.md#portão-de-validação)).
