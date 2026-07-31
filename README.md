<div align="center">

<img src="https://capsule-render.vercel.app/api?type=waving&color=0:000000,50:1F0D0D,100:FF4500&height=220&section=header&text=%F0%9F%94%90%20Keycloak%20SSO%20%2B%20Vault&fontSize=42&fontColor=FF4500&animation=fadeIn&fontAlignY=35&desc=Autentica%C3%A7%C3%A3o%20%C3%9Anica%20%26%20Cofre%20de%20Segredos%20da%20Institui%C3%A7%C3%A3o&descSize=17&descAlignY=55&descColor=FF4500" width="100%"/>

<a href="https://github.com/yurythx/Keycloak-0.1/actions/workflows/ci.yml">
  <img src="https://github.com/yurythx/Keycloak-0.1/actions/workflows/ci.yml/badge.svg" alt="CI"/>
</a>
<img src="https://img.shields.io/badge/Keycloak-26.7.0-FF4500?style=for-the-badge&logo=keycloak&logoColor=black&labelColor=000000" alt="Keycloak"/>
<img src="https://img.shields.io/badge/Vaultwarden-Cofre%20de%20Senhas-FF4500?style=for-the-badge&logo=bitwarden&logoColor=black&labelColor=000000" alt="Vaultwarden"/>
<img src="https://img.shields.io/badge/PostgreSQL-16-FF4500?style=for-the-badge&logo=postgresql&logoColor=black&labelColor=000000" alt="PostgreSQL"/>
<img src="https://img.shields.io/badge/Docker-Compose-FF4500?style=for-the-badge&logo=docker&logoColor=black&labelColor=000000" alt="Docker"/>
<br/>
<img src="https://img.shields.io/badge/Secrets-Docker%20Secrets%2C%20nunca%20no%20git-FF4500?style=flat-square&labelColor=000000&logo=lock&logoColor=FF4500" alt="Secrets"/>
<img src="https://img.shields.io/badge/Rede-Isolada%20%2F%20internal%20true-FF4500?style=flat-square&labelColor=000000&logo=cloudflare&logoColor=FF4500" alt="Rede isolada"/>
<img src="https://img.shields.io/badge/Autorregistro-Fechado%20por%20padr%C3%A3o-FF4500?style=flat-square&labelColor=000000&logo=googlesecuritycenter&logoColor=FF4500" alt="Autorregistro fechado"/>
<img src="https://img.shields.io/badge/SSO-OpenID%20Connect-FF4500?style=flat-square&labelColor=000000&logo=openid&logoColor=FF4500" alt="SSO"/>

<img src="https://readme-typing-svg.demolab.com?font=Fira+Code&weight=600&size=20&duration=3000&pause=900&color=FF4500&center=true&vCenter=true&width=650&lines=SSO+institucional+%3E+Active+Directory+(LDAPS);Cofre+de+senhas+%3E+Vaultwarden+%3E+login+via+SSO;Federa%C3%A7%C3%A3o+%C3%BAnica+%3E+Django+%C2%B7+GLPI+%C2%B7+Zabbix;Build+fora+da+VM+%3E+CI%2FCD+%3E+Registry+%3E+Deploy;Zero+senha+em+texto+plano+%3E+secrets+versionados+fora+do+git;Zero+autorregistro+publico+%3E+contas+so+via+admin" alt="Typing SVG"/>

</div>

---

## Uma identidade só, para toda a instituição

A maioria das instituições públicas brasileiras opera identidade de forma
fragmentada: cada sistema (intranet, GLPI, Zabbix, e-mail) com seu
próprio usuário e senha, credenciais de infraestrutura circulando em
planilha ou papel, e zero trilha de auditoria de quem acessou o quê. A
alternativa de mercado — IAM comercial (Okta, Entra ID Premium,
PingFederate) — custa licença por usuário e mantém os dados da
instituição fora da própria infraestrutura.

Esta stack resolve os dois problemas com **software livre, auditável e
rodando inteiramente dentro da rede da instituição**: o [Keycloak](https://www.keycloak.org/)
federa **todos** os sistemas a uma única identidade vinda do **Active
Directory** (LDAPS), e o **Vaultwarden** — compatível com o protocolo
Bitwarden — dá à equipe de TI um cofre de credenciais de infraestrutura
que **autentica com essa mesma identidade**, via OpenID Connect. Uma
conta, dois sistemas críticos, zero senha duplicada, zero custo de
licença, zero dado saindo do datacenter da instituição.

```bash
git clone https://github.com/yurythx/Keycloak-0.1.git /opt/keycloak-stack
cd /opt/keycloak-stack
./setup.sh      # provisiona .env, segredos e certificados
./deploy.sh     # sobe a stack, aguarda ficar healthy, mostra o painel
```

## Arquitetura

```
                      Internet / rede da instituição
                                │
                      ┌──────────────────────┐
                      │  Servidor web da      │  ← já existe na instituição,
                      │  instituição (fora    │     FORA desta stack: TLS,
                      │  desta stack)         │     redirect HTTP→HTTPS e
                      │  TLS + proxy reverso  │     balanceamento de carga
                      │  + balanceamento      │
                      └──────────┬───────────┘
                    ┌────────────┴────────────┐
                    │ HTTP puro, host:porta    │
                    │ restrito por firewall    │
                    │ ao IP desse proxy        │
         ┌──────────┴──────────┐    ┌──────────┴──────────┐
         │      Keycloak       │    │     Vaultwarden      │
         │──── LDAPS ──→ AD    │◄───┤  (login via OIDC,    │
         │  (porta 8080,       │SSO │   PKCE, contra o     │
         │   publicada no host)│    │   Keycloak ao lado)  │
         └──────────┬──────────┘    └──────────┬──────────┘
                    │ rede interna (internal: true, sem rota de saída)
         ┌──────────┴──────────┐    ┌──────────┴──────────┐
         │  Postgres (Keycloak) │    │ Postgres (Vaultwarden)│
         │  nunca exposto       │    │  nunca exposto        │
         └─────────────────────┘    └───────────────────────┘

  Portainer (opcional) — bind 127.0.0.1:9443, só via SSH tunnel/VPN
```

## Dois pilares técnicos, uma única fonte de verdade

| | **Keycloak — identidade** | **Vaultwarden — segredos** |
|---|---|---|
| Papel | Provedor OIDC/SAML, federado ao AD via LDAPS | Cofre de credenciais compatível com clientes Bitwarden |
| Consome do AD | Usuários, grupos, senha | — |
| Autentica via | Realm próprio (`prefeitura`), Django/GLPI/Zabbix como clients | O **próprio Keycloak**, como client OIDC confidencial (`vaultwarden`), com PKCE |
| Cadastro de conta | Sincronizado do AD | **Fechado por padrão** — só admin ou convite, nunca autorregistro público |
| Banco | Postgres dedicado, rede `internal: true` | Postgres dedicado **próprio**, rede `internal: true` separada |
| Dado crítico | Sessões, tokens JWT | `rsa_key.pem` da instância — sem ela, dados cifrados ficam irrecuperáveis mesmo com o banco intacto |

A integração entre os dois **não é cosmética**: o `docker compose exec`
que cria o client OIDC do Vaultwarden no Keycloak, o `redirect_uri`
exato, o PKCE, e o fluxo de autorização completo (redirect → login →
código de autorização) foram testados ponta a ponta contra a stack real
antes de entrar na documentação — não é um diagrama aspiracional.

## Segurança em camadas — nada fica exposto por acidente

<div align="center">

| Camada | O que protege | Como |
|---|---|---|
| 🕸️ **Rede** | Bancos de dados | `internal: true` — Postgres do Keycloak e do Vaultwarden sem rota de saída, nem o host alcança |
| 🔑 **Segredos** | Senhas e tokens | Docker secrets com permissão restrita, **zero** texto plano em `.env` versionado |
| 🚪 **Borda** | Portas publicadas | Só o necessário exposto ao proxy da instituição, restrito por firewall ao IP dele |
| 🙅 **Cadastro** | Contas no cofre | Autorregistro **desligado**; contas só via admin ou convite, sem depender de SMTP |
| 🪪 **Identidade** | Login | SSO único via Keycloak (federado ao AD) — sem senha duplicada entre sistemas |
| 🩹 **Supply chain** | Imagem publicada | Build fora da VM, scan de vulnerabilidades (Trivy) antes do push pro registry |
| 🧯 **Continuidade** | Dados do cofre | Backup diário automatizado (banco **e** chave RSA/anexos) + drill de restauração testável |

</div>

## Achados reais, não suposições

Nada nesta documentação descreve um comportamento "esperado" sem ter
sido observado rodando de verdade. Uma amostra do que já foi encontrado
— e corrigido — testando esta stack contra si mesma, do zero, várias
vezes:

- **`DOMAIN` vazio derruba o Vaultwarden** — não degrada, **recusa
  iniciar** e entra em crash-loop. Virou variável obrigatória, com
  `deploy.sh` barrando o deploy antes do container sequer tentar subir.
- **O mesmo vale pra `SSO_ENABLED=true` sem client configurado** — erro
  claro no preflight em vez de crash-loop em produção.
- **Autorregistro aberto por padrão no Vaultwarden** — achado numa
  revisão de segurança formal (multi-agente, com filtragem de falsos
  positivos); sem a correção, qualquer pessoa alcançando a URL pública
  criava conta própria no cofre da instituição.
- **Backup cobria só o banco do Keycloak** — o banco do Vaultwarden e o
  volume com a chave RSA da instância não entravam no backup. Corrigido
  e testado: os dois bancos e o volume, com drill de restauração real.
- **Criação de conta com senha pré-definida** — implementada replicando
  a criptografia client-side do próprio Bitwarden (PBKDF2 + HKDF +
  AES-CBC/HMAC + RSA) a partir do código-fonte oficial, e validada
  logando de verdade com a conta criada — não assumida como "deveria
  funcionar".
- **502 do proxy externo** — script de diagnóstico (`scripts/diagnose_502.sh`)
  que separa "problema nesta stack" de "problema na borda" automaticamente,
  nascido de um incidente real de produção.

Cada um desses achados tem uma nota correspondente em
[`docs/`](docs/README.md), no ponto exato onde importa — não um
changelog solto.

## Build fora da VM, deploy sem surpresa

GitHub Actions **e** GitLab CI, lado a lado — lint, build, scan de
vulnerabilidades (Trivy) e push pra um registry de containers. A VM de
produção **nunca builda nada**: só `docker compose pull` + `up -d`. Isso
significa que o que sobe em produção é bit-a-bit o que passou no CI, não
um build local que "funcionou aqui".

| | |
|---|---|
| 🟢 **Console de operação** | `./manage.sh`, estilo TrueNAS: logs, reiniciar, backup, restore-drill, uso de recursos ao vivo (`docker stats`), shell no contêiner. |
| 🟢 **Identidade visual** | Tema customizado do Keycloak (`keycloak.v2`/PatternFly 5) com logo e cores da instituição — ver [`docs/tema-visual.md`](docs/tema-visual.md). |
| 🟢 **TLS via infraestrutura existente** | O Keycloak e o Vaultwarden publicam só HTTP puro em portas não padrão do host — TLS, redirecionamento e balanceamento ficam com o servidor web/proxy reverso que a instituição já opera, sem duplicar essa camada dentro da stack. |
| 🟢 **Imagem travável** | `KEYCLOAK_IMAGE_TAG` pode ser fixado num `sha-xxxxxxx` específico em produção — reprodutibilidade em vez de `latest` flutuante. |

## Documentação completa

Todo o passo a passo operacional — pré-requisitos, provisionamento,
federação com o AD, integração dos sistemas, go-live, cofre de senhas —
está em [**`docs/README.md`**](docs/README.md), organizado em etapas com
portões de validação (Go/No-Go) entre cada uma. Nenhuma etapa avança sem
que a anterior prove que funciona de verdade.

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
<img src="https://capsule-render.vercel.app/api?type=waving&color=0:FF4500,50:1F0D0D,100:000000&height=100&section=footer" width="100%"/>

🔐 *"Zero senha em texto plano. Zero autorregistro público. Zero surpresa."*

</div>
