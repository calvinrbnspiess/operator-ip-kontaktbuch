#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# seed.sh — Populate PostgreSQL and LDAP with demo data
#
# Creates synthetic persons, department memberships, function assignments,
# LDAP OUs, users, and groups so that sync.py has something to work with.
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
echo "ldap-usergroup-sync — seeding demo data"
echo "════════════════════════════════════════════════"

# ───────────────────────────────────────────────────────────────────────────
# 1. PostgreSQL — insert test persons
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── PostgreSQL: inserting test persons ──"

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
-- Max → Atemschutzgeräteträger/in (active)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9001, 3, '2021-01-01', NULL)
ON CONFLICT DO NOTHING;

-- Maria → Atemschutzgeräteträger/in + Korbfahrer (both active)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9002, 3, '2020-05-01', NULL),
  (9002, 40, '2023-07-01', NULL)
ON CONFLICT DO NOTHING;

-- Thomas → Wehrführer (active)
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
# 4. LDAP — create OUs, users, and groups with stale memberships
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── LDAP: creating OUs ──"

if ! ldap_entry_exists "${LDAP_USERS_OU}"; then
  ldap_add "dn: ${LDAP_USERS_OU}
objectClass: top
objectClass: organizationalUnit
ou: Personen"
  echo "  → Created ${LDAP_USERS_OU}"
else
  echo "  → ${LDAP_USERS_OU} already exists"
fi

if ! ldap_entry_exists "${LDAP_GROUPS_OU}"; then
  ldap_add "dn: ${LDAP_GROUPS_OU}
objectClass: top
objectClass: organizationalUnit
ou: groups"
  echo "  → Created ${LDAP_GROUPS_OU}"
else
  echo "  → ${LDAP_GROUPS_OU} already exists"
fi

echo ""
echo "── LDAP: creating test users ──"

create_ldap_user() {
  local uid="$1" display_name="$2" sn="$3" given="$4"
  local dn="cn=${uid},${LDAP_USERS_OU}"
  if ldap_entry_exists "${dn}"; then
    echo "  → User ${uid}: already exists"
  else
    ldap_add "dn: ${dn}
objectClass: inetOrgPerson
cn: ${uid}
sn: ${sn}
givenName: ${given}
displayName: ${display_name}
userPassword: DemoPassword1!"
    echo "  → User ${uid}: created"
  fi
}

create_ldap_user "P-1001" "Max Mustermann"   "Mustermann" "Max"
create_ldap_user "P-1002" "Maria Musterfrau" "Musterfrau" "Maria"
create_ldap_user "P-1003" "Thomas Testmann"  "Testmann"   "Thomas"
create_ldap_user "P-1004" "Peter Prüfer"     "Prüfer"     "Peter"
create_ldap_user "P-1005" "Ursula Überin"    "Überin"     "Ursula"

echo ""
echo "── LDAP: creating groups with stale/wrong memberships ──"

# atemschutz — P-1004 was a member but cert expired, P-1005 never qualified
# Desired: P-1001, P-1002.  So P-1004 and P-1005 get removed.
GRP_DN="cn=atemschutz,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: atemschutz
description: Aktive Atemschutzgeräteträger
member: cn=P-1004,${LDAP_USERS_OU}
member: cn=P-1005,${LDAP_USERS_OU}"
  echo "  → Group 'atemschutz': created with P-1004 (expired) + P-1005 (wrong)"
else
  echo "  → Group 'atemschutz': already exists"
fi

# korbfahrer — P-1003 wrongly assigned, should be replaced by P-1002
GRP_DN="cn=korbfahrer,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: korbfahrer
description: Korbfahrer
member: cn=P-1003,${LDAP_USERS_OU}"
  echo "  → Group 'korbfahrer': created with P-1003 (wrong member)"
else
  echo "  → Group 'korbfahrer': already exists"
fi

# landau-stadt — P-1001 already correct, P-1005 expired, P-1003 wrong dept
# Desired: P-1001, P-1002.  So P-1005 and P-1003 removed, P-1002 added.
GRP_DN="cn=landau-stadt,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: landau-stadt
description: Angehörige der Einheit Landau-Stadt
member: cn=P-1001,${LDAP_USERS_OU}
member: cn=P-1005,${LDAP_USERS_OU}
member: cn=P-1003,${LDAP_USERS_OU}"
  echo "  → Group 'landau-stadt': created with P-1001 (correct), P-1005 (expired), P-1003 (wrong)"
else
  echo "  → Group 'landau-stadt': already exists"
fi

# landau-dammheim — empty (placeholder), P-1003 should be added
GRP_DN="cn=landau-dammheim,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: landau-dammheim
description: Angehörige der Einheit Landau-Dammheim
member: cn=P-1001,${LDAP_USERS_OU}"
  echo "  → Group 'landau-dammheim': created with P-1001 (wrong dept)"
else
  echo "  → Group 'landau-dammheim': already exists"
fi

# wehrfuehrer — P-1001 wrongly in here, P-1003 should be added
GRP_DN="cn=wehrfuehrer,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: wehrfuehrer
description: Wehrführer
member: cn=P-1001,${LDAP_USERS_OU}"
  echo "  → Group 'wehrfuehrer': created with P-1001 (wrong member)"
else
  echo "  → Group 'wehrfuehrer': already exists"
fi

# gefahrstoffzug — P-1002 wrongly assigned, P-1004 should be added
GRP_DN="cn=gefahrstoffzug,${LDAP_GROUPS_OU}"
if ! ldap_entry_exists "${GRP_DN}"; then
  ldap_add "dn: ${GRP_DN}
objectClass: top
objectClass: groupOfNames
cn: gefahrstoffzug
description: Angehörige des Gefahrstoffzuges
member: cn=P-1002,${LDAP_USERS_OU}"
  echo "  → Group 'gefahrstoffzug': created with P-1002 (wrong member)"
else
  echo "  → Group 'gefahrstoffzug': already exists"
fi

echo ""
echo "════════════════════════════════════════════════"
echo "Seeding complete."
echo ""
echo "Expected sync.py behaviour:"
echo "  Group 'atemschutz'     : +P-1001, +P-1002  (remove P-1004 expired, P-1005 wrong)"
echo "  Group 'korbfahrer'     : +P-1002            (remove P-1003 wrong)"
echo "  Group 'landau-stadt'   : +P-1002            (keep P-1001, remove P-1005 expired + P-1003 wrong)"
echo "  Group 'landau-dammheim': +P-1003            (remove P-1001 wrong dept)"
echo "  Group 'wehrfuehrer'    : +P-1003            (remove P-1001 wrong)"
echo "  Group 'gefahrstoffzug' : +P-1004            (remove P-1002 wrong)"
echo ""
echo "  P-1001: +atemschutz, +landau-stadt(kept)    −landau-dammheim, −wehrfuehrer"
echo "  P-1002: +atemschutz, +korbfahrer, +landau-stadt  −gefahrstoffzug"
echo "  P-1003: +landau-dammheim, +wehrfuehrer      −korbfahrer, −landau-stadt"
echo "  P-1004: +gefahrstoffzug                     −atemschutz"
echo "  P-1005:                                     −atemschutz, −landau-stadt"
echo "════════════════════════════════════════════════"
