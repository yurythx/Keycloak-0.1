FROM quay.io/keycloak/keycloak:26.7.0 AS builder

# Habilita suporte a metricas e healthchecks nativos
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
ENV KC_DB=postgres

WORKDIR /opt/keycloak
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.7.0
COPY --from=builder /opt/keycloak/ /opt/keycloak/

# Wrapper que resolve KC_DB_PASSWORD_FILE / KC_BOOTSTRAP_ADMIN_PASSWORD_FILE
# (nao suportados nativamente pela imagem oficial - ver docs/01-provisionamento.md)
COPY --chmod=0755 docker-entrypoint-secrets.sh /opt/keycloak/bin/docker-entrypoint-secrets.sh

ENTRYPOINT ["/opt/keycloak/bin/docker-entrypoint-secrets.sh"]
CMD ["start", "--optimized"]
