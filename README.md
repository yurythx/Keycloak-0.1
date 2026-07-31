<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:0D1F0D,100:00FF41&height=220&section=header&text=%F0%9F%94%90%20Keycloak%20SSO%20%2B%20Vault&fontSize=42&fontColor=00FF41&animation=fadeIn&fontAlignY=35&desc=Autentica%C3%A7%C3%A3o%20%C3%9Anica%20%26%20Cofre%20de%20Segredos%20da%20Prefeitura&descSize=17&descAlignY=55&descColor=00FF41" width="100%"/>

<a href="https://github.com/yurythx/Keycloak0.1/actions/workflows/ci.yml">
  <img src="https://github.com/yurythx/Keycloak0.1/actions/workflows/ci.yml/badge.svg" alt="CI"/>
</a>
<img src="https://img.shields.io/badge/Keycloak-26.7.0-00FF41?style=for-the-badge&logo=keycloak&logoColor=black&labelColor=000000" alt="Keycloak"/>
<img src="https://img.shields.io/badge/Vaultwarden-Cofre%20de%20Senhas-00FF41?style=for-the-badge&logo=bitwarden&logoColor=black&labelColor=000000" alt="Vaultwarden"/>
<img src="https://img.shields.io/badge/PostgreSQL-16-00FF41?style=for-the-badge&logo=postgresql&logoColor=black&labelColor=000000" alt="PostgreSQL"/>
<img src="https://img.shields.io/badge/Docker-Compose-00FF41?style=for-the-badge&logo=docker&logoColor=black&labelColor=000000" alt="Docker"/>
<br/>
<img src="https://img.shields.io/badge/🔒_Secrets-Docker%20Secrets%2C%20nunca%20no%20git-00FF41?style=flat-square&labelColor=000000" alt="Secrets"/>
<img src="https://img.shields.io/badge/🛡️_Rede-Isolada%20%2F%20internal%3A%20true-00FF41?style=flat-square&labelColor=000000" alt="Rede isolada"/>
<img src="https://img.shields.io/badge/🚫_Autorregistro-Fechado%20por%20padrão-00FF41?style=flat-square&labelColor=000000" alt="Autorregistro fechado"/>
<img src="https://img.shields.io/badge/🔑_SSO-OpenID%20Connect-00FF41?style=flat-square&labelColor=000000" alt="SSO"/>

<img src="https://readme-typing-svg.demolab.com?font=Fira+Code&weight=600&size=20&duration=3000&pause=900&color=00FF41&center=true&vCenter=true&width=650&lines=SSO+institucional+%3E+Active+Directory+(LDAPS);Cofre+de+senhas+%3E+Vaultwarden+%3E+login+via+SSO;Federa%C3%A7%C3%A3o+%C3%BAnica+%3E+Django+%C2%B7+GLPI+%C2%B7+Zabbix;Build+fora+da+VM+%3E+CI%2FCD+%3E+Registry+%3E+Deploy;Zero+senha+em+texto+plano+%3E+secrets+versionados+fora+do+git;Zero+autorregistro+publico+%3E+contas+so+via+admin" alt="Typing SVG"/>

</div>

---

Stack de **Single Sign-On (SSO)** da prefeitura, construída sobre o
[Keycloak](https://www.keycloak.org/), federada ao **Active Directory**
via LDAPS e integrada à Intranet (Django), ao GLPI e ao Zabbix. Roda
inteiramente em **Docker Compose** — Postgres + Keycloak, **Vaultwarden**
(cofre de senhas, com seu próprio Postgres) e Portainer opcional —
provisionada e operada por scripts próprios com tema visual "Matrix" no
terminal. TLS, redirecionamento HTTP→HTTPS e balanceamento de carga
ficam a cargo do servidor web/proxy reverso já existente na prefeitura,
fora desta stack.

```bash
git clone https://github.com/yurythx/Keycloak0.1.git /opt/keycloak-stack
cd /opt/keycloak-stack
./setup.sh      # provisiona .env, segredos e certificados
./deploy.sh     # sobe a stack, aguarda ficar healthy, mostra o painel
```

## Arquitetura

```
                      Internet / rede da prefeitura
                                │
                      ┌──────────────────────┐
                      │  Servidor web da      │  ← já existe na prefeitura,
                      │  prefeitura (fora     │     FORA desta stack: TLS,
                      │  desta stack)         │     redirect HTTP→HTTPS e
                      │  TLS + proxy reverso  │     balanceamento de carga
                      │  + balanceamento      │
                      └──────────┬───────────┘
                                 │ HTTP puro, porta ${KEYCLOAK_PORT}
                                 │ (host:porta restrito por firewall
                                 │  ao IP desse proxy)
                      ┌──────────┴──────────┐
                      │      Keycloak       │──── LDAPS ──→ Active Directory
                      │  (porta 8080        │
                      │   publicada no host) │
                      └──────────┬──────────┘
                                 │ rede "backend" (internal: true,
                                 │  sem rota de saída para a internet)
                      ┌──────────┴──────────┐
                      │      Postgres       │  ← nunca exposto, nem para o host
                      └─────────────────────┘

  Portainer (opcional) — bind 127.0.0.1:9443, só via SSH tunnel/VPN

  Vaultwarden (cofre de senhas) — stack irmã isolada (rede, banco e
  secrets próprios), mesmo proxy reverso externo, ver docs/06-vaultwarden.md
```

## O que essa stack já resolve

| | |
|---|---|
| 🟢 **Build fora da VM** | GitHub Actions **e** GitLab CI, lado a lado — lint, build, scan de vulnerabilidades (Trivy) e push pro registry. A VM só faz `pull`. |
| 🟢 **Segredos fora do git** | Senhas de 32 caracteres geradas pelo `setup.sh`, montadas via Docker secrets, permissão de arquivo ajustada pro usuário não-root do Keycloak — nunca em `.env` versionado. |
| 🟢 **Isolamento de rede real** | Postgres numa rede `internal: true`, sem rota de saída — nem o host alcança a porta 5432. |
| 🟢 **TLS via infraestrutura existente** | O Keycloak publica só HTTP puro numa porta não padrão do host — TLS, redirecionamento e balanceamento ficam com o servidor web/proxy reverso que a prefeitura já opera, sem duplicar essa camada dentro da stack. |
| 🟢 **Console de operação** | `./manage.sh`, estilo TrueNAS: logs, reiniciar, backup, restore-drill, uso de recursos ao vivo (`docker stats`), shell no contêiner. |
| 🟢 **Identidade visual** | Tema customizado do Keycloak (`keycloak.v2`/PatternFly 5) com logo e cores da prefeitura — ver [`docs/tema-visual.md`](docs/tema-visual.md). |
| 🟢 **Achados reais documentados** | Cada incidente de produção (permissão de secret, `restart` vs `up -d`, certificado desatualizado após troca de domínio, HSTS travando o navegador) virou correção **e** nota na documentação — não só um patch silencioso. |
| 🟢 **Vaultwarden com autorregistro fechado** | `SIGNUPS_ALLOWED=false` fixo no compose (achado de revisão de segurança) — contas são criadas só pelo admin, sem precisar de SMTP. Ver [`docs/06-vaultwarden.md`](docs/06-vaultwarden.md). |
| 🟢 **SSO unificado Keycloak ↔ Vaultwarden** | O cofre de senhas autentica contra o mesmo Keycloak (OpenID Connect, PKCE) — uma identidade só pra SSO institucional e pra cofre de credenciais. |

<div align="center">

### 🔐 Segurança em camadas — nada fica exposto por acidente

| Camada | O que protege | Como |
|---|---|---|
| 🕸️ **Rede** | Bancos de dados | `internal: true` — Postgres do Keycloak e do Vaultwarden sem rota de saída, nem o host alcança |
| 🔑 **Segredos** | Senhas e tokens | Docker secrets com permissão restrita, **zero** texto plano em `.env` versionado |
| 🚪 **Borda** | Portas publicadas | Só o necessário exposto ao proxy da prefeitura, restrito por firewall ao IP dele |
| 🙅 **Cadastro** | Contas no cofre | Autorregistro **desligado**; contas só via admin ou convite, sem depender de SMTP |
| 🪪 **Identidade** | Login | SSO único via Keycloak (federado ao AD) — sem senha duplicada entre sistemas |
| 🩹 **Supply chain** | Imagem publicada | Build fora da VM, scan de vulnerabilidades (Trivy) antes do push pro registry |
| 🧯 **Continuidade** | Dados do cofre | Backup diário automatizado (banco **e** chave RSA/anexos) + drill de restauração testável |

</div>

## Documentação completa

Todo o passo a passo operacional — pré-requisitos, provisionamento,
federação com o AD, integração dos sistemas, go-live — está em
[**`docs/README.md`**](docs/README.md), organizado em etapas com
portões de validação (Go/No-Go) entre cada uma.

| Etapa | Documento |
|---|---|
| 0 | [Pré-requisitos e Governança](docs/00-pre-requisitos.md) |
| 1 | [Provisionamento e Subida da Stack](docs/01-provisionamento.md) |
| 2 | [Configuração Básica do Keycloak](docs/02-configuracao-keycloak.md) |
| 3 | [Federação com o Active Directory](docs/03-federacao-ad.md) |
| 4 | [Integração dos Sistemas Piloto](docs/04-integracao-sistemas.md) |
| 5 | [Go-Live e Operação Contínua](docs/05-golive-operacao.md) |
| 6 | [🔐 Vaultwarden (Cofre de Senhas)](docs/06-vaultwarden.md) |
| — | [Referência de Scripts](docs/scripts-referencia.md) · [Tema Visual](docs/tema-visual.md) · [CI/CD e Registry](docs/ci-cd.md) · [Verificação Final](docs/verificacao-final.md) |

<div align="center">
<img src="https://capsule-render.vercel.app/api?type=waving&color=0:00FF41,50:0D1F0D,100:000000&height=100&section=footer" width="100%"/>

🔐 *"Zero senha em texto plano. Zero autorregistro público. Zero surpresa."*

</div>
