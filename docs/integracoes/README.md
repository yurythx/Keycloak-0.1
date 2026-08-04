# Integrações com o Keycloak

[← Documentação Geral](../README.md)

Todas as integrações de sistemas com o SSO desta stack (realm
`Prefeitura`), separadas por sistema. Duas categorias diferentes nesta
pasta — a tabela abaixo marca qual é qual:

- ✅ **Testada em produção/homologação**: integração real, feita e
  depurada ao vivo, com os bugs de verdade encontrados e corrigidos
  documentados — pronta pra replicar.
- 📋 **Guia de implementação**: roteiro pra equipe de desenvolvimento
  seguir quando o sistema for construído/integrado — ainda não existe
  rodando, então não tem "achados reais" ainda. Atualize o documento
  assim que a integração for testada de verdade, movendo pra ✅.

| Sistema | Status | Documento | Protocolo | O que cobre |
|---|---|---|---|---|
| GLPI | ✅ Testada | [glpi.md](glpi.md) | OIDC | Plugin `singlesignon`, volume persistente, cookie `SameSite`, perfil padrão |
| Active Directory | ✅ Testada | [active-directory.md](active-directory.md) | LDAP (federação) | Realm real, e-mail via `userPrincipalName`, sync de grupos, achado do grupo `Administrators` |
| Vaultwarden | ✅ Testada | [vaultwarden.md](vaultwarden.md) | OIDC | Realm errado, access token de 5min, senha mestra separada |
| Zabbix | ✅ Testada | [zabbix.md](zabbix.md) | SAML | Client SAML, provisionamento JIT por grupo do AD, atributo duplicado |
| Grafana | ✅ Testada | [grafana.md](grafana.md) | OIDC | Mapeamento de grupo→papel via JMESPath, `GF_SERVER_ROOT_URL` |
| Intranet (Django) | 📋 Guia | [intranet-django.md](intranet-django.md) | OIDC | `mozilla-django-oidc`, Authorization Code Flow (client confidencial) |
| Protocolo Digital (React + Node.js) | 📋 Guia | [protocolo-digital.md](protocolo-digital.md) | OIDC | `keycloak-js` (SPA, PKCE) + validação de JWT via JWKS no backend |
| Balcão de Empregos (Django) | 📋 Guia | [balcao-empregos.md](balcao-empregos.md) | OIDC | SSO só na área administrativa — site público de candidatos fica fora do Keycloak |

## Padrões que se repetem entre integrações

Coisas descobertas numa integração que valem a pena checar de cara nas
próximas, em vez de esperar o mesmo sintoma aparecer de novo:

1. **Realm certo**: sempre `Prefeitura` (maiúsculo) — nunca
   `prefeitura` minúsculo (ver [active-directory.md §1](active-directory.md#1-o-que-a-federação-real-é-diferente-do-plano)).
2. **`access.token.lifespan` do client**: subir de 300s (padrão do
   Keycloak) pra pelo menos 1800s **desde a criação do client**, não
   esperar o sintoma de sessão caindo aparecer (achado em
   [vaultwarden.md §4](vaultwarden.md#4-causa-raiz-3-access-token-expira-em-5-minutos-sem-refresh-funcional)).
3. **URL pública/base configurável da ferramenta** (`baseurl` no
   Zabbix, `root_url` no Grafana, `redirect_uri` em qualquer client):
   configurar explicitamente com o endereço público real de cara —
   várias ferramentas calculam isso sozinhas usando a porta/host
   interno por padrão, o que quebra o `redirect_uri` contra o Keycloak.
4. **Mapper de grupos multi-valor em SAML**: sempre `single=true`, ou
   vira múltiplos elementos `<Attribute>` com o mesmo `Name` e o parser
   SAML do outro lado rejeita (achado em
   [zabbix.md §4.2](zabbix.md#42-found-an-attribute-element-with-duplicated-name)).
5. **Testar sem senha real de ninguém**: técnica de impersonation via
   admin do Keycloak, documentada em
   [glpi.md §5](glpi.md#5-testar-sem-precisar-de-senha-real-de-ninguém)
   (OIDC) e [zabbix.md §6](zabbix.md#6-testar-sem-senha-real-fluxo-saml-via-impersonation)
   (SAML, mais elaborado).
6. **Cache do proxy externo (192.168.0.218)**: já causou bug real duas
   vezes (CSS do Vaultwarden, CSS do tema de login) — qualquer recurso
   estático servido pelo Keycloak/apps por trás desse proxy pode estar
   desatualizado por até 30 dias pra quem acessa pelo domínio público,
   mesmo com a origem já corrigida. Testar direto na origem (túnel SSH,
   `curl` local) antes de assumir que uma correção "não funcionou".
7. **Sistema de uso público (não só interno)**: antes de aplicar SSO
   no app inteiro, confirmar se ele tem uma área aberta pro cidadão
   (que não tem conta no AD) — nesse caso o Keycloak protege só a área
   administrativa/staff, o login público continua com autenticação
   própria da aplicação, separada. Ver
   [balcao-empregos.md §0](balcao-empregos.md#0-⚠️-antes-de-tudo-sso-cobre-só-a-área-administrativa-não-o-site-público)
   pra esse desenho completo.
