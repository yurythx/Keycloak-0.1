# Integração Intranet (Django) ↔ Keycloak (SSO via OIDC)

[← Índice de Integrações](README.md) · [Documentação Geral](../README.md)

**Status**: guia de implementação pra equipe de desenvolvimento — a
Intranet ainda não existe rodando/integrada. Diferente das outras
integrações desta pasta (GLPI, Vaultwarden, Zabbix, Grafana — sistemas
reais, já testados em homologação/produção, com bugs reais documentados),
este documento é o **roteiro a seguir** quando a equipe backend for
implementar. Atualize com achados reais assim que a integração for
testada de verdade (mesmo padrão dos outros documentos desta pasta).

**Público-alvo**: desenvolvedores backend Django.
**Escopo**: autenticação centralizada via OpenID Connect (OIDC).
**Provedor de Identidade**: Keycloak, realm `Prefeitura`, federado ao
Active Directory (ver [active-directory.md](active-directory.md)).

## Visão geral da arquitetura

O Keycloak é o Provedor de Identidade (IdP) centralizador. A validação
das credenciais do Active Directory acontece **no Keycloak** — a
Intranet não conversa com o AD via LDAP diretamente, só delega a
autenticação ao Keycloak via OIDC.

```
Active Directory (AD) ──LDAP sync──▶ Keycloak (realm Prefeitura) ──OIDC──▶ Intranet (Django)
```

A Intranet usa o fluxo **Authorization Code Flow** com `Client ID` +
`Client Secret` (client confidencial — aplicação server-side, com
backend que pode guardar segredo com segurança, diferente de uma SPA).

## Endpoints do Keycloak (realm `Prefeitura`)

| Recurso | URL |
|---|---|
| Base URL do realm | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura` |
| OpenID Configuration | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/.well-known/openid-configuration` |
| Authorization Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/auth` |
| Token Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/token` |
| Userinfo Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/userinfo` |
| JWKS Endpoint (chaves públicas) | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/certs` |
| Logout Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/logout` |

## 1. Criar o client no Keycloak

Mesmo padrão usado pras outras integrações deste projeto — via
`kcadm.sh` (ver exemplo completo em
[glpi.md §2](glpi.md#2-configurar-o-client-no-keycloak) ou
[grafana.md §2](grafana.md#2-client-oidc-no-keycloak), adaptando pra
OIDC/Django):

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r Prefeitura \
    -s clientId=django-intranet \
    -s name='Intranet' \
    -s protocol=openid-connect \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s frontchannelLogout=true \
    -s 'redirectUris=["https://intranet.rondonopolis.mt.gov.br/oidc/callback/"]' \
    -s 'webOrigins=["https://intranet.rondonopolis.mt.gov.br"]' \
    -s rootUrl='https://intranet.rondonopolis.mt.gov.br/' \
    -s 'attributes."access.token.lifespan"=1800'
```

> **`access.token.lifespan=1800` não é opcional** — o padrão do
> Keycloak (300s/5min) já causou um bug real de sessão no Vaultwarden
> (ver [vaultwarden.md §4](vaultwarden.md#4-causa-raiz-3-access-token-expira-em-5-minutos-sem-refresh-funcional)).
> Aplicar desde a criação evita repetir o mesmo problema aqui.

Parâmetros do client:

| Campo | Valor |
|---|---|
| Client ID | `django-intranet` |
| Client Authentication | `ON` (confidencial) |
| Authentication Flow | Standard Flow habilitado |
| Valid Redirect URIs | `https://intranet.rondonopolis.mt.gov.br/oidc/callback/` |

Pega o secret gerado:
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients/<ID>/client-secret -r Prefeitura
```

### Mapper de grupos (opcional, pra permissão por secretaria/setor)

Mesmo padrão usado em todas as outras integrações — manda os grupos do
AD do usuário como claim `groups` no token, pra Django decidir
permissão sem precisar consultar o AD diretamente:
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients/<ID>/protocol-mappers/models -r Prefeitura \
    -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true'
```

## 2. Passos para a equipe Django

### Step 1 — Instalar a dependência
```bash
pip install mozilla-django-oidc
```

### Step 2 — Configurar `settings.py`
```python
INSTALLED_APPS = [
    # ... apps do django
    'django.contrib.auth',
    'mozilla_django_oidc',  # Adicionar
]

AUTHENTICATION_BACKENDS = (
    'mozilla_django_oidc.auth.OIDCAuthenticationBackend',
    'django.contrib.auth.backends.ModelBackend',
)

# Configuracoes do Keycloak
OIDC_RP_CLIENT_ID = 'django-intranet'
OIDC_RP_CLIENT_SECRET = 'SEU_CLIENT_SECRET_GERADO_NO_KEYCLOAK'  # nunca em texto plano no repo - variavel de ambiente/secret
OIDC_RP_SIGN_ALGO = 'RS256'

# URLs do realm Keycloak (Prefeitura)
OIDC_OP_AUTHORIZATION_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/auth'
OIDC_OP_TOKEN_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/token'
OIDC_OP_USER_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/userinfo'
OIDC_OP_JWKS_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/certs'

# Redirecionamentos
LOGIN_URL = 'oidc_authentication_init'
LOGIN_REDIRECT_URL = '/'
LOGOUT_REDIRECT_URL = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/logout?redirect_uri=https://intranet.rondonopolis.mt.gov.br/'
```

> **Segredo nunca em texto plano no código** — mesmo padrão de todo o
> resto deste projeto (ver `secrets/*.txt` no repositório principal):
> `OIDC_RP_CLIENT_SECRET` deve vir de variável de ambiente ou de um
> arquivo de secret montado, nunca commitado.

### Step 3 — Mapear `urls.py`
```python
from django.urls import path, include

urlpatterns = [
    # ... outras rotas
    path('oidc/', include('mozilla_django_oidc.urls')),
]
```

### Step 4 — Botão de login/logout no template
```html
{% if user.is_authenticated %}
  <p>Bem-vindo, {{ user.first_name }} ({{ user.username }})</p>
  <a href="{% url 'oidc_logout' %}">Sair (SSO)</a>
{% else %}
  <a href="{% url 'oidc_authentication_init' %}">Entrar com Keycloak/AD</a>
{% endif %}
```

## Checklist de validação (preencher quando testar de verdade)

- [ ] Client `django-intranet` criado no realm `Prefeitura`, `access.token.lifespan` > 300s
- [ ] `redirectUris` do client bate exatamente com `OIDC_RP_CLIENT_SECRET`/callback configurado no Django
- [ ] Login SSO completo testado com usuário real do AD
- [ ] Logout encerra também a sessão do Keycloak (`LOGOUT_REDIRECT_URL` aponta pro endpoint de logout, não só pra home da Intranet)
- [ ] `OIDC_RP_CLIENT_SECRET` vem de variável de ambiente/secret, confirmado que não está commitado
- [ ] Se usar o claim `groups`: mapeamento de grupo do AD → permissão Django decidido e documentado aqui
