# ldap-usergroup-sync

Alle Befehle aus dem **Repo-Root** ausfuhren:

```bash
# Testdaten einspielen
docker compose -f docker-compose.yaml -f ldap-sync/ldap-usergroup-sync/docker-compose.yaml run --rm ldap-sync bash seed.sh

# Tests ausfuhren
docker compose -f docker-compose.yaml -f ldap-sync/ldap-usergroup-sync/docker-compose.yaml run --rm ldap-sync bash test.sh

# Sync (Dry-Run)
docker compose -f docker-compose.yaml -f ldap-sync/ldap-usergroup-sync/docker-compose.yaml run --rm ldap-sync ./sync.py --dry-run

# Sync (produktiv)
docker compose -f docker-compose.yaml -f ldap-sync/ldap-usergroup-sync/docker-compose.yaml run --rm ldap-sync ./sync.py

# Daemon starten (Cron, Sync jede Nacht 02:00)
docker compose -f docker-compose.yaml -f ldap-sync/ldap-usergroup-sync/docker-compose.yaml up -d ldap-sync
```
