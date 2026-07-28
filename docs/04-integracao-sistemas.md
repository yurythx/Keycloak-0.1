# Etapa 4 — Integração e Homologação dos Sistemas Piloto

[← Etapa 3](03-federacao-ad.md) · [Índice](README.md) · Próxima etapa: [Etapa 5 →](05-golive-operacao.md)

Conecta os três sistemas piloto ao Keycloak como Identity Provider,
validando SSO (login único) e SLO (logout único) de ponta a ponta.

## Ações

### 1. Intranet Django (OIDC)
- Client `intranet-django` no Keycloak, callback
  `https://intranet.rondonopolis.mt.gov.br/oidc/callback/`.
- Biblioteca `mozilla-django-oidc`, configurada em `settings.py`.

### 2. GLPI (OIDC)
- Ativar o plugin OAuth2/OIDC no GLPI.
- Client `glpi-chamados` no Keycloak, mapeando grupos do AD
  (`TI_SUPORTE` → perfil `Technician`).

### 3. Zabbix (SAML 2.0 — **não OIDC**)

> **Correção importante**: o Zabbix **não tem suporte nativo a OpenID
> Connect** (apenas SAML 2.0 nativo, confirmado na documentação oficial).
> Usar OIDC exigiria um proxy Apache adicional com `mod_auth_openidc`, o
> que foi descartado por adicionar complexidade desnecessária.

- Criar um client **SAML** no Keycloak (`zabbix-saml`).
- No Zabbix: **Administração → Autenticação → SAML** (não existe opção
  "OpenID Connect" no menu — se não aparecer SAML, a versão do Zabbix
  precisa de upgrade, mínimo recomendado 6.0+).
- IdP metadata do Keycloak:
  `https://sso.rondonopolis.mt.gov.br/realms/prefeitura/protocol/saml/descriptor`
- Habilitar provisionamento Just-In-Time (JIT).

## Portão de Validação

- [ ] **SSO real**: logar na Intranet Django, abrir nova aba e acessar o
      GLPI — deve logar automaticamente, sem pedir senha.
- [ ] **RBAC**: usuário comum do AD entra no GLPI como `Requester`; um
      técnico (grupo `TI_SUPORTE`) entra como `Technician`.
- [ ] **SLO (logout único)**: clicar em "Sair" na Intranet e, ao atualizar
      GLPI e Zabbix, o usuário deve estar deslogado de todas as sessões.

---
Próxima etapa: **[Etapa 5 — Go-Live e Operação Contínua →](05-golive-operacao.md)**
