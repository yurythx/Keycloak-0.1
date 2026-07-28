# Etapa 3 — Federação de Identidades com o Active Directory (LDAPS)

[← Etapa 2](02-configuracao-keycloak.md) · [Índice](README.md) · Próxima etapa: [Etapa 4 →](04-integracao-sistemas.md)

Conecta o Keycloak ao Active Directory da prefeitura via LDAPS, para que
servidores públicos entrem com a mesma conta de rede — sem duplicar senha
em lugar nenhum.

> **Caminho recomendado**: `./deploy.sh --configure-ldap` (ou
> `./scripts/configure_ldap.sh` diretamente, se a stack já estiver no ar)
> automatiza as ações 2 e 3 abaixo via `kcadm.sh`, o CLI administrativo do
> próprio Keycloak — chamado por dentro do contêiner, sem expor nenhuma
> porta administrativa extra. É idempotente: rodar de novo atualiza a
> configuração existente em vez de duplicar. Detalhes completos em
> [Referência de Scripts](scripts-referencia.md#scriptsconfigure_ldapsh).
> A ação 1 (copiar a CA) e o portão de validação continuam manuais mesmo
> usando o script.

## Ações

### 1. Copiar a CA raiz do AD
```bash
cp <caminho-da-ca-do-ad>.pem ./certs/ad-ca.pem
docker compose restart keycloak   # recarrega o truststore
```

### 2. Configurar o provider LDAP

**Automatizado (recomendado):**
```bash
./scripts/configure_ldap.sh
```
Pergunta interativamente: realm, Connection URL, Bind DN, senha da conta
de bind (gravada em `secrets/ldap_bind_password.txt`, nunca em texto
plano no `.env`), Users DN e Groups DN — com valores padrão derivados de
`AD_DOMAIN`/`AD_DC_HOSTNAME` do `.env`.

**Manual (alternativa)**, via Admin Console → realm `prefeitura` →
**User Federation → Add LDAP**:
- Connection URL: `ldaps://dc01.rondonopolis.local:636`
- Bind DN: `CN=svc-keycloak,OU=ServiceAccounts,DC=rondonopolis,DC=local`
- Edit Mode: `READ_ONLY`

### 3. Mapear os grupos
O script já cria o mapper `group-ldap-mapper` automaticamente. Se feito
manualmente, adicione um mapper `group-ldap-mapper` apontando para
`OU=Grupos,DC=rondonopolis,DC=local`.

## Portão de Validação

- [ ] **Test Connection**: sucesso, sem erro de PKIX/certificado (se
      falhar aqui, confira se `certs/ad-ca.pem` foi copiada e o Keycloak
      reiniciado).
- [ ] **Test Authentication**: credenciais da conta de bind validadas.
- [ ] **Synchronize all users**: servidores públicos aparecem na aba
      `Users` do realm `prefeitura`.
- [ ] **Login real**: autenticar com a conta de rede de um servidor da
      equipe — a senha é validada diretamente contra o AD, sem ser
      persistida no banco do Keycloak.

---
Próxima etapa: **[Etapa 4 — Integração dos Sistemas Piloto →](04-integracao-sistemas.md)**
