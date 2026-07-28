# Verificação End-to-End

[← Etapa 5](05-golive-operacao.md) · [Índice](README.md)

Checklist final antes do go-live real em produção — roda tudo de ponta a
ponta uma última vez, de preferência em ambiente de homologação primeiro.

- [ ] `docker compose config` — valida a sintaxe do compose.
- [ ] `./deploy.sh` em ambiente de homologação — todos os healthchecks
      `healthy` (ver [Etapa 1](01-provisionamento.md#portão-de-validação)).
- [ ] Bateria de curl da [Etapa 2](02-configuracao-keycloak.md) (emissão
      de JWT), decodificação em [jwt.io](https://jwt.io).
- [ ] Testar LDAPS ([Etapa 3](03-federacao-ad.md)) contra um DC de
      homologação, se disponível, antes do DC de produção.
- [ ] Simular login único Django → GLPI → Zabbix (SAML) e logout único
      ([Etapa 4](04-integracao-sistemas.md)).
- [ ] Rodar `scripts/backup.sh` manualmente e depois
      `scripts/restore_test.sh` para validar o ciclo completo de
      backup/restore antes do go-live real ([Etapa 5](05-golive-operacao.md)).
- [ ] Confirmar a política de segurança do CI/CD ([CI/CD e Registry](ci-cd.md))
      — pacote no registry com a visibilidade certa, `KEYCLOAK_IMAGE_TAG`
      travado numa versão específica se for esse o critério da prefeitura.
- [ ] Procedimento de rollback testado pelo menos uma vez
      ([Etapa 0](00-pre-requisitos.md)).
- [ ] Proxy reverso da prefeitura confirmado: `PROXY_TRUSTED_ADDRESSES`
      no `.env` é o IP real (não o de exemplo), firewall da VM restringe
      `KEYCLOAK_PORT` a esse IP, e um login completo via
      `https://<KC_HOSTNAME>` (de fora da VM) não gera nenhum link
      `http://` no fluxo OIDC ([Referência de Scripts](scripts-referencia.md#proxy-reverso-externo)).

Se todos os itens acima passarem, a stack está pronta para o go-live.
