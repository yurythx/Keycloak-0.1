# Integração Papermoon (DRF + Next.js) ↔ Keycloak (SSO via OIDC)

[← Índice de Integrações](README.md) · [Documentação Geral](../README.md)

**Status**: guia de implementação pra equipe de desenvolvimento — o
Papermoon ainda não existe integrado. Assumido como **uso interno**
(servidores autenticados via AD), igual à Intranet — se o Papermoon
tiver alguma área de uso público (como o
[Balcão de Empregos](balcao-empregos.md#0-⚠️-antes-de-tudo-sso-cobre-só-a-área-administrativa-não-o-site-público)),
revise a seção 0 daquele documento e aplique o mesmo raciocínio aqui
antes de implementar.

**Público-alvo**: desenvolvedores frontend (Next.js) e backend (Django
REST Framework).
**Escopo**: autenticação centralizada via OpenID Connect (OIDC), com
aplicação **desacoplada** (frontend e backend/API separados).
**Provedor de Identidade**: Keycloak, realm `Prefeitura`, federado ao
Active Directory (ver [active-directory.md](active-directory.md)).

## 0. ⚠️ Diferença importante em relação ao Protocolo Digital

O [Protocolo Digital](protocolo-digital.md) (React puro + Node.js) usa
um client **público** com PKCE, porque uma SPA React não tem nenhum
backend próprio pra guardar segredo — o código OAuth é trocado direto
no navegador.

**Next.js é diferente**: tem um runtime Node.js do próprio lado do
frontend (API routes / route handlers), então a troca do código OAuth
pelo token pode acontecer **no servidor do Next.js**, não no navegador.
Isso significa que o client do Papermoon pode (e deve) ser
**confidencial** (com `client_secret`), igual ao padrão Django — o
segredo fica seguro no servidor Next.js, nunca chega no bundle JS do
navegador. É o modelo padrão do NextAuth.js/Auth.js com providers OIDC.

| | Protocolo Digital (React puro) | Papermoon (Next.js) |
|---|---|---|
| Onde roda a troca do código OAuth | No navegador (client-side) | No servidor do Next.js (API route) |
| Tipo de client no Keycloak | Público, com PKCE | **Confidencial**, com `client_secret` |
| Lib usada | `keycloak-js` | `next-auth` (Auth.js) |

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

> **Domínio abaixo é placeholder** (`papermoon.rondonopolis.mt.gov.br`)
> — confirme o domínio real antes de criar o client de verdade.

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r Prefeitura \
    -s clientId=papermoon \
    -s name='Papermoon' \
    -s protocol=openid-connect \
    -s enabled=true \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s frontchannelLogout=true \
    -s 'redirectUris=["https://papermoon.rondonopolis.mt.gov.br/api/auth/callback/keycloak"]' \
    -s 'webOrigins=["https://papermoon.rondonopolis.mt.gov.br"]' \
    -s rootUrl='https://papermoon.rondonopolis.mt.gov.br/' \
    -s 'attributes."access.token.lifespan"=1800'
```

> `/api/auth/callback/keycloak` é o caminho **padrão** que o NextAuth.js
> usa pra callback de um provider chamado `keycloak` (convenção
> `/api/auth/callback/<provider-id>`) — ajuste se o `id` do provider no
> `authOptions` for outro nome.

> **`access.token.lifespan=1800` desde a criação** — mesmo motivo
> documentado em
> [vaultwarden.md §4](vaultwarden.md#4-causa-raiz-3-access-token-expira-em-5-minutos-sem-refresh-funcional).

Parâmetros do client:

| Campo | Valor |
|---|---|
| Client ID | `papermoon` |
| Client Authentication | `ON` (**confidencial** — ver seção 0) |
| Authentication Flow | Standard Flow habilitado |
| Valid Redirect URIs | `https://papermoon.rondonopolis.mt.gov.br/api/auth/callback/keycloak` (+ `http://localhost:3000/api/auth/callback/keycloak` em dev) |

Pega o secret gerado:
```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh get clients/<ID>/client-secret -r Prefeitura
```

## 2. Passos para a equipe Frontend (Next.js)

### Step 1 — Instalar o NextAuth.js
```bash
npm install next-auth
```

### Step 2 — Configurar o provider Keycloak

App Router (`app/api/auth/[...nextauth]/route.ts`):
```typescript
import NextAuth from "next-auth";
import KeycloakProvider from "next-auth/providers/keycloak";

const handler = NextAuth({
  providers: [
    KeycloakProvider({
      id: "keycloak",
      clientId: process.env.KEYCLOAK_CLIENT_ID!,
      clientSecret: process.env.KEYCLOAK_CLIENT_SECRET!,
      issuer: "https://sso.rondonopolis.mt.gov.br/realms/Prefeitura",
    }),
  ],
  callbacks: {
    // Repassa o access_token do Keycloak pro token de sessao do NextAuth,
    // pra depois anexar nas chamadas pra API do DRF (ver Step 3)
    async jwt({ token, account }) {
      if (account) {
        token.accessToken = account.access_token;
        token.accessTokenExpires = account.expires_at ? account.expires_at * 1000 : undefined;
        token.refreshToken = account.refresh_token;
      }
      // TODO: renovar o token usando refreshToken quando accessTokenExpires estiver proximo
      // (mesmo cuidado do keycloak.updateToken(30) do Protocolo Digital)
      return token;
    },
    async session({ session, token }) {
      session.accessToken = token.accessToken as string;
      return session;
    },
  },
});

export { handler as GET, handler as POST };
```

`.env.local`:
```bash
KEYCLOAK_CLIENT_ID=papermoon
KEYCLOAK_CLIENT_SECRET=SEU_CLIENT_SECRET_GERADO_NO_KEYCLOAK
NEXTAUTH_URL=https://papermoon.rondonopolis.mt.gov.br
NEXTAUTH_SECRET=<gerar com: openssl rand -base64 32>
```

> `KEYCLOAK_CLIENT_SECRET` e `NEXTAUTH_SECRET` só existem no servidor
> Next.js (nunca prefixados com `NEXT_PUBLIC_`, que seriam expostos no
> bundle do navegador) — mesmo cuidado de nunca commitar segredo em
> texto plano do resto deste projeto.

### Step 3 — Anexar o token nas chamadas pra API do DRF

```typescript
import { getServerSession } from "next-auth/next";

async function fetchProcessos() {
  const session = await getServerSession();
  const res = await fetch("https://api-papermoon.rondonopolis.mt.gov.br/api/processos/", {
    headers: {
      Authorization: `Bearer ${session?.accessToken}`,
    },
  });
  return res.json();
}
```

### Step 4 — Botão de login/logout

```tsx
"use client";
import { useSession, signIn, signOut } from "next-auth/react";

export function AuthButton() {
  const { data: session } = useSession();
  if (session) {
    return (
      <>
        <p>Bem-vindo, {session.user?.name}</p>
        <button onClick={() => signOut()}>Sair (SSO)</button>
      </>
    );
  }
  return <button onClick={() => signIn("keycloak")}>Entrar com Keycloak/AD</button>;
}
```

## 3. Passos para a equipe Backend (DRF)

O backend **não consulta a API do Keycloak a cada requisição** — só
valida a assinatura do JWT usando as chaves públicas (JWKS), mesmo
princípio do [Protocolo Digital §3](protocolo-digital.md#3-passos-para-a-equipe-backend-nodejs--express),
adaptado pra uma classe de autenticação do DRF.

### Step 1 — Instalar os pacotes de validação
```bash
pip install pyjwt cryptography
```

### Step 2 — Classe de autenticação DRF (`core/authentication.py`)
```python
import jwt
from jwt import PyJWKClient
from rest_framework.authentication import BaseAuthentication
from rest_framework.exceptions import AuthenticationFailed

KEYCLOAK_ISSUER = "https://sso.rondonopolis.mt.gov.br/realms/Prefeitura"
KEYCLOAK_JWKS_URL = f"{KEYCLOAK_ISSUER}/protocol/openid-connect/certs"

# PyJWKClient ja cacheia as chaves internamente - nao busca o JWKS a
# cada requisicao (client global, reaproveitado pelo processo todo)
_jwks_client = PyJWKClient(KEYCLOAK_JWKS_URL)


class KeycloakUser:
    """Representa o usuario autenticado via token, sem precisar de
    linha na tabela auth_user do Django - so' os dados vindos do JWT."""

    def __init__(self, claims: dict):
        self.claims = claims
        self.id = claims.get("sub")
        self.username = claims.get("preferred_username")
        self.email = claims.get("email")
        self.full_name = claims.get("name")
        self.roles = claims.get("realm_access", {}).get("roles", [])
        self.groups = claims.get("groups", [])
        self.is_authenticated = True

    def __str__(self):
        return self.username or self.id


class KeycloakJWTAuthentication(BaseAuthentication):
    def authenticate(self, request):
        auth_header = request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            return None  # deixa outras classes de autenticacao tentarem, se houver

        token = auth_header.split(" ")[1]

        try:
            signing_key = _jwks_client.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                issuer=KEYCLOAK_ISSUER,
                options={"verify_aud": False},  # client_id do Papermoon nao esta em "aud" por padrao no Keycloak
            )
        except jwt.PyJWTError as exc:
            raise AuthenticationFailed(f"Token invalido: {exc}")

        return (KeycloakUser(claims), token)
```

### Step 3 — Ligar no `settings.py`
```python
REST_FRAMEWORK = {
    "DEFAULT_AUTHENTICATION_CLASSES": [
        "core.authentication.KeycloakJWTAuthentication",
    ],
    "DEFAULT_PERMISSION_CLASSES": [
        "rest_framework.permissions.IsAuthenticated",
    ],
}
```

### Step 4 — Usar nas views
```python
from rest_framework.views import APIView
from rest_framework.response import Response

class ProcessosView(APIView):
    def get(self, request):
        return Response({
            "usuarioConectado": request.user.username,
            "email": request.user.email,
            "grupos": request.user.groups,
        })
```

> **`KeycloakUser` não é um `django.contrib.auth.models.User`** — não
> tem linha no banco, é só um objeto com os dados do token. Isso é
> suficiente pra maioria das APIs, mas se o Papermoon precisar
> relacionar dados a um usuário Django de verdade (`ForeignKey` pra
> `auth_user`, por exemplo), a classe de autenticação precisa criar
> /atualizar um `User` real na primeira vez que vê aquele `sub` — decisão
> de implementação a tomar com o time quando for construir de verdade.

## Estrutura esperada do token JWT

```json
{
  "exp": 1740000000,
  "iat": 1739996400,
  "iss": "https://sso.rondonopolis.mt.gov.br/realms/Prefeitura",
  "sub": "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
  "preferred_username": "mario.silva",
  "given_name": "Mario",
  "family_name": "Silva",
  "email": "mario.silva@rondonopolis.local",
  "realm_access": {
    "roles": ["default-roles-prefeitura"]
  }
}
```

> Claim `groups` só aparece se o mapper da seção 1 (não incluso por
> padrão) for adicionado ao client — mesmo padrão de todas as outras
> integrações desta pasta.

## Checklist de validação (preencher quando testar de verdade)

- [ ] Domínio real da aplicação confirmado (substituir o placeholder `papermoon.rondonopolis.mt.gov.br`)
- [ ] Client `papermoon` criado como **confidencial** (não público — ver seção 0), `access.token.lifespan` > 300s
- [ ] `redirectUris` bate exatamente com o path que o NextAuth gera (`/api/auth/callback/<id-do-provider>`)
- [ ] `KEYCLOAK_CLIENT_SECRET`/`NEXTAUTH_SECRET` vêm de variável de ambiente, confirmado que não estão commitados nem prefixados com `NEXT_PUBLIC_`
- [ ] Renovação de token implementada (`refreshToken` no callback `jwt` do NextAuth) — não só o esqueleto do exemplo
- [ ] Backend DRF rejeita corretamente token ausente e token com assinatura inválida (testar os dois casos)
- [ ] Login SSO completo testado com usuário real do AD, do Next.js até uma chamada real pra API do DRF
- [ ] Logout do Next.js (`signOut()`) encerra a sessão do Keycloak também, não só a sessão local do NextAuth
