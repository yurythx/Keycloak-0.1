# Tema Visual (logo e cores da Prefeitura)

[← Índice](README.md)

Customiza a tela de login do Keycloak com a identidade visual oficial da
prefeitura — logo no cabeçalho e cores institucionais no botão de entrar
e nos links. Aplica-se via um tema customizado do Keycloak, versionado
neste repositório em `themes/prefeitura/`.

## Antes de tudo: qual tema o Keycloak 26 realmente usa

Guias antigos de tema do Keycloak (pré-22) ensinam a herdar do tema
`keycloak` (Bootstrap, classes como `.btn-primary`). **Isso não se aplica
mais.** Desde o Keycloak 22, o tema padrão é o **`keycloak.v2`**,
construído em cima do **PatternFly 5** — outra estrutura de HTML/CSS
inteira. Confirmamos isso direto no Keycloak 26.7.0 rodando neste projeto
antes de escrever qualquer CSS (não por suposição): extraímos o
`theme.properties` e o `styles.css` reais do tema `keycloak.v2` de dentro
do jar de temas do próprio Keycloak, e buscamos o formulário de login
renderizado de verdade para confirmar os seletores. Um tema escrito para
`.btn-primary` simplesmente **não teria efeito nenhum** nesta versão.

## Estrutura de arquivos

```
themes/
└── prefeitura/
    └── login/
        ├── theme.properties
        └── resources/
            ├── css/
            │   └── styles.css
            └── img/
                ├── README.md   (instruções)
                └── logo.png    (você adiciona)
```

### `theme.properties`

```properties
parent=keycloak.v2
styles=css/styles.css
```

`parent=keycloak.v2` herda **todos** os templates, scripts e traduções do
tema padrão — só precisamos declarar o que queremos *adicionar* por cima.
`styles=` é cumulativo: o CSS do `keycloak.v2` continua carregando
primeiro, o nosso `styles.css` entra **depois**, então conseguimos
sobrescrever pontualmente em vez de reescrever a tela inteira.

### `resources/css/styles.css`

A abordagem usada é sobrescrever as **custom properties (variáveis CSS)**
que o próprio `keycloak.v2`/PatternFly 5 já expõe para customização —
confirmadas direto no CSS-fonte do Keycloak, não chutadas:

| Variável | Para que serve | Confirmada em |
|---|---|---|
| `--keycloak-logo-url` | Imagem da logo (usada em `#kc-header-wrapper` — ver achado abaixo) | `keycloak.v2/login/resources/css/styles.css` |
| `--keycloak-logo-height` / `--keycloak-logo-width` | Dimensões da área da logo | idem |
| `--pf-v5-c-button--m-primary--BackgroundColor` / `--Color` | Cor de fundo/texto do botão primário ("Entrar") | `patternfly.min.css` |
| `--pf-v5-c-button--m-primary--hover--*` / `--focus--*` | Estados de hover/foco do botão | idem |

Por que variáveis CSS em vez de `background-color` direto ou
`!important`: é o **contrato público** de customização que o próprio
PatternFly/Keycloak.v2 disponibiliza — mais robusto a mudanças internas
de classe entre versões do Keycloak, e não entra em guerra de
especificidade CSS.

**Antes de usar em produção**: troque os valores placeholder no topo do
`styles.css` (`--prefeitura-primary`, `--prefeitura-primary-hover`,
`--prefeitura-on-primary`) pelas cores oficiais da identidade visual da
prefeitura (hex ou RGB) — no caso desta prefeitura, extraídas direto do
CSS de produção do site oficial (`rondonopolis.mt.gov.br`, variáveis
`--c-blue`/`--c-dark-blue`), não inventadas.

### ⚠️ Achado real: o seletor certo é `#kc-header-wrapper`, não `div.kc-logo-text`

A primeira versão deste tema usava `div.kc-logo-text` pra estilizar a
logo — essa classe **existe no `styles.css` do `keycloak.v2`**, mas
**não é usada por nenhum template `.ftl` renderizado no Keycloak
26.7.0**. É vestígio morto de uma versão anterior do tema. Resultado
prático: o CSS "funcionava" (sem erro, sem warning), só que **nada
aparecia na tela**, porque o elemento que a regra mirava simplesmente
não existe no HTML real.

**Como foi descoberto**: extraindo `template.ftl` de dentro do jar de
temas do próprio Keycloak (`keycloak-themes-26.7.0.jar`,
`theme/keycloak.v2/login/template.ftl`) em vez de confiar só no
`styles.css`:
```bash
docker exec keycloak_server sh -c 'find /opt/keycloak -iname "*theme*.jar"'
# copia o jar pro host e extrai com python3 -m zipfile (o container nao tem unzip/jar)
```
O cabeçalho real é:
```html
<header id="kc-header" class="pf-v5-c-login__header">
  <div id="kc-header-wrapper" class="pf-v5-c-brand">${...realm.displayNameHtml...}</div>
</header>
```
Ou seja: o elemento certo é **`#kc-header-wrapper`** (classe
`.pf-v5-c-brand`), que por padrão só mostra o **nome do realm como texto
grande** — não tem `<img>` nem `background-image` nenhum até você
adicionar.

**Correção aplicada**: `background-image` (a logo) + `background-color`
(cor institucional, em formato de badge arredondado) direto em
`#kc-header-wrapper`, escondendo o texto do nome do realm de forma
**acessível** (`font-size: 0` / `color: transparent`, não `display:none`
— continua legível por leitor de tela).

> **Lição pra qualquer tema futuro**: não confie só no `styles.css` de
> um tema-base pra saber quais seletores "existem de verdade" — variáveis
> e classes podem estar definidas no CSS sem nenhum elemento no HTML
> renderizado as usando (versões antigas do tema deixam rastro). Extraia
> e confira o `.ftl`/HTML real antes de escrever CSS em cima de um
> seletor, ou teste visualmente cedo (ver seção de validação).

### `resources/img/logo.png`

Ver instruções detalhadas (formato, proporção, resolução recomendada) em
[`themes/prefeitura/login/resources/img/README.md`](../themes/prefeitura/login/resources/img/README.md).
Resumo: PNG com fundo transparente, gerado em pelo menos 2x o tamanho
final, abaixo de ~100 KB. Ajuste `--keycloak-logo-height`/`-width` no
`styles.css` para a proporção real do arquivo.

> **Achado real sobre a logo oficial desta prefeitura**: o arquivo
> fornecido é um PNG com fundo **transparente de verdade**, mas o
> desenho (brasão + texto) é **branco sólido** — feito pra fundo escuro.
> Como o card de login do `keycloak.v2` é branco, a logo ficaria
> invisível (branco sobre branco) sem tratamento. Por isso
> `#kc-header-wrapper` recebe um `background-color` com a cor
> institucional — vira um "badge" colorido com a logo branca por cima,
> padrão comum em portais de governo. Confira antes de reusar esse CSS
> com outra logo se a sua já tem cor/contraste próprio — nesse caso o
> `background-color` do badge pode não ser necessário.

> **Enquanto `logo.png` não existe**: testado ao vivo — o tema funciona
> normalmente (cores, botão, links já aparecem), só a área do cabeçalho
> fica **em branco** onde a logo entraria. Como é `background-image` via
> variável CSS (não uma tag `<img>`), o 404 do arquivo não gera ícone de
> "imagem quebrada" nem erro visível — só não desenha nada ali.

## Montagem no `docker-compose.yml`

Já está no `docker-compose.yml` deste repositório (serviço `keycloak`):

```yaml
volumes:
  - ./certs:/opt/keycloak/certs:ro
  - ./themes:/opt/keycloak/themes:ro
```

Montado como **somente leitura** (`:ro`) — o Keycloak só lê temas, nunca
escreve neles. Confirmamos que `/opt/keycloak/themes` só contém um
`README.md` por padrão na imagem oficial (os temas nativos, incluindo o
`keycloak.v2`, ficam empacotados dentro de jars, não soltos nessa pasta)
— então montar aqui **não esconde nem substitui** nenhum tema nativo.

## Ativar o tema no realm

O Keycloak já reconhece o tema assim que o container sobe com o volume
montado (confirmado via `GET /admin/serverinfo` — `prefeitura` aparece na
lista de temas de login disponíveis). Falta só selecionar ele no realm:

**Via Admin Console** (recomendado): Realm Settings → Themes →
**Login Theme** → `prefeitura` → Save.

**Via linha de comando** (`kcadm.sh` dentro do container), se preferir
automatizar:
```bash
docker exec keycloak_server sh -c '
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 \
    --realm master --user kc_admin --password "$(cat /run/secrets/kc_admin_password)"
  /opt/keycloak/bin/kcadm.sh update realms/Prefeitura -s loginTheme=prefeitura
'
```

> Aplique no realm **`Prefeitura`** (maiúsculo — o realm real de
> produção, ver [docs/integracoes/active-directory.md §1](integracoes/active-directory.md#1-o-que-a-federação-real-é-diferente-do-plano)
> sobre por que não é `prefeitura` minúsculo), nunca no `master` —
> o `master` fica isolado, uso exclusivo administrativo (ver
> [Etapa 2](02-configuracao-keycloak.md)).

## Como validar que funcionou

1. Depois de montar o volume, redeploy: `./deploy.sh` (ou
   `docker compose up -d --force-recreate keycloak` se só o tema mudou).
2. Confira que o Keycloak reconheceu o tema:
   ```bash
   docker exec keycloak_server sh -c '/opt/keycloak/bin/kcadm.sh get serverinfo --config /tmp/kcadm.config' | grep -A2 prefeitura
   ```
   (requer login prévio do `kcadm.sh` — ver `scripts/configure_ldap.sh`
   para o padrão completo de autenticação via `kcadm`.)
3. Acesse a tela de login do realm `Prefeitura` — a logo e as cores devem
   aparecer. Force um refresh sem cache (`Ctrl+Shift+R`) se ainda ver o
   visual antigo.

> ⚠️ **Achado real: o proxy reverso externo (192.168.0.218) cacheia os
> arquivos CSS do tema por até 30 dias** (`cache-control: max-age=2592000`
> confirmado no CSS servido via `sso.rondonopolis.mt.gov.br`). Testar
> pelo domínio público **não é confiável** logo depois de editar o tema
> — o `Ctrl+Shift+R` só limpa o cache do seu navegador, não o do proxy no
> meio do caminho. Pra validar de verdade sem esperar (ou sem depender
> de alguém purgar o cache lá), bata **direto no Keycloak, sem passar
> pelo proxy**:
> ```bash
> # tunel SSH local ate a porta do Keycloak na VM (127.0.0.1:18443 la' == aqui)
> ssh -L 18443:127.0.0.1:18443 -N pmrkeycloak &
> curl -s --compressed http://127.0.0.1:18443/resources/<hash>/login/prefeitura/css/styles.css \
>     | grep 'prefeitura-primary\|kc-header-wrapper'
> ```
> Isso já mostra o CSS real e atualizado, mesmo que o proxy externo ainda
> esteja servindo uma versão antiga pra usuários de verdade — o mesmo
> tipo de bug de cache que já tínhamos achado antes no CSS do Vaultwarden
> (ver [docs/integracoes/vaultwarden.md](integracoes/vaultwarden.md)). **Esse cache do proxy
> ainda não foi resolvido/purgado** — enquanto isso, usuários acessando
> pelo domínio público podem continuar vendo o tema antigo por até 30
> dias após qualquer alteração.

4. Inspecione o HTML da página (`Ver código-fonte`) e confirme que o CSS
   carregado é `.../login/prefeitura/css/styles.css`, não
   `.../login/keycloak.v2/css/styles.css`.

## Atualizando o tema depois

Como é um bind mount (não fica dentro da imagem), qualquer alteração em
`themes/prefeitura/` exige recriar o container do Keycloak pra valer —
`restart` não é suficiente pra pegar arquivos novos adicionados depois do
container já ter subido pela primeira vez:
```bash
docker compose up -d --force-recreate keycloak
```

> **Nota sobre imutabilidade**: por ser um volume montado da VM (não
> parte da imagem publicada pelo CI), o tema pode ser editado direto em
> produção sem passar pelo pipeline — conveniente para iteração rápida de
> logo/cores, mas foge do princípio de "tudo vem da imagem versionada"
> que o resto do projeto segue (ver [CI/CD e Registry](ci-cd.md)). Se
> quiser reproducibilidade total, é possível copiar `themes/` para dentro
> da imagem via `COPY` no `Dockerfile` em vez de montar como volume — nesse
> caso qualquer troca de logo/cor passa a exigir um novo build/push pela
> pipeline, igual ao resto da stack.
