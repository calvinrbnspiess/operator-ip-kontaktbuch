# ── ldap-usergroup-sync - demo environment ───────────────────
#
# Spins up PostgreSQL, OpenLDAP, and the sync tool.  Everything is seeded
# automatically so the sync can run immediately after startup.
#
# Quick start:
#   docker compose up -d
#   docker compose run --rm ldap-sync ./seed.sh
#   docker compose run --rm ldap-sync ./sync.py --dry-run
#   docker compose run --rm ldap-sync ./sync.py
#   docker compose run --rm ldap-sync ./test.sh
#
# Stop and remove containers:
#   docker compose down -v