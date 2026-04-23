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

ldap_delete() {
  ldapdelete -x \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
    "$1" > /dev/null 2>&1 || true
}

echo "════════════════════════════════════════════════"
echo "ldap-usergroup-sync — seeding demo data"
echo "════════════════════════════════════════════════"

# ───────────────────────────────────────────────────────────────────────────
# 1. PostgreSQL — insert test persons
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "── PostgreSQL: inserting test persons ──"

# Reset memberships for the demo persons so this script is re-runnable.
db "
DELETE FROM public.persondepartments WHERE \"personId\" BETWEEN 9001 AND 9005;
DELETE FROM public.personfunctions  WHERE \"personId\" BETWEEN 9001 AND 9005;
"

# Persons — mix of persontypes to exercise every CN prefix case.
# Thomas (personNumber 34) and Peter (123) show zero-padding to 4 digits.
db "
INSERT INTO public.people
  (id, \"persontypeId\", sex, \"lastName\", \"firstName\",
   \"personNumber\", active, \"exportFlag\")
VALUES
  (9001, 1, 1, 'Mustermann', 'Max',      1001, true, false),
  (9002, 1, 2, 'Musterfrau', 'Maria',    1002, true, false),
  (9003, 5, 1, 'Testmann',   'Thomas',     34, true, false),
  (9004, 3, 1, 'Prüfer',     'Peter',     123, true, false),
  (9005, 4, 2, 'Überin',     'Ursula',   4012, true, false)
ON CONFLICT (id) DO UPDATE
  SET \"persontypeId\" = EXCLUDED.\"persontypeId\",
      \"personNumber\" = EXCLUDED.\"personNumber\",
      \"firstName\"    = EXCLUDED.\"firstName\",
      \"lastName\"     = EXCLUDED.\"lastName\",
      active          = EXCLUDED.active;
"
echo "  → 5 persons inserted: P-1001, P-1002, TEST-0034, K-0123, E-4012"

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

-- Maria → Zugführer (active)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9002, 2, '2023-01-01', NULL)
ON CONFLICT DO NOTHING;

-- Ursula → Stellvertretender Zugführer (active — dept membership expired but function is valid)
INSERT INTO public.personfunctions
  (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
VALUES
  (9005, 4, '2023-06-01', NULL)
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

# Remove legacy CNs left over from earlier seed runs (old hardcoded P- prefix
# for every person, or TEST-100x entries the sync created against stale data).
for legacy in P-1003 P-1004 P-1005 TEST-1001 TEST-1002 TEST-1003 TEST-1004 TEST-1005; do
  ldap_delete "cn=${legacy},${LDAP_USERS_OU}"
done

create_ldap_user "P-1001"    "Max Mustermann"   "Mustermann" "Max"
create_ldap_user "P-1002"    "Maria Musterfrau" "Musterfrau" "Maria"
create_ldap_user "TEST-0034" "Thomas Testmann"  "Testmann"   "Thomas"
create_ldap_user "K-0123"    "Peter Prüfer"     "Prüfer"     "Peter"
create_ldap_user "E-4012"    "Ursula Überin"    "Überin"     "Ursula"

echo ""
echo "── LDAP: recreating groups with intentionally stale memberships ──"

# Wipe demo groups so the script is re-runnable with a predictable starting state.
for grp in atemschutz korbfahrer landau-stadt landau-dammheim wehrfuehrer gefahrstoffzug zugfuehrer; do
  ldap_delete "cn=${grp},${LDAP_GROUPS_OU}"
done

# atemschutz — has K-0123 (cert expired) and E-4012 (no function at all).
# Desired: P-1001, P-1002.
ldap_add "dn: cn=atemschutz,${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: atemschutz
description: Aktive Atemschutzgeräteträger
member: cn=K-0123,${LDAP_USERS_OU}
member: cn=E-4012,${LDAP_USERS_OU}"
echo "  → 'atemschutz'      : K-0123 (expired cert) + E-4012 (wrong)"

# korbfahrer — has TEST-0034 (wrong function). Desired: P-1002.
ldap_add "dn: cn=korbfahrer,${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: korbfahrer
description: Korbfahrer
member: cn=TEST-0034,${LDAP_USERS_OU}"
echo "  → 'korbfahrer'      : TEST-0034 (wrong)"

# landau-stadt — P-1001 correct, E-4012 expired, TEST-0034 wrong dept.
# Desired: P-1001, P-1002.
ldap_add "dn: cn=landau-stadt,${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: landau-stadt
description: Angehörige der Einheit Landau-Stadt
member: cn=P-1001,${LDAP_USERS_OU}
member: cn=E-4012,${LDAP_USERS_OU}
member: cn=TEST-0034,${LDAP_USERS_OU}"
echo "  → 'landau-stadt'    : P-1001 (keep) + E-4012 (expired) + TEST-0034 (wrong)"

# landau-dammheim — P-1001 wrong dept. Desired: TEST-0034.
ldap_add "dn: cn=landau-dammheim,${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: landau-dammheim
description: Angehörige der Einheit Landau-Dammheim
member: cn=P-1001,${LDAP_USERS_OU}"
echo "  → 'landau-dammheim' : P-1001 (wrong)"

# wehrfuehrer — P-1001 wrong function. Desired: TEST-0034.
ldap_add "dn: cn=wehrfuehrer,${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: wehrfuehrer
description: Wehrführer
member: cn=P-1001,${LDAP_USERS_OU}"
echo "  → 'wehrfuehrer'     : P-1001 (wrong)"

# gefahrstoffzug — P-1002 wrong function. Desired: K-0123.
ldap_add "dn: cn=gefahrstoffzug,${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: gefahrstoffzug
description: Angehörige des Gefahrstoffzuges
member: cn=P-1002,${LDAP_USERS_OU}"
echo "  → 'gefahrstoffzug'  : P-1002 (wrong)"

# zugfuehrer — P-1001 wrong (no Zugführer function). Desired: P-1002 (Zugführer) + E-4012 (Stellv.).
# Demonstrates multi-source: both function sources merge into one LDAP group.
ldap_add "dn: cn=zugfuehrer,${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: zugfuehrer
description: Zugführer und Stellvertretende Zugführer
member: cn=P-1001,${LDAP_USERS_OU}"
echo "  → 'zugfuehrer'      : P-1001 (wrong — multi-source demo)"

echo ""
echo "════════════════════════════════════════════════"
echo "Seeding complete."
echo ""
echo "Expected sync.py behaviour:"
echo "  'atemschutz'     : +P-1001, +P-1002   −K-0123 (expired) −E-4012 (wrong)"
echo "  'korbfahrer'     : +P-1002             −TEST-0034 (wrong)"
echo "  'landau-stadt'   : +P-1002  (keep P-1001)  −E-4012 (expired) −TEST-0034 (wrong)"
echo "  'landau-dammheim': +TEST-0034          −P-1001 (wrong)"
echo "  'wehrfuehrer'    : +TEST-0034          −P-1001 (wrong)"
echo "  'gefahrstoffzug' : +K-0123             −P-1002 (wrong)"
echo "  'zugfuehrer'     : +P-1002 (Zugführer) +E-4012 (Stellv.)  −P-1001 (wrong)"
echo "                     [multi-source: two functions merged into one group]"
echo ""
echo "  P-1001   : +atemschutz, +landau-stadt(kept)   −landau-dammheim, −wehrfuehrer, −zugfuehrer"
echo "  P-1002   : +atemschutz, +korbfahrer, +landau-stadt, +zugfuehrer  −gefahrstoffzug"
echo "  TEST-0034: +landau-dammheim, +wehrfuehrer    −korbfahrer, −landau-stadt"
echo "  K-0123   : +gefahrstoffzug                   −atemschutz"
echo "  E-4012   : +zugfuehrer                       −atemschutz, −landau-stadt"
echo "════════════════════════════════════════════════"
