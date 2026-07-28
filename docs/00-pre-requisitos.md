# Etapa 0 — Pré-requisitos e Governança

[← Índice](README.md) · Próxima etapa: [Etapa 1 — Provisionamento →](01-provisionamento.md)

Antes de tocar em qualquer comando, esta etapa garante que a equipe tem
tudo em mãos para não travar no meio da implantação — dependências
externas (AD, certificados) costumam ser o gargalo real, não a stack em
si.

## Ações

### 1. Dimensionar a VM
Mínimo recomendado: **8 vCPU / 16 GB RAM / 100 GB de disco**. O tuning do
Postgres usa `shared_buffers=1GB` e o Keycloak roda com heap JVM de até
4 GB — some isso ao overhead do SO e a uma margem de crescimento.

### 2. Firewall
TLS, redirecionamento e balanceamento de carga ficam a cargo do servidor
web/proxy reverso que a prefeitura já opera — **fora desta stack**. Aqui,
liberar entrada **apenas** na porta configurada em `KEYCLOAK_PORT` (ex.:
`18443`) na VM, e **restrita ao IP daquele proxy** — nenhuma outra porta
(5432 do Postgres, 9000 de métricas) deve ser alcançável de fora do host
— a stack já garante isso por padrão (ver [Etapa 1](01-provisionamento.md)),
mas o firewall de borda é a segunda camada de defesa.

### 3. Conta de serviço do Active Directory
Solicitar à equipe do AD a criação de uma conta de serviço, por exemplo:
```
CN=svc-keycloak,OU=ServiceAccounts,DC=rondonopolis,DC=local
```
Com permissão **somente leitura** (bind/consulta) — sem privilégios
administrativos no domínio. Essa conta é usada na
[Etapa 3](03-federacao-ad.md) para a federação LDAPS.

### 4. Proxy reverso externo (TLS, redirect e balanceamento)
Esta stack **não** inclui um proxy reverso próprio — quem termina o TLS,
redireciona HTTP→HTTPS e faz o balanceamento é o servidor web que a
prefeitura já opera fora dela. Antes do deploy, levantar com quem
administra esse servidor:
- **O IP (ou faixa) de onde ele vai alcançar esta VM** — vai em
  `PROXY_TRUSTED_ADDRESSES` no `.env` e também é o único IP liberado no
  firewall (item 2) para a porta `KEYCLOAK_PORT`. Sem isso certo, o
  Keycloak não confia no header `X-Forwarded-Proto` e gera links `http://`
  em vez de `https://` nos fluxos OIDC.
- **Confirmação de que ele encaminha `X-Forwarded-Proto`, `X-Forwarded-Host`
  e `X-Forwarded-For`** corretamente para `http://<IP-da-VM>:KEYCLOAK_PORT`.
- **Confirmação de que ele já injeta os headers de segurança** (HSTS,
  `X-Content-Type-Options`, `X-Frame-Options`) — esta stack não injeta mais
  nenhum, isso passou a ser responsabilidade do proxy externo.

Ver [Referência de Scripts](scripts-referencia.md#proxy-reverso-externo).

Ainda é necessária:
- **CA raiz do Active Directory**, exportada em `.pem`, para o truststore
  do Keycloak (necessária na [Etapa 3](03-federacao-ad.md) para LDAPS) —
  isso é independente do TLS do proxy externo.

### 5. Janela de manutenção
Aprovada e comunicada às áreas afetadas.

### 6. Procedimento de rollback
Documentado e aprovado antes do go-live, por exemplo:
```bash
./deploy.sh --down
# restaurar snapshot da VM, ou reverter DNS para o sistema de login anterior
```
`./deploy.sh --down` preserva o volume do Postgres por padrão — só use
`--down --purge` se o objetivo explícito for apagar os dados (ver
[Referência de Scripts](scripts-referencia.md#deploysh)).

## Portão de Validação (Go/No-Go)

- [ ] Checklist acima assinado pelo responsável de infraestrutura do AD e
      pelo gestor da janela de manutenção.
- [ ] IP do proxy reverso da prefeitura e CA raiz do AD já em mãos —
      **não iniciar a Etapa 1 sem eles**.

---
Próxima etapa: **[Etapa 1 — Provisionamento e Subida da Stack →](01-provisionamento.md)**
