# Integração Protocolo Digital (React + Node.js) ↔ Keycloak (SSO via OIDC)

[← Índice de Integrações](README.md) · [Documentação Geral](../README.md)

**Status**: guia de implementação pra equipe de desenvolvimento — o
Protocolo Digital ainda não existe rodando/integrado. Diferente das
outras integrações desta pasta (GLPI, Vaultwarden, Zabbix, Grafana —
sistemas reais, já testados, com bugs reais documentados), este
documento é o **roteiro a seguir** quando as equipes frontend/backend
forem implementar. Atualize com achados reais assim que a integração
for testada de verdade.

**Público-alvo**: desenvolvedores frontend (React) e backend (Node.js).
**Escopo**: autenticação centralizada via OpenID Connect (OIDC), com
aplicação **desacoplada** (SPA + API separadas, diferente da Intranet
Django que é server-side — ver [intranet-django.md](intranet-django.md)).
**Provedor de Identidade**: Keycloak, realm `Prefeitura`, federado ao
Active Directory (ver [active-directory.md](active-directory.md)).

## Visão geral da arquitetura

- **React (frontend)**: autentica o usuário no Keycloak via
  **Authorization Code Flow com PKCE** e obtém um Access Token (JWT).
  Client **público** (SPA não guarda segredo com segurança nenhuma —
  diferente da Intranet Django).
- **Node.js (backend)**: recebe o token no cabeçalho HTTP
  (`Authorization: Bearer <token>`) e valida a assinatura
  criptográfica usando as chaves públicas do Keycloak (JWKS) — **não
  chama o Keycloak a cada requisição**, só valida a assinatura
  localmente.

```
React (SPA) ──Authorization Code + PKCE──▶ Keycloak (realm Prefeitura)
     │                                            │
     │ Access Token (JWT)                         │ JWKS (chaves publicas)
     ▼                                            │
Node.js (API) ◀──valida assinatura do JWT localmente──┘
```

## Endpoints do Keycloak (realm `Prefeitura`)

| Recurso | URL |
|---|---|
| Base URL do realm | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura` |
| Authorization Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/auth` |
| Token Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/token` |
| JWKS Endpoint (chaves públicas) | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/certs` |
| Logout Endpoint | `https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/logout` |

## 1. Criar o client no Keycloak

```bash
docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh create clients -r Prefeitura \
    -s clientId=protocolo-digital-frontend \
    -s name='Protocolo Digital' \
    -s protocol=openid-connect \
    -s enabled=true \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s frontchannelLogout=true \
    -s 'redirectUris=["https://protocolo.rondonopolis.mt.gov.br/*","http://localhost:3000/*"]' \
    -s 'webOrigins=["https://protocolo.rondonopolis.mt.gov.br","http://localhost:3000"]' \
    -s rootUrl='https://protocolo.rondonopolis.mt.gov.br/' \
    -s 'attributes."pkce.code.challenge.method"=S256' \
    -s 'attributes."access.token.lifespan"=1800'
```

Parâmetros do client:

| Campo | Valor |
|---|---|
| Client ID | `protocolo-digital-frontend` |
| Client Authentication | `OFF` (client **público** — SPA não armazena segredo) |
| Authentication Flow | Standard Flow com PKCE |
| Valid Redirect URIs | `https://protocolo.rondonopolis.mt.gov.br/*` (+ `http://localhost:3000/*` em dev) |
| Web Origins (CORS) | `https://protocolo.rondonopolis.mt.gov.br` (+ `http://localhost:3000` em dev) |

> **`access.token.lifespan=1800` aplicado desde a criação** — mesmo
> motivo documentado em
> [vaultwarden.md §4](vaultwarden.md#4-causa-raiz-3-access-token-expira-em-5-minutos-sem-refresh-funcional):
> o padrão do Keycloak (300s) já causou um bug real de sessão numa
> integração anterior.

> **Lembrar de remover `http://localhost:3000/*` das Redirect
> URIs/Web Origins antes de considerar produção "fechada"** — deixar
> uma origem de desenvolvimento sempre liberada num client de produção
> é uma superfície de ataque desnecessária.

## 2. Passos para a equipe Frontend (React)

### Step 1 — Instalar o SDK oficial
```bash
npm install keycloak-js
```

### Step 2 — Instanciar a lib (`src/services/keycloak.js`)
```javascript
import Keycloak from 'keycloak-js';

const keycloak = new Keycloak({
  url: 'https://sso.rondonopolis.mt.gov.br/',
  realm: 'Prefeitura',
  clientId: 'protocolo-digital-frontend'
});

export default keycloak;
```

### Step 3 — Inicializar no App (`src/index.js`)
```javascript
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import keycloak from './services/keycloak';

const root = ReactDOM.createRoot(document.getElementById('root'));

// Inicializacao com PKCE ativado
keycloak.init({
  onLoad: 'login-required',
  pkceMethod: 'S256',
  checkLoginIframe: false
}).then((authenticated) => {
  if (authenticated) {
    root.render(<App />);
  } else {
    window.location.reload();
  }
}).catch((error) => {
  console.error("Erro na autenticacao SSO:", error);
});
```

### Step 4 — Anexar o token nas requisições HTTP (Axios)
```javascript
import axios from 'axios';
import keycloak from './services/keycloak';

const api = axios.create({
  baseURL: 'https://api-protocolo.rondonopolis.mt.gov.br'
});

api.interceptors.request.use(async (config) => {
  if (keycloak.token) {
    // Renova o token se faltar menos de 30 segundos para expirar
    try {
      await keycloak.updateToken(30);
    } catch (error) {
      console.error("Sessao expirada. Redirecionando para login...");
      keycloak.login();
    }

    config.headers.Authorization = `Bearer ${keycloak.token}`;
  }
  return config;
}, (error) => {
  return Promise.reject(error);
});

export default api;
```

## 3. Passos para a equipe Backend (Node.js / Express)

O backend **não consulta a API do Keycloak a cada requisição** — só
valida a assinatura do JWT recebido usando as chaves públicas (JWKS).

### Step 1 — Instalar os pacotes de validação
```bash
npm install jsonwebtoken jwks-rsa
```

### Step 2 — Middleware de autenticação (`middlewares/auth.js`)
```javascript
const jwt = require('jsonwebtoken');
const jwksRsa = require('jwks-rsa');

// Cliente para buscar a chave publica (JWKS) do Keycloak
const jwksClient = jwksRsa({
  cache: true,
  rateLimit: true,
  jwksRequestsPerMinute: 10,
  jwksUri: 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura/protocol/openid-connect/certs'
});

// Resolve a chave de assinatura a partir do header 'kid' do JWT
function getKey(header, callback) {
  jwksClient.getSigningKey(header.kid, (err, key) => {
    if (err) {
      return callback(err, null);
    }
    const signingKey = key.getPublicKey();
    callback(null, signingKey);
  });
}

function verifyKeycloakToken(req, res, next) {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Acesso nao autorizado: Token ausente' });
  }

  const token = authHeader.split(' ')[1];

  const options = {
    issuer: 'https://sso.rondonopolis.mt.gov.br/realms/Prefeitura',
    algorithms: ['RS256']
  };

  jwt.verify(token, getKey, options, (err, decodedToken) => {
    if (err) {
      console.error("Falha na validacao do JWT:", err.message);
      return res.status(401).json({ error: 'Acesso nao autorizado: Token invalido' });
    }

    req.user = {
      id: decodedToken.sub,
      username: decodedToken.preferred_username,
      email: decodedToken.email,
      fullName: decodedToken.name,
      roles: decodedToken.realm_access ? decodedToken.realm_access.roles : []
    };

    next();
  });
}

module.exports = verifyKeycloakToken;
```

### Step 3 — Usar o middleware nas rotas
```javascript
const express = require('express');
const verifyKeycloakToken = require('./middlewares/auth');

const app = express();
app.use(express.json());

app.get('/api/processos', verifyKeycloakToken, (req, res) => {
  res.json({
    message: "Consulta realizada com sucesso",
    usuarioConectado: req.user.username,
    email: req.user.email
  });
});

app.listen(3000, () => console.log('Servidor rodando na porta 3000'));
```

## Estrutura esperada do token JWT

Payload de exemplo (dados reais do realm `Prefeitura`, incluindo o
achado documentado em [active-directory.md](active-directory.md) sobre
o `email` vir de `userPrincipalName`, não de `mail`):
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
    "roles": [
      "default-roles-prefeitura"
    ]
  }
}
```

> Pra receber o claim `groups` (grupos do AD, útil pra decidir
> permissão sem consultar o AD diretamente), é preciso adicionar o
> mapper `oidc-group-membership-mapper` no client — mesmo padrão usado
> em todas as outras integrações (ver exemplo em
> [grafana.md §2](grafana.md#2-client-oidc-no-keycloak)). Não vem por
> padrão.

## Checklist de validação (preencher quando testar de verdade)

- [ ] Client `protocolo-digital-frontend` criado, `publicClient=true`, PKCE `S256`
- [ ] `access.token.lifespan` > 300s
- [ ] `redirectUris`/`webOrigins` de desenvolvimento (`localhost:3000`) removidos antes de produção fechar
- [ ] Login SSO completo testado com usuário real do AD, PKCE confirmado no fluxo (inspecionar a URL de authorize — deve ter `code_challenge`)
- [ ] Backend rejeita corretamente token sem `Authorization` header e token com assinatura inválida (testar os dois casos)
- [ ] `keycloak.updateToken(30)` testado de verdade — sessão não deve cair no meio do uso
- [ ] Logout global: clicar "Sair" encerra a sessão do Keycloak também (`keycloak.logout()`), não só o estado local da SPA
