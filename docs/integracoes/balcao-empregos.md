# Integração Balcão de Empregos (Django) ↔ Keycloak (SSO via OIDC)

[← Índice de Integrações](README.md) · [Documentação Geral](../README.md)

**Status**: guia de implementação pra equipe de desenvolvimento — o
Balcão de Empregos ainda não existe rodando/integrado. Mesmo padrão
técnico de [intranet-django.md](intranet-django.md) (mesmo framework,
mesma lib) — a diferença real está no **escopo de quem faz SSO** (ver
seção 0 abaixo), não no mecanismo.

**Público-alvo**: desenvolvedores backend Django.
**Escopo**: autenticação centralizada via OpenID Connect (OIDC) — só
pra área administrativa/staff, não pro site público.
**Provedor de Identidade**: Keycloak, realm `Prefeitura`, federado ao
Active Directory (ver [active-directory.md](active-directory.md)).

## 0. ⚠️ Antes de tudo: SSO cobre só a área administrativa, não o site público

**Achado/decisão de arquitetura, confirmar com o time antes de
implementar**: diferente da Intranet (uso 100% interno, todo mundo que
acessa já é servidor público com conta no AD), o Balcão de Empregos é
uma aplicação **de uso público** — qualquer cidadão da cidade deve
poder navegar vagas e se candidatar, e a **imensa maioria dessas
pessoas não tem conta no Active Directory da prefeitura** (não são
servidores). Aplicar Keycloak/SSO no site inteiro trancaria a
população de fora, o que quebra o propósito da ferramenta.

O desenho recomendado:

| Área | Quem acessa | Autenticação |
|---|---|---|
| Site público (buscar vaga, se candidatar) | Qualquer cidadão | **Sem Keycloak** — conta própria da aplicação (`django.contrib.auth` padrão, cadastro por e-mail/CPF, o que já for o modelo de usuário do Balcão de Empregos) ou até sem conta nenhuma pra só navegar |
| Painel administrativo (cadastrar vaga, gerenciar candidaturas, relatórios) | Servidores da prefeitura (RH, Secretaria do Trabalho, etc.) | **Keycloak/SSO** — igual às outras integrações desta pasta |

Na prática, isso significa: o client OIDC e o `mozilla-django-oidc`
protegem só as rotas administrativas (tipicamente sob um prefixo, ex.
`/staff/` ou o próprio `/admin/` do Django, ou uma `staff_member_required`
view decorator customizada) — **não** o `AUTHENTICATION_BACKENDS`
inteiro do projeto, que continua aceitando login normal (usuário/senha
da própria aplicação) pra candidatos.

> Se o Balcão de Empregos também precisar de conta pra cidadão (pra
> acompanhar candidatura, por exemplo), isso é uma base de usuários
> **separada** da federação com o AD — não faz sentido (nem seria
> seguro) misturar identidade de servidor público com identidade de
> candidato externo no mesmo IdP.

## Endpoints do Keycloak (realm `Prefeitura`)

| Recurso | URL |
|---|---|
| Base URL do realm | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura` |
| Authorization Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/auth` |
| Token Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/token` |
| Userinfo Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/userinfo` |
| JWKS Endpoint (chaves públicas) | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/certs` |
| Logout Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/logout` |

## 1. Criar o client no Keycloak

> **Domínio abaixo é placeholder** (`balcaoempregos.rondonopolis.mt.gov.br`)
> — confirme o domínio real da aplicação antes de criar o client de
> verdade, e ajuste o `redirectUris` de acordo com o prefixo escolhido
> pra área administrativa (ex. `/staff/oidc/callback/`).

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r Prefeitura \
    -s clientId=django-balcao-empregos \
    -s name='Balcao de Empregos (Admin)' \
    -s protocol=openid-connect \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s frontchannelLogout=true \
    -s 'redirectUris=["https://balcaoempregos.rondonopolis.mt.gov.br/staff/oidc/callback/"]' \
    -s 'webOrigins=["https://balcaoempregos.rondonopolis.mt.gov.br"]' \
    -s rootUrl='https://balcaoempregos.rondonopolis.mt.gov.br/' \
    -s 'attributes."access.token.lifespan"=1800'
```

> **`access.token.lifespan=1800` desde a criação** — mesmo motivo
> documentado em
> [vaultwarden.md §4](vaultwarden.md#4-causa-raiz-3-access-token-expira-em-5-minutos-sem-refresh-funcional):
> o padrão do Keycloak (300s) já causou um bug real de sessão numa
> integração anterior.

Parâmetros do client:

| Campo | Valor |
|---|---|
| Client ID | `django-balcao-empregos` |
| Client Authentication | `ON` (confidencial) |
| Authentication Flow | Standard Flow habilitado |
| Valid Redirect URIs | só a rota de callback da área **administrativa** (ex. `/staff/oidc/callback/`), nunca a raiz do site |

Pega o secret gerado:
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients/<ID>/client-secret -r Prefeitura
```

### Mapper de grupos (recomendado aqui — RH/Secretaria do Trabalho já são grupos reais do AD)

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients/<ID>/protocol-mappers/models -r Prefeitura \
    -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
    -s 'config."claim.name"=groups' \
    -s 'config."full.path"=false' \
    -s 'config."id.token.claim"=true' \
    -s 'config."access.token.claim"=true' \
    -s 'config."userinfo.token.claim"=true'
```
Útil pra restringir quem entra no painel administrativo a um grupo
específico do AD (ex. RH), em vez de "qualquer servidor autenticado" —
ver `OIDC_RP_...` + verificação de grupo no `settings.py` na seção 2.

## 2. Passos para a equipe Django

Igual [intranet-django.md §2](intranet-django.md#2-passos-para-a-equipe-django)
(mesma lib, `mozilla-django-oidc`), com a diferença de que a
autenticação OIDC não deve substituir o backend de auth padrão do
projeto — os dois convivem.

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

# IMPORTANTE: ModelBackend continua primeiro/presente - login de
# candidato (usuario comum do site) nao passa pelo Keycloak.
AUTHENTICATION_BACKENDS = (
    'django.contrib.auth.backends.ModelBackend',           # login normal do site (candidatos)
    'mozilla_django_oidc.auth.OIDCAuthenticationBackend',   # login SSO (staff/administrativo)
)

# Configuracoes do Keycloak
OIDC_RP_CLIENT_ID = 'django-balcao-empregos'
OIDC_RP_CLIENT_SECRET = 'SEU_CLIENT_SECRET_GERADO_NO_KEYCLOAK'  # nunca em texto plano no repo
OIDC_RP_SIGN_ALGO = 'RS256'

OIDC_OP_AUTHORIZATION_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/auth'
OIDC_OP_TOKEN_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/token'
OIDC_OP_USER_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/userinfo'
OIDC_OP_JWKS_ENDPOINT = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/certs'

# Redirecionamentos - so' afetam o fluxo SSO, nao o login normal do site
LOGIN_REDIRECT_URL = '/staff/'
LOGOUT_REDIRECT_URL = 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/logout?redirect_uri=https://balcaoempregos.rondonopolis.mt.gov.br/'
```

### Step 3 — Mapear `urls.py` só sob o prefixo administrativo

```python
from django.urls import path, include

urlpatterns = [
    path('', include('vagas.urls')),          # site publico - login normal, sem SSO
    path('staff/oidc/', include('mozilla_django_oidc.urls')),  # SSO so' aqui
    path('staff/', include('painel.urls')),    # area administrativa
]
```

### Step 4 — Restringir o painel administrativo a quem logou via SSO (e opcionalmente por grupo)

```python
from django.contrib.auth.decorators import login_required
from django.core.exceptions import PermissionDenied
from functools import wraps

def staff_sso_required(view_func):
    @wraps(view_func)
    @login_required(login_url='oidc_authentication_init')
    def wrapper(request, *args, **kwargs):
        # opcional: exigir grupo especifico do AD (claim "groups", ver mapper na secao 1)
        groups = request.session.get('oidc_groups', [])
        if 'Grupo Secretaria do Trabalho' not in groups and not request.user.is_superuser:
            raise PermissionDenied
        return view_func(request, *args, **kwargs)
    return wrapper
```

> O jeito exato de acessar o claim `groups` depende de como o
> `OIDCAuthenticationBackend` é customizado (`create_user`/`update_user`
> hooks) — ajustar a extração/salvamento desse claim faz parte da
> implementação real, este é só o esqueleto do controle de acesso.

### Step 5 — Botão de login/logout (só na área administrativa)

```html
{% if user.is_authenticated %}
  <p>Bem-vindo, {{ user.first_name }}</p>
  <a href="{% url 'oidc_logout' %}">Sair (SSO)</a>
{% else %}
  <a href="{% url 'oidc_authentication_init' %}">Entrar com Keycloak/AD</a>
{% endif %}
```

## Checklist de validação (preencher quando testar de verdade)

- [ ] Domínio real da aplicação confirmado (substituir o placeholder `balcaoempregos.rondonopolis.mt.gov.br` em todo lugar, inclusive no client do Keycloak)
- [ ] Client `django-balcao-empregos` criado no realm `Prefeitura`, `access.token.lifespan` > 300s
- [ ] `redirectUris` do client aponta só pra rota de callback administrativa, **não** pra raiz do site
- [ ] Confirmado que o site público (busca de vaga, candidatura) **continua funcionando sem Keycloak** — login de candidato não quebrou
- [ ] Painel administrativo exige SSO — acessar `/staff/` deslogado redireciona pro Keycloak, não mostra nada
- [ ] Se usar restrição por grupo do AD: testado com usuário de dentro e de fora do grupo permitido
- [ ] Logout do painel administrativo encerra a sessão do Keycloak também, sem afetar sessão de candidato (são independentes)
