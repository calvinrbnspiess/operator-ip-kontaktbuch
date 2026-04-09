FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      python3 \
      python3-yaml \
      python3-ldap3 \
      python3-psycopg2 \
      python3-jinja2 \
      ldap-utils \
      postgresql-client \
      cron \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ldap-usergroup-sync

COPY sync.py             ./sync.py
COPY seed.sh             ./seed.sh
COPY test.sh             ./test.sh
COPY config.yaml         ./config.yaml
COPY group-mappings.yaml ./group-mappings.yaml

RUN chmod +x seed.sh test.sh sync.py \
    && mkdir -p logs

RUN echo "0 2 * * * root /opt/ldap-usergroup-sync/sync.py \
      --config /opt/ldap-usergroup-sync/config.yaml \
      >> /opt/ldap-usergroup-sync/logs/cron.log 2>&1" \
      > /etc/cron.d/ldap-usergroup-sync \
    && chmod 0644 /etc/cron.d/ldap-usergroup-sync \
    && crontab /etc/cron.d/ldap-usergroup-sync

CMD ["cron", "-f"]
