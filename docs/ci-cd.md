# CI/CD e Registry

[← Índice](README.md)

**Build fora da VM**: a imagem do Keycloak não é construída na VM de
produção. O pipeline builda, valida e publica a imagem num registry; a VM
só faz `docker compose pull` (via `./deploy.sh`). Isso tira o processo de
build — e suas dependências (compiladores, cache, superfície de ataque) —
de cima do servidor que atende ao público.

Existem **dois pipelines equivalentes, um por plataforma** — cada uma só
processa o arquivo que reconhece, não há conflito em manter os dois no
mesmo repositório:

| | GitHub Actions | GitLab CI |
|---|---|---|
| Arquivo | `.github/workflows/ci.yml` | `.gitlab-ci.yml` |
| Registry | GitHub Container Registry (`ghcr.io`) | GitLab Container Registry (`$CI_REGISTRY_IMAGE`) |
| Credencial | `secrets.GITHUB_TOKEN` (automático) | `$CI_REGISTRY_USER`/`$CI_REGISTRY_PASSWORD` (automático) |
| Variável de imagem | `ghcr.io/<owner>/keycloak-sso` | `registry.<host>/<grupo>/<projeto>` |

## O que cada pipeline faz, em todo push/MR para a branch principal

1. **Lint** — `shellcheck` em todos os `.sh` do repositório (via glob,
   `*.sh scripts/*.sh scripts/lib/*.sh` — nenhum script novo fica de fora
   silenciosamente), `hadolint` no `Dockerfile`, `docker compose config`
   para validar o compose (roda sem precisar de um daemon Docker de
   verdade).
2. **Build** — builda a imagem (roda inclusive em Pull Request/Merge
   Request, para pegar erro de build antes do merge).
3. **Scan de vulnerabilidades** — [Trivy](https://aquasecurity.github.io/trivy/)
   escaneia a imagem buildada em dois passos:
   - **Relatório HIGH+CRITICAL** (informativo, não bloqueia) — fica nos
     logs do CI pra acompanhamento.
   - **Gate de segurança** (bloqueia o pipeline) — falha **só** se houver
     `CRITICAL` com correção disponível.
4. **Push** (só em push/pipeline real na branch principal, nunca em
   PR/MR) — publica com duas tags: `latest` e `sha-<7 chars do commit>`.
   Numa tag `vX.Y.Z`, publica também essa tag de versão.

### Por que o gate não bloqueia em HIGH também

A maior parte dos achados `HIGH` numa imagem do Keycloak está em
bibliotecas Java *de terceiros empacotadas pelo próprio vendor* (ex.:
`jackson-databind`, `netty`, drivers JDBC que nem usamos — o Keycloak
empacota driver de SQL Server mesmo rodando com Postgres). Exigir zero
`HIGH` nessas dependências transitivas travaria o deploy indefinidamente
a cada release do Keycloak, por algo fora do nosso controle direto.
`CRITICAL` é o piso não-negociável; `HIGH` fica **visível e monitorado**,
não bloqueante.

> Reavalie essa política periodicamente (ex.: a cada atualização de
> versão do Keycloak). Decisão tomada em 2026-07-23 após constatar que a
> versão `26.0` tinha `CRITICAL` real (CVE-2025-14813, BouncyCastle) e
> vários `HIGH` específicos do próprio Keycloak (autenticação/SAML)
> corrigidos ao subir para `26.7.0`.

## GitHub Actions — detalhes específicos

**Visibilidade do pacote no GHCR** — decisão a tomar antes do primeiro
deploy em produção via pull:
- **Pacote público** (mais simples): a imagem não contém nenhum segredo
  da prefeitura (senhas ficam em `secrets/*.txt`, nunca na imagem) —
  tornar o pacote público é seguro e elimina a necessidade de
  autenticação na VM. Configurável em GitHub → seu perfil/org → Packages
  → `keycloak-sso` → Package settings → Change visibility.
- **Pacote privado**: mais conservador por política interna. Nesse caso,
  a VM precisa de `docker login` uma vez:
  ```bash
  echo "<PAT com escopo read:packages>" | docker login ghcr.io -u <usuario> --password-stdin
  ```
  Gere o PAT em GitHub → Settings → Developer settings → Personal access
  tokens, com escopo mínimo `read:packages`.

**Permissões do `GITHUB_TOKEN`**: a pipeline usa o token automático do
GitHub Actions (nenhum secret manual necessário) para publicar no
ghcr.io. Se a organização/repositório tiver a permissão padrão do
workflow restrita a somente-leitura (Settings → Actions → General →
Workflow permissions), habilite "Read and write permissions" — sem isso
o passo de push falha com `403`.

## GitLab CI — detalhes específicos

**Runner privileged**: o job `build-scan-push` usa Docker-in-Docker
(`docker:27-dind`) para conseguir buildar imagens dentro do próprio CI. O
runner que executar esse job precisa estar configurado com
`privileged = true` (em `[runners.docker]` no `config.toml` do runner, ou
na config do runner no GitLab self-hosted). Sem isso o job falha tentando
conversar com o daemon Docker interno — é a causa mais comum de pipeline
quebrada aqui.

**Registry do projeto**: `$CI_REGISTRY_IMAGE`, `$CI_REGISTRY_USER` e
`$CI_REGISTRY_PASSWORD` são providos automaticamente pelo GitLab para
qualquer projeto com o Container Registry habilitado (Settings → General
→ Visibility → Container Registry) — nenhum secret manual necessário,
mesmo princípio do `GITHUB_TOKEN`.

## Reprodutibilidade em produção (vale para as duas plataformas)

Por padrão `KEYCLOAK_IMAGE_TAG=latest` (flutuante). Para risco mínimo de
uma atualização inesperada da imagem, trave em produção num
`sha-xxxxxxx` específico (o pipeline mostra a tag exata publicada no
resumo da execução — *Actions → run → Summary* no GitHub, no log do job
`build-scan-push` no GitLab):
```bash
# no .env da VM
KEYCLOAK_IMAGE=<registry usado>
KEYCLOAK_IMAGE_TAG=sha-1a2b3c4
```
