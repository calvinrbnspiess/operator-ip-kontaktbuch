FROM debian:bookworm-slim

# Install all required runtime tools in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      python3 \
      python3-yaml \
      ldap-utils \
      postgresql-client \
      cron \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ldap-usergroup-sync

# Copy scripts and config
COPY sync.sh   ./sync.sh
COPY seed.sh   ./seed.sh
COPY config.yaml ./config.yaml

RUN chmod +x sync.sh seed.sh \
    && mkdir -p logs

# ── Cron entry ──────────────────────────────────────────────────────────────
# Runs every night at 02:00.  Adjust the schedule as needed.
# Logs go to /opt/ldap-usergroup-sync/logs/  (mount as a volume to persist them).
RUN echo "0 2 * * * root /opt/ldap-usergroup-sync/sync.sh \
      --config /opt/ldap-usergroup-sync/config.yaml \
      >> /opt/ldap-usergroup-sync/logs/cron.log 2>&1" \
      > /etc/cron.d/ldap-usergroup-sync \
    && chmod 0644 /etc/cron.d/ldap-usergroup-sync \
    && crontab /etc/cron.d/ldap-usergroup-sync

# Default: start cron in the foreground so Docker keeps the container alive.
# Override CMD to run sync.sh directly for a one-shot execution.
CMD ["cron", "-f"]
