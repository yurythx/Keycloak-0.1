# Logo da Prefeitura

Coloque o arquivo da logo **exatamente neste diretório**, com o nome:

```
logo.png
```

(`themes/prefeitura/login/resources/img/logo.png`)

## Recomendações

- **Formato**: PNG com fundo transparente (o cabeçalho do login tem cor
  sólida por trás — uma logo com fundo branco/opaco vai aparecer com uma
  caixa ao redor).
- **Proporção**: a área reservada é controlada por duas variáveis em
  `../css/styles.css` (`--keycloak-logo-height` e `--keycloak-logo-width`,
  hoje `60px` × `220px`). Ajuste esses dois valores para a proporção real
  do seu arquivo — `background-size: contain` já garante que a imagem
  nunca é cortada nem distorcida, mas se a caixa estiver com uma proporção
  muito diferente da logo, vai sobrar espaço vazio dos lados ou em cima/
  embaixo.
- **Resolução**: gere em pelo menos 2x o tamanho final (ex.: 440×120px
  para uma área de 220×60px) para ficar nítido em telas de alta
  densidade (Retina/4K).
- **Peso do arquivo**: mantenha abaixo de ~100 KB — é carregado a cada
  visita à tela de login, sem cache agressivo por padrão.

## Este arquivo é só um placeholder

Este `README.md` existe apenas para o Git versionar a estrutura de pastas
(diretório vazio não é versionado). Depois de colocar o `logo.png` de
verdade aqui, você pode manter ou remover este arquivo — não afeta o
funcionamento do tema.
