<div align="center">

# 🔐 Keycloak SSO + Vault

### Login único e cofre de senhas da instituição, rodando na própria infraestrutura

<a href="https://github.com/yurythx/Keycloak-0.1/actions/workflows/ci.yml">
  <img src="https://github.com/yurythx/Keycloak-0.1/actions/workflows/ci.yml/badge.svg" alt="CI"/>
</a>
<img src="https://img.shields.io/badge/Keycloak-26.7.0-FF4500?style=for-the-badge&logo=keycloak&logoColor=black&labelColor=000000" alt="Keycloak"/>
<img src="https://img.shields.io/badge/Vaultwarden-Cofre%20de%20Senhas-FF4500?style=for-the-badge&logo=bitwarden&logoColor=black&labelColor=000000" alt="Vaultwarden"/>
<img src="https://img.shields.io/badge/PostgreSQL-16-FF4500?style=for-the-badge&logo=postgresql&logoColor=black&labelColor=000000" alt="PostgreSQL"/>
<img src="https://img.shields.io/badge/Docker-Compose-FF4500?style=for-the-badge&logo=docker&logoColor=black&labelColor=000000" alt="Docker"/>

<img src="https://readme-typing-svg.demolab.com?font=Fira+Code&weight=600&size=18&duration=3000&pause=900&color=FF4500&center=true&vCenter=true&width=650&lines=Uma+conta+%3E+todos+os+sistemas;Zero+senha+em+texto+plano;Zero+autorregistro+publico;Zero+dado+fora+da+institui%C3%A7%C3%A3o" alt="Typing SVG"/>

</div>

---

## O que essa stack faz

Sobe, com dois comandos, uma central de identidade completa:

- 🔑 **Um login para tudo** — Keycloak federado ao Active Directory: a
  senha da rede vira a senha de todos os sistemas (intranet, GLPI,
  Zabbix), sem cadastro duplicado.
- 🗄️ **Um cofre de senhas institucional** — Vaultwarden (compatível com
  Bitwarden) para guardar credenciais de infraestrutura, com login
  **pela mesma identidade** do Keycloak.
- 🚫 **Ninguém cria conta sozinho** — autorregistro desligado por padrão,
  tanto no cofre quanto na federação. Toda conta nasce de uma fonte
  confiável (AD ou admin).
- 🔒 **Segredo nenhum no git** — senhas e tokens gerados automaticamente,
  guardados como Docker secrets, nunca em arquivo versionado.
- 📦 **Nada é construído na VM de produção** — CI builda, escaneia
  vulnerabilidades e publica a imagem; a VM só baixa e sobe.
- 🧰 **Opera sozinha no dia a dia** — console próprio (`manage.sh`),
  backup automático dos dois bancos, e scripts de diagnóstico para os
  problemas mais comuns (proxy externo, restauração de backup).

```bash
git clone https://github.com/yurythx/Keycloak-0.1.git /opt/keycloak-stack
cd /opt/keycloak-stack
./setup.sh      # provisiona .env, segredos e certificados
./deploy.sh     # sobe a stack, aguarda ficar healthy, mostra o painel
```

## Como as peças se encaixam

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

## Segurança em camadas

<div align="center">

| Camada | O que protege | Como |
|---|---|---|
| 🕸️ Rede | Bancos de dados | `internal: true` — sem rota de saída, nem o host alcança |
| 🔑 Segredos | Senhas e tokens | Docker secrets, zero texto plano em `.env` |
| 🚪 Borda | Portas publicadas | Só o necessário, restrito por firewall ao IP do proxy |
| 🙅 Cadastro | Contas no cofre | Autorregistro desligado; contas só via admin ou convite |
| 🪪 Identidade | Login | SSO único via Keycloak, federado ao AD |
| 🩹 Supply chain | Imagem publicada | Build fora da VM + scan de vulnerabilidades (Trivy) |
| 🧯 Continuidade | Dados do cofre | Backup diário (banco + chave RSA) + restauração testável |

</div>

## Testado de verdade, não só documentado

Cada item abaixo foi encontrado rodando a stack de verdade, não
imaginado na hora de escrever a documentação:

- `DOMAIN` vazio derruba o Vaultwarden (crash-loop) — virou variável
  obrigatória, com erro claro antes do deploy.
- `SSO_ENABLED=true` sem o client configurado tem o mesmo problema — mesmo
  tratamento.
- Autorregistro do cofre vinha **aberto por padrão** — achado numa
  revisão de segurança formal, corrigido.
- O backup cobria só o banco do Keycloak — agora cobre os dois bancos
  **e** o volume com a chave de criptografia do cofre.
- Criação de conta com senha pré-definida replica a criptografia real do
  Bitwarden — testada criando uma conta e logando de verdade com ela.

Detalhes de cada um, e mais, em [`docs/`](docs/README.md).

## Documentação completa

Passo a passo operacional completo em [**`docs/README.md`**](docs/README.md),
organizado em etapas com portão de validação entre cada uma — não avança
sem provar que funciona.

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

🔐 *Zero senha em texto plano. Zero autorregistro público. Zero surpresa.*

</div>
