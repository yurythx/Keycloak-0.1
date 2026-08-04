# SSO do Vaultwarden: Ajustes Reais de Produção

[← Índice de Integrações](README.md) · [Documentação Geral](../README.md)

`docs/06-vaultwarden.md` cobre o provisionamento e a configuração
planejada do SSO do Vaultwarden. Este documento registra especificamente
a depuração real feita em produção até o login SSO funcionar de ponta a
ponta — os bugs encontrados não eram de configuração óbvia, e vale
registrar tanto pra não repetir o mesmo caminho quanto porque **os dois
primeiros achados aqui (realm errado, e-mail ausente) são exatamente os
mesmos que afetam qualquer outro client SSO deste Keycloak** (GLPI,
futura intranet Django) — ver [active-directory.md](active-directory.md).

## 1. Sintoma inicial: "integração OK" nos testes, mas login real falhava

`scripts/check_vaultwarden_sso.sh` reportava `INTEGRACAO OK` — o
redirect pro Keycloak acontecia, com `client_id` e PKCE corretos. Mas
login real com usuário do AD não funcionava. O script só testa o
**início** do fluxo (redirect), não completa um login de verdade — por
isso não pegava os problemas abaixo.

## 2. Causa raiz #1: client apontando pro realm errado (vazio)

Igual detalhado em
[active-directory.md §1](active-directory.md#1-o-que-a-federação-real-é-diferente-do-plano):
o `.env` tinha `VAULTWARDEN_SSO_AUTHORITY=.../realms/prefeitura`
(minúsculo) — um realm **vazio**, criado pelos scripts deste repositório
por padrão, sem nenhum usuário real do AD. O client `vaultwarden`
criado nesse realm funcionava tecnicamente, só que contra ninguém.

O realm certo (`Prefeitura`, maiúsculo) **já tinha** um client chamado
`vaultwarden-sso` criado por fora deste repositório — mas com as
`redirectUris` apontando pra um host antigo (`http://192.168.0.181:8081/`,
não o domínio atual `https://cofre.rondonopolis.mt.gov.br`).

**Correção**:
```bash
# 1. Atualiza o client existente no realm certo (nao cria um novo)
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh update clients/<ID-VAULTWARDEN-SSO> -r Prefeitura \
    -s 'redirectUris=["https://cofre.rondonopolis.mt.gov.br/identity/connect/oidc-signin"]' \
    -s 'webOrigins=["https://cofre.rondonopolis.mt.gov.br"]' \
    -s rootUrl=https://cofre.rondonopolis.mt.gov.br/ \
    -s baseUrl=https://cofre.rondonopolis.mt.gov.br/

# 2. Reaponta o .env
VAULTWARDEN_SSO_AUTHORITY=https://sso.rondonopolis.mt.gov.br/realms/Prefeitura
VAULTWARDEN_SSO_CLIENT_ID=vaultwarden-sso

# 3. Client secret real (pega do client existente, nao inventa um novo)
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients/<ID-VAULTWARDEN-SSO>/client-secret -r Prefeitura
# grava o valor em secrets/vw_sso_client_secret.txt

# 4. Recria o container pra aplicar
docker compose up -d --force-recreate vaultwarden
```

O realm `prefeitura` (minúsculo, vazio, sem uso) foi apagado depois —
`kcadm.sh delete realms/prefeitura`.

## 3. Causa raiz #2: sem `email` no token, Vaultwarden recusa o login

```
[vaultwarden::sso][ERROR] Neither id token nor userinfo contained an email
```

Coberto em detalhe em
[active-directory.md §2-3](active-directory.md#2-e-mail-mail-não-serve-usar-userprincipalname) —
resumo: `mail` do AD só estava preenchido pra 7,6% dos usuários, e
`emailVerified` sempre vinha `false` (Vaultwarden exige e-mail
verificado pra criar conta no primeiro login SSO). Resolvido trocando a
fonte do e-mail pra `userPrincipalName` + mapper hardcoded de
`emailVerified=true` — isso é ajuste do **realm inteiro** (federação
AD), não específico do Vaultwarden, mas foi aqui que o sintoma apareceu
primeiro.

## 4. Causa raiz #3: access token expira em 5 minutos, sem refresh funcional

**Sintoma no navegador** (erro visível pro usuário, "cofre bloqueado"):
```
Erro ao recarregar o token de acesso
Nenhum token de atualização ou chave de API foi encontrado.
```

**No console do navegador**:
```
Unhandled error in angular Error: Cannot refresh access token,
no refresh token or api keys are stored.
```

**Nos logs do Vaultwarden**, o aviso que já estava lá o tempo todo,
ignorado até a causa raiz ficar clara:
```
[vaultwarden::auth][WARN] Raise access_token lifetime to more than 5min.
```

**Causa raiz**: `accessTokenLifespan` do realm Prefeitura estava no
padrão do Keycloak, **300s (5 minutos)** — curto demais pro fluxo de
sessão do Vaultwarden. O próprio Vaultwarden avisa nos logs, mas o aviso
passa despercebido fácil porque o login *parece* funcionar no começo
(o problema só aparece quando o token expira em uso).

**Correção** (aplicada só no client `vaultwarden-sso`, não no realm
inteiro — não afeta o tempo de token do GLPI/admin console):
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh update clients/<ID-VAULTWARDEN-SSO> -r Prefeitura \
    -s 'attributes."access.token.lifespan"=1800'
```

Confirmação (o `expires_in` do token emitido reflete o novo valor, e
`refresh_token` vem presente):
```bash
curl -s -X POST http://<KC-HOST>/realms/Prefeitura/protocol/openid-connect/token \
    -d grant_type=authorization_code -d code=<CODE> \
    -d redirect_uri=<REDIRECT_URI> -d client_id=vaultwarden-sso -d client_secret=<SECRET> \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("expires_in:", d["expires_in"], "| refresh_token:", "refresh_token" in d)'
# esperado: expires_in: 1800 | refresh_token: True
```

> **Ao replicar em outro client SSO** (GLPI, intranet Django, etc.):
> considere aplicar o mesmo override preventivamente, em vez de esperar
> o sintoma aparecer — qualquer app que mantenha uma sessão longa
> (WebSocket, sync periódico) tende a esbarrar no mesmo problema com o
> padrão de 5 minutos do Keycloak.

## 5. Comportamento esperado (não é bug): pede senha mestra depois do SSO

Depois do SSO funcionar, o Vaultwarden **sempre** pede uma senha mestra
separada antes de mostrar o cofre — isso é o design do Bitwarden/Vaultwarden,
não um bug nosso, e acontece igual em qualquer empresa usando Bitwarden
(nuvem oficial ou self-hosted):

- **SSO autentica** (prova quem você é, via AD/Keycloak).
- **Senha mestra desbloqueia** (decripta os dados do cofre, localmente
  no navegador — o servidor nunca vê essa senha nem os dados
  descriptografados). É *outra* senha, não a do AD.
- Pra usuário novo (primeiro login via SSO), o próprio Vaultwarden pede
  pra **criar** essa senha mestra ali (`POST /api/accounts/set-password`,
  confirmado nos logs funcionando).
- **Não tem como eliminar essa segunda senha** no Vaultwarden self-hosted
  — o recurso que faria isso (**Key Connector**) só existe no Bitwarden
  Enterprise pago (nuvem oficial), não no Vaultwarden open-source.

## 6. Diagnóstico sem precisar de senha real de ninguém

Duas técnicas usadas o tempo todo pra validar cada correção acima, sem
depender de pedir senha de AD pra ninguém nem esperar alguém testar:

**Impersonation do Keycloak** — gera uma sessão válida como qualquer
usuário usando só o token de admin (ver exemplo completo em
[glpi.md §5](glpi.md#5-testar-sem-precisar-de-senha-real-de-ninguém),
o mesmo processo serve pra qualquer client, só troca o `client_id`,
`redirect_uri` e `client_secret`).

**Comparar origin direto vs. proxy externo** — usado pra descartar
(nesse caso, corretamente descartar) a hipótese de cache desatualizado
no proxy reverso externo (192.168.0.218) como causa do erro de token:
```bash
curl -s -D - -o /tmp/local.html http://<IP-INTERNO-DO-VAULTWARDEN>:<PORTA>/
curl -s -D - -o /tmp/public.html https://cofre.rondonopolis.mt.gov.br/
diff /tmp/local.html /tmp/public.html   # identico = nao e' cache
```
(Esse mesmo par de comandos já tinha sido usado antes, em outra sessão,
pra **confirmar** um bug real de cache no CSS do Vaultwarden — vale como
técnica geral de descarte/confirmação, não assume a resposta de
antemão.)

## Portão de validação

- [ ] `VAULTWARDEN_SSO_AUTHORITY` aponta pro realm com usuários reais
      (confirmar com `kcadm.sh get realms`, não assumir pelo nome)
- [ ] Client SSO do Vaultwarden tem `redirectUris` batendo com o
      `VAULTWARDEN_DOMAIN` **atual** (não um host antigo)
- [ ] `access.token.lifespan` do client é maior que 300s
- [ ] Login SSO completo testado com usuário real (ou via impersonation,
      seção 6) — sem erro de token no meio da sessão
- [ ] Confirmado com quem for usar: a senha mestra separada é esperada,
      não um problema a resolver
