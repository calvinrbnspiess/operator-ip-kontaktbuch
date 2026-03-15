#!/usr/bin/env bash
# Version 1 — 15-03-2026
# ═══════════════════════════════════════════════════════════════════════════
# seed.sh — Populate PostgreSQL and LDAP with test data
#
# Creates synthetic persons, department memberships, and function assignments
# so that sync.sh has something concrete to work with.
#
# Safe to run multiple times (uses INSERT ... ON CONFLICT DO NOTHING and
# ldap_entry_exists guards).
#
# Usage:
#   ./seed.sh [--config <path>]
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|-c) CONFIG_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Load config ────────────────────────────────────────────────────────────
eval "$(python3 - "${CONFIG_FILE}" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as fh:
    c = yaml.safe_load(fh)

def esc(v):
    return "'" + str(v).replace("'", "'\\''") + "'"

l = c['ldap']
d = c['database']

for name, val in [
    ("LDAP_HOST",      l['host']),
    ("LDAP_PORT",      l['port']),
    ("LDAP_BIND_DN",   l['bind_dn']),
    ("LDAP_BIND_PW",   l['bind_password']),
    ("LDAP_BASE_DN",   l['base_dn']),
    ("LDAP_USERS_OU",  l['users_ou']),
    ("LDAP_GROUPS_OU", l['groups_ou']),
    ("DB_HOST",        d['host']),
    ("DB_PORT",        d['port']),
    ("DB_NAME",        d['name']),
    ("DB_USER",        d['user']),
    ("DB_PASS",        d['password']),
]:
    print(f"{name}={esc(val)}")
PYEOF
)"

# ─── Helpers ────────────────────────────────────────────────────────────────
db() {
  PGPASSWORD="${DB_PASS}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" \
    -U "${DB_USER}" -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -c "$1"
}

ldap_entry_exists() {
  local dn="$1"
  local base="${dn#*,}"
  local rdn="${dn%%,*}"
  local attr="${rdn%%=*}"
  local val="${rdn#*=}"
  local hits
  hits=$(ldapsearch -x -LLL \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
    -b "${base}" "(${attr}=${val})" dn 2>/dev/null \
    | grep -c "^dn:" || true)
  [[ "${hits}" -gt 0 ]]
}

ldap_add() {
  echo "$1" | ldapadd -x \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" 2>&1 || true
}

echo "════════════════════════════════════════════════"
echo "ldap-usergroup-sync — seeding test data"
echo "════════════════════════════════════════════════"

# ───────────────────────────────────────────────────────────────────────────
# 1. PostgreSQL — insert test persons
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── PostgreSQL: inserting test persons ──"

db "
-- Ensure 'Testperson' person type exists (id=5 from real data)
INSERT INTO public.persontypes (id, name, short)
VALUES (5, 'Testperson', 'TEST')
ON CONFLICT (id) DO NOTHING;
"

# Test persons  (personNumber must be unique, 4 digits)
# persontypeId=5 (Testperson) so they are clearly synthetic
db "
INSERT INTO public.people
  (id, \"persontypeId\", sex, \"lastName\", \"firstName\",
   \"personNumber\", active, \"exportFlag\")
VALUES
  (9001, 5, 1, 'Mustermann', 'Max',    1001, true, false),
  (9002, 5, 2, 'Musterfrau', 'Maria',  1002, true, false),
  (9003, 5, 1, 'Testmann',   'Thomas', 1003, true, false),
  (9004, 5, 1, 'Prüfer',     'Peter',  1004, true, false),
  (9005, 5, 2, 'Überin',     'Ursula', 1005, true, false)
ON CONFLICT (id) DO NOTHING;
"
echo "  → 5 test persons inserted (ids 9001–9005, personNumbers 1001–1005)"

# ───────────────────────────────────────────────────────────────────────────
# 2. PostgreSQL — department memberships
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── PostgreSQL: assigning department memberships ──"

db "
-- Max + Maria → Landau-Stadt  (open-ended)
INSERT INTO public.persondepartments
  (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
VALUES
  (9001, 10, '2020-01-01', NULL),
  (9002, 10, '2021-06-01', NULL)
ON CONFLICT DO NOTHING;

-- Thomas → Landau-Dammheim (active)
INSERT INTO public.persondepartments
  (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
VALUES
  (9003, 4, '2019-03-15', NULL)
ON CONFLICT DO NOTHING;

-- Peter → Gefahrstoffzug (active)
INSERT INTO public.persondepartments
  (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
VALUES
  (9004, 18, '2022-09-01', NULL)
ON CONFLICT DO NOTHING;

-- Ursula → Landau-Stadt (membership EXPIRED — should NOT be synced)
INSERT INTO public.persondepartments
  (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
VALUES
  (9005, 10, '2018-01-01', '2020-12-31')
ON CONFLICT DO NOTHING;
"
echo "  → Department memberships inserted (Ursula's Landau-Stadt membership is expired)"

# ───────────────────────────────────────────────────────────────────────────
# 3. PostgreSQL — function assignments
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── PostgreSQL: assigning functions ──"

db "
-- Max → Atemschutzgeräteträger/in  (id=3, active)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9001, 3, '2021-01-01', NULL)
ON CONFLICT DO NOTHING;

-- Maria → Atemschutzgeräteträger/in + Korbfahrer  (both active)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9002, 3, '2020-05-01', NULL),
  (9002, 40, '2023-07-01', NULL)
ON CONFLICT DO NOTHING;

-- Thomas → IT FachGuru  (id=1, active)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9003, 1, '2022-11-01', NULL)
ON CONFLICT DO NOTHING;

-- Peter → Atemschutzgeräteträger/in (validity EXPIRED — should NOT sync)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9004, 3, '2015-01-01', '2019-12-31')
ON CONFLICT DO NOTHING;
"
echo "  → Function assignments inserted (Peter's Atemschutz cert is expired)"

# ───────────────────────────────────────────────────────────────────────────
# 4. LDAP — pre-create test users with existing group memberships
#    (to give sync.sh something to update and remove)
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── LDAP: pre-creating test users ──"

# Ensure ou=people exists
if ! ldap_entry_exists "ou=people,${LDAP_BASE_DN}"; then
  ldap_add "dn: ou=people,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: people"
  echo "  → Created ou=people"
fi

# Ensure ou=groups exists
if ! ldap_entry_exists "ou=groups,${LDAP_BASE_DN}"; then
  ldap_add "dn: ou=groups,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: groups"
  echo "  → Created ou=groups"
fi

# Helper: create an LDAP user without POSIX attrs so sync.sh adds them
create_ldap_user() {
  local uid="$1" cn="$2" sn="$3" given="$4"
  local dn="uid=${uid},${LDAP_USERS_OU}"
  if ldap_entry_exists "${dn}"; then
    echo "  → User ${uid}: already exists"
  else
    ldap_add "dn: ${dn}
objectClass: inetOrgPerson
uid: ${uid}
cn: ${cn}
sn: ${sn}
givenName: ${given}
userPassword: SeedPassword1!"
    echo "  → User ${uid}: created (no POSIX attrs yet — sync.sh will add them)"
  fi
}

create_ldap_user "p-1001" "Max Mustermann"  "Mustermann" "Max"
create_ldap_user "p-1002" "Maria Musterfrau" "Musterfrau" "Maria"
# 1003, 1004, 1005 intentionally omitted — sync.sh will create them

# ───────────────────────────────────────────────────────────────────────────
# 5. LDAP — pre-populate groups with stale memberships
#    (sync.sh must clean these up)
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── LDAP: pre-creating groups with stale/wrong memberships ──"

# Pre-create 'atemschutz' with jdoe (not a DB person) — sync.sh should remove jdoe,
# add p-1001 and p-1002, and leave p-1004 out (expired cert).
GRP_DN="cn=atemschutz,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: atemschutz
description: Aktive Atemschutzgeräteträger
member: uid=jdoe,${LDAP_USERS_OU}"
  echo "  → Group 'atemschutz': created with stale member uid=jdoe"
else
  echo "  → Group 'atemschutz': already exists"
fi

# Pre-create 'landau-stadt' with asmith (not a DB person).
GRP_DN="cn=landau-stadt,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: landau-stadt
description: Angehörige der Abteilung Landau-Stadt
member: uid=asmith,${LDAP_USERS_OU}"
  echo "  → Group 'landau-stadt': created with stale member uid=asmith"
else
  echo "  → Group 'landau-stadt': already exists"
fi

echo ""
echo "════════════════════════════════════════════════"
echo "Seeding complete."
echo ""
echo "Summary of expected sync.sh behaviour:"
echo "  Users to CREATE in LDAP : p-1003, p-1004, p-1005"
echo "  Users to UPDATE (add POSIX): p-1001, p-1002"
echo ""
echo "  Group 'atemschutz'   : +p-1001, +p-1002  (remove jdoe)"
echo "  Group 'korbfahrer'   : +p-1002"
echo "  Group 'landau-stadt' : +p-1001, +p-1002  (remove asmith)"
echo "                         (p-1005 excluded: membership expired)"
echo "  Group 'landau-dammheim': +p-1003"
echo "  Group 'it-fachguru'  : +p-1003"
echo "  Group 'gefahrstoffzug': +p-1004"
echo "════════════════════════════════════════════════"
