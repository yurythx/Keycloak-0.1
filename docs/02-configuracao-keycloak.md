# Etapa 2 — Configuração Básica do Keycloak e Testes Isolados (sem AD)

[← Etapa 1](01-provisionamento.md) · [Índice](README.md) · Próxima etapa: [Etapa 3 →](03-federacao-ad.md)

Antes de plugar o Active Directory, valida que o Keycloak em si emite
token corretamente — isolando qualquer problema de configuração de rede,
TLS ou realm de problemas de LDAP, que só entram na próxima etapa.

## Ações

### 1. Login no console administrativo
```bash
cat secrets/kc_admin_password.txt
```
Acesse `https://sso.rondonopolis.mt.gov.br/admin` e logue como `kc_admin`
com a senha acima.

### 2. Criar o realm de produção
Criar o realm `prefeitura`. O realm `master` fica isolado, de uso
exclusivo administrativo — nenhum client ou usuário de aplicação deve ser
criado nele.

> **Identidade visual**: se quiser já deixar a tela de login com a logo e
> as cores da prefeitura, este é um bom momento — ver
> [Tema Visual](tema-visual.md). Não bloqueia os portões desta etapa,
> pode ser feito a qualquer momento.

### 3. Criar grupos e usuário de teste
No realm `prefeitura`, criar os grupos `TI_ADMIN` e `SERVIDOR_GERAL`, e um
usuário local de teste (`teste.ti`) com senha temporária.

### 4. Criar o client de teste
Criar o client `test-oidc`, Access Type `Confidential`.

## Portão de Validação

- [ ] **Realm master intacto**: nenhum client ou usuário de aplicação foi
      criado no `master`.
- [ ] **Emissão de JWT**:
  ```bash
  curl -d "client_id=test-oidc" \
       -d "client_secret=<SECRET_GERADO>" \
       --data-urlencode "username=teste.ti" \
       --data-urlencode "password=<SENHA>" \
       -d "grant_type=password" \
       https://sso.rondonopolis.mt.gov.br/realms/prefeitura/protocol/openid-connect/token
  ```
  Deve retornar um `access_token` JWT válido.

  > **Atenção**: segredos gerados com `openssl rand -base64 32` contêm
  > `+`, `/` e `=`. Use sempre `--data-urlencode` para `username` e
  > `password` no curl — com `-d` puro o `+` vira espaço e a autenticação
  > falha com `invalid_grant` mesmo com a senha certa (achado real,
  > validado durante o desenvolvimento desta stack).

- [ ] **Auditoria do token**: decodificar em [jwt.io](https://jwt.io) e
      confirmar que `iss` = `https://sso.rondonopolis.mt.gov.br/realms/prefeitura`.

---
Próxima etapa: **[Etapa 3 — Federação com o Active Directory →](03-federacao-ad.md)**
