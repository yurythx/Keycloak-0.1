# Federação com o AD: Ajustes Reais de Produção

[← Índice de Integrações](README.md) · [Documentação Geral](../README.md)

`docs/03-federacao-ad.md` descreve o **plano original** (LDAPS na porta
636, Users/Groups DN organizados em OUs específicas, tudo criado do zero
via `configure_ldap.sh`). Na prática, a federação real de produção **já
existia, configurada por fora deste repositório**, com um desenho
diferente do planejado. Este documento registra o que **realmente**
está configurado, os ajustes feitos nele, e os porquês — pra replicar
sem precisar redescobrir tudo nem quebrar o que já funciona.

## 1. O que a federação real é (diferente do plano)

| | Planejado (`03-federacao-ad.md`) | Real (produção) |
|---|---|---|
| Realm | `prefeitura` (minúsculo) | **`Prefeitura`** (maiúsculo) — ver achado abaixo |
| Protocolo | LDAPS, porta 636 | `ldap://` **sem TLS**, porta 389 |
| Bind DN | Conta de serviço dedicada | `adm.yuri@rondonopolis.local` |
| Users DN | `OU=Usuarios,DC=...` | `DC=rondonopolis,DC=local` (raiz do domínio, sem OU) |
| Criado por | `./scripts/configure_ldap.sh` | Manualmente, fora deste repositório, antes deste projeto |
| Usuários sincronizados | — | **12.751** |

### Achado crítico: dois realms coexistindo

O Keycloak desta stack, ao ser provisionado do zero, **cria e usa por
padrão** um realm `prefeitura` (minúsculo) vazio — mas a federação real
com o AD (com todos os usuários e grupos) já existia num realm
`Prefeitura` (maiúsculo) diferente, criado antes deste projeto, com
client SSO do GLPI já configurado nele.

Isso significa: **qualquer integração SSO apontada pro `prefeitura`
minúsculo (o que os scripts fazem por padrão) conversa com um realm
vazio, sem usuário nenhum de verdade** — funciona tecnicamente (redirect,
PKCE corretos) mas contra ninguém.

**Correção aplicada**: todos os defaults deste repositório (`setup.sh`,
`manage.sh`, `scripts/configure_ldap.sh`, `scripts/check_ad_status.sh`,
`scripts/configure_vaultwarden_sso.sh`, `scripts/session_stats.sh`,
`.env.example`) foram atualizados pra usar `Prefeitura` (maiúsculo) como
padrão — commit `e40947f`. O realm `prefeitura` (minúsculo, vazio) foi
apagado da produção.

**Ao replicar em outro ambiente**: antes de rodar qualquer script deste
repositório contra um AD/Keycloak que já tenha federação configurada,
**confirme o nome exato do realm real** (`kcadm.sh get realms --fields realm`)
antes de aceitar os defaults dos scripts.

## 2. E-mail: `mail` não serve, usar `userPrincipalName`

**Achado real**: o atributo `mail` do AD só estava preenchido pra **7,6%**
dos usuários (152 de uma amostra de 2.000) — a maioria dos servidores
públicos nunca teve caixa de e-mail cadastrada no AD. Sem `email` no
token, qualquer app SSO (Vaultwarden, GLPI) que exija esse claim recusa
o login (`Neither id token nor userinfo contained an email`, no caso do
Vaultwarden).

**Correção**: trocar a fonte do mapper de e-mail do LDAP, de `mail` pra
`userPrincipalName` — atributo que o **AD gera sozinho** pra toda conta
(formato `usuario@dominio.local`), sem precisar de cadastro manual.

```bash
# acha o mapper "email" do provider LDAP
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get components \
    -r Prefeitura -q parent=<ID-DO-PROVIDER-LDAP> | grep -B2 -A10 '"name" : "email"'

# troca o atributo fonte
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh update components/<ID-DO-MAPPER-EMAIL> -r Prefeitura \
    -s 'config."ldap.attribute"=["userPrincipalName"]'
```

Depois, dispara um sync completo pra aplicar a todo mundo (ver seção 5):
resultado real medido: cobertura de e-mail subiu de **7,6% para 83,4%**
— o que sobrou sem e-mail são quase só contas de máquina/serviço
(terminam em `$`, tipo `abaco-02745$`), não pessoas.

> **Bônus não-óbvio**: o mapper tem `always.read.value.from.ldap: false`
> por padrão — isso significa que **contas que já tinham e-mail
> preenchido não são sobrescritas** no resync, só as que estavam vazias
> são preenchidas pela primeira vez. Trocar a fonte do mapper não é
> destrutivo pra quem já tinha e-mail certo.

## 3. `emailVerified` sempre `false` — trava provisionamento SSO

**Achado real**: toda conta vinda do AD chega no Keycloak com
`emailVerified: false` (não existe mapper nenhum que marque isso como
`true`). Alguns apps SSO (o Vaultwarden é um caso confirmado) **exigem
e-mail verificado** pra criar a conta automaticamente no primeiro login
via SSO. Como o "e-mail" agora é baseado em `userPrincipalName` (não é
uma caixa de e-mail real), **não tem como verificar por link** — não
existe inbox pra receber nada. Isso travaria todo mundo, um por um.

**Correção**: mapper LDAP do tipo "hardcoded" que marca `emailVerified=true`
pra toda conta vinda do AD — decisão deliberada de confiar na
autenticação do próprio AD como prova de identidade (o Keycloak já
validou a senha contra o AD antes de emitir qualquer token; exigir
"verificação de e-mail" em cima disso é redundante quando o e-mail nem é
uma caixa real).

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create components -r Prefeitura \
    -s name='email verified (hardcoded - fonte AD e confiavel)' \
    -s providerId=hardcoded-attribute-mapper \
    -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
    -s parentId=<ID-DO-PROVIDER-LDAP> \
    -s 'config."user.model.attribute"=["emailVerified"]' \
    -s 'config."attribute.value"=["true"]'
```

Depois, sync completo (seção 5) pra aplicar retroativamente.

## 4. Grupos do AD: sincronização completa

Não existia **nenhum** `group-ldap-mapper` configurado — zero grupos do
AD apareciam no Keycloak (`check_ad_status.sh` reportava "grupos podem
não estar sincronizando").

### 4.1. Criar o mapper de grupos

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create components -r Prefeitura \
    -s name='ldap-groups' \
    -s providerId=group-ldap-mapper \
    -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
    -s parentId=<ID-DO-PROVIDER-LDAP> \
    -s 'config."groups.dn"=["DC=rondonopolis,DC=local"]' \
    -s 'config."group.name.ldap.attribute"=["cn"]' \
    -s 'config."group.object.classes"=["group"]' \
    -s 'config."preserve.group.inheritance"=["false"]' \
    -s 'config."membership.ldap.attribute"=["member"]' \
    -s 'config."membership.attribute.type"=["DN"]' \
    -s 'config."membership.user.ldap.attribute"=["cn"]' \
    -s 'config."mode"=["READ_ONLY"]' \
    -s 'config."user.roles.retrieve.strategy"=["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE_RECURSIVELY"]' \
    -s 'config."drop.non.existing.groups.during.sync"=["false"]' \
    -s 'config."groups.ldap.filter"=[""]' \
    -s 'config."groups.path"=["/"]'
```

Pontos que custaram tempo de diagnóstico até chegar nessa config:

- **`user.roles.retrieve.strategy` precisa ser `_RECURSIVELY`**. Com a
  estratégia padrão (`LOAD_GROUPS_BY_MEMBER_ATTRIBUTE`, não-recursiva),
  usuários que só pertencem a um grupo **aninhado** dentro de outro (ex:
  `Domain Admins` sendo membro de `Administrators`, topologia padrão do
  Windows) **não aparecem** como membro do grupo pai. Sem a versão
  recursiva, sincronizamos o grupo `Administrators` e ele apareceu com
  **zero membros** — só depois de trocar pra `_RECURSIVELY` os membros
  de verdade (inclusive aninhados) apareceram.
- **`groups.ldap.filter` vazio = sincroniza TODOS os grupos do AD**
  (nesta prefeitura, **682 grupos**). Se quiser restringir a um subset
  (ex: só grupos de TI), usar um filtro LDAP aqui, tipo
  `(cn=Administrators)` — mas isso limita a busca de membership também,
  então só use filtro se tiver certeza de que não vai precisar de outros
  grupos depois.
- **`preserve.group.inheritance` — NÃO ligar** (ver seção 6, é uma
  limitação real, não uma opção).

### 4.2. Disparar o sync

```bash
# sync completo do provider inteiro (usuarios + grupos + membership)
TOKEN=$(...)  # token de admin
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/user-storage/<ID-DO-PROVIDER-LDAP>/sync?action=triggerFullSync"

# sync so' dos grupos (mais rapido, quando so mudou o mapper de grupo)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
    "http://<KC-HOST>/admin/realms/Prefeitura/user-storage/<ID-DO-PROVIDER-LDAP>/mappers/<ID-DO-MAPPER-GRUPO>/sync?direction=fedToKeycloak"
```

> Sincronizar grupo (via `mappers/{id}/sync`) só importa os **objetos**
> de grupo. Pra vincular a **membership** de usuários já existentes a
> esses grupos, é necessário um sync completo do provider (`triggerFullSync`)
> depois — foi isso que aconteceu quando testamos: sincronizamos o grupo
> `Administrators` (apareceu no Keycloak), mas com zero membros, até
> rodar o full sync depois.

### 4.3. Sync automático (não precisa disparar manualmente sempre)

Por padrão, `fullSyncPeriod` e `changedSyncPeriod` vêm `-1` (desligado —
só sincroniza quando alguém dispara manualmente). Ligamos:

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh update components/<ID-DO-PROVIDER-LDAP> -r Prefeitura \
    -s 'config."changedSyncPeriod"=["300"]' \
    -s 'config."fullSyncPeriod"=["86400"]'
```

- **`changedSyncPeriod=300`** (5 min): sync incremental — pega mudanças
  de atributo/grupo desde a última vez. É o mais perto de "tempo real"
  que o Keycloak suporta nativamente (é *polling*, não *push* — não
  existe notificação instantânea vinda do AD).
- **`fullSyncPeriod=86400`** (24h): reconciliação completa, pega
  remoções que o incremental pode não capturar.

**Login em si já é sempre em tempo real**, independente desse sync: a
senha é validada com bind LDAP ao vivo a cada tentativa. Uma conta
desativada no AD não consegue logar imediatamente — só *atributos* e
*grupos* dependem do sync periódico pra refletir.

## 5. Achado: grupo `Administrators` do AD é amplo demais pra virar admin do Keycloak

Ao configurar quem deveria ter acesso administrativo ao Keycloak via
grupo do AD, o primeiro teste (mapear o grupo `Administrators` embutido
do AD pra role `realm-admin`) resultou em **112 membros** com controle
total do Keycloak — incluindo contas de serviço (`backup`, `zabbix`,
`oracle.backup`, `sophos.stas`, `camera.samu` etc.), não só a equipe de
TI de confiança. É o grupo embutido "Administrators" do Windows, que
acumula acesso de admin local de servidores/serviços ao longo dos anos —
não é um grupo pensado pra "quem administra o Keycloak".

**Correção**: usar grupos de TI específicos em vez do genérico:

| Grupo AD | Membros | Uso |
|---|---|---|
| `Grupo TI - Administradores` | 2 | realm-admin completo |
| `Grupo Nucleo de TI` | 8 | realm-admin completo |
| `Administrators` (embutido) | 112 | **nenhuma role especial** — removida |

```bash
# tira a role do grupo generico
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    "http://<KC-HOST>/admin/realms/Prefeitura/groups/<ID-ADMINISTRATORS>/role-mappings/clients/<ID-REALM-MANAGEMENT>" \
    -d '[{"id":"<ID-ROLE-REALM-ADMIN>","name":"realm-admin","clientRole":true,"containerId":"<ID-REALM-MANAGEMENT>"}]'

# da' pros grupos certos
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    "http://<KC-HOST>/admin/realms/Prefeitura/groups/<ID-GRUPO-TI-ADM>/role-mappings/clients/<ID-REALM-MANAGEMENT>" \
    -d '[{"id":"<ID-ROLE-REALM-ADMIN>","name":"realm-admin","clientRole":true,"containerId":"<ID-REALM-MANAGEMENT>"}]'
```

**Ao replicar**: sempre confira quantos membros tem um grupo do AD antes
de mapear pra uma role administrativa — nomes "óbvios" tipo
`Administrators`/`Domain Admins` costumam ser muito mais amplos do que
parecem à primeira vista.

## 6. Limitação real: sem hierarquia de subgrupos no Keycloak

Tentamos ligar `preserve.group.inheritance=true` no mapper de grupos
(seção 4.1), esperando que grupos aninhados no AD virassem
"subgrupos" (pai/filho) dentro do Keycloak também. Resultado:
```json
{"errorMessage":"GroupsMultipleParents"}
```

**Causa raiz**: o AD permite um grupo pertencer a **múltiplos** grupos-pai
ao mesmo tempo (normal em ambientes grandes — um grupo de TI pode estar
dentro de "Departamento de TI" **e** de "Acesso VPN" ao mesmo tempo, por
exemplo). A árvore de grupos do Keycloak só aceita **um pai por grupo**
— não é configurável, é uma limitação estrutural do modelo de dados do
Keycloak (árvore, não grafo).

**Não dá pra contornar isso preservando hierarquia real.** A solução que
funciona: manter `preserve.group.inheritance=false` (grupos "irmãos",
todos no nível raiz do Keycloak) — a **membership continua completa e
correta** graças à estratégia recursiva (seção 4.1): se alguém está num
subgrupo aninhado dentro de outro no AD, aparece como membro dos dois no
Keycloak, só não existe uma relação "pai→filho" visível entre os grupos
em si. Pra qualquer sistema fazendo controle de acesso por grupo, isso é
suficiente — o que importa é "esse usuário está no grupo X?", não a
árvore.

## 7. Achado: divisão por secretaria já existe no AD, mas não tem grupo "Prefeitura" genérico

O AD tem uma estrutura extensa de grupos por secretaria — não é só
"Saúde" e "Educação", tem dezenas: Sinfra (infraestrutura), Seciti
(ciência/tecnologia), SEMAS (assistência social), Governo, Procuradoria,
Cultura, Habitação, Meio Ambiente, entre outras. Grupos "guarda-chuva"
identificados:

| Secretaria | Grupo | Membros (aprox.) |
|---|---|---|
| Saúde | `Grupo_Saude` | 1000+ (limite de paginação da API, real é maior) |
| Educação | `Grupo_Educacao` | 1000+ (idem) |
| Infraestrutura | `Grupo_Sinfra` | 210 |
| Ciência/Tecnologia | `Grupo_Seciti` | 138 |

Mais **64 subgrupos específicos de Saúde** (farmácia, UPAs, hospital,
SAMU, epidemiologia...) e **28 de Educação** (escolas, transporte
escolar, merenda...). **Não existe um grupo "Prefeitura" genérico** —
quem não está em nenhum `Grupo_<secretaria>` é, na prática,
administração central (cada setor com seus próprios grupos específicos,
tipo `Governo Administrativo`, `Procuradoria Administrativa`).

Essa informação já está disponível via sincronização (seção 4) e pode
ser usada por qualquer sistema integrado (claim `groups` no token) pra
segmentar acesso por secretaria — ver limitação equivalente documentada
em [glpi.md](glpi.md#7-limitações-conhecidas-não-implementado)
sobre o GLPI ainda não usar essa informação.

## 8. Lacuna conhecida: sem `secrets/ldap_bind_password.txt`

Como a federação foi configurada manualmente (fora deste repositório,
fora do `configure_ldap.sh`), o arquivo `secrets/ldap_bind_password.txt`
**nunca existiu** localmente. Isso não afeta o funcionamento real (o
Keycloak já tem a senha de bind guardada internamente e usa ela
normalmente) — só afeta o **teste de diagnóstico**
(`scripts/check_ad_status.sh`), que não consegue fazer um bind LDAP
síncrono de teste sem esse arquivo, e reporta "FEDERAÇÃO COM O AD: COM
PROBLEMA" mesmo quando está tudo funcionando (12.751+ usuários
sincronizados provam isso).

**Pra corrigir de vez**: preencher `secrets/ldap_bind_password.txt` com
a senha real da conta de bind (`adm.yuri`, nesta prefeitura), pra o
script de diagnóstico parar de dar falso negativo.

## Portão de validação

- [ ] `kcadm.sh get realms` confirma qual realm tem os usuários de
      verdade antes de configurar qualquer integração nova
- [ ] Amostra de usuários reais tem `email` preenchido (`userPrincipalName`,
      não `mail`) e `emailVerified: true`
- [ ] Grupos sincronizados (`GET /admin/realms/<realm>/groups/count`)
      batem com o esperado
- [ ] Grupo mapeado pra alguma role administrativa foi **conferido
      manualmente quantos membros tem** antes de aplicar
- [ ] `changedSyncPeriod`/`fullSyncPeriod` configurados (não `-1`)
- [ ] `secrets/ldap_bind_password.txt` preenchido, `check_ad_status.sh`
      reporta federação OK de verdade (não só "usuários sincronizados")
