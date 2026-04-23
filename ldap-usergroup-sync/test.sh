#!/usr/bin/env bash
# Version 3 — 2026-04-17
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Integration tests for sync.py
#
# Each test:
#   1. Arranges : puts DB + LDAP into a specific known state
#   2. Acts     : runs sync.sh with a test-only config
#   3. Asserts  : verifies the resulting LDAP state
#   4. Reports  : prints PASS or FAIL with details
#
# Run inside the Docker container (same environment as sync.sh):
#   ./test.sh [--config <path>]
#
# The test config inherits LDAP/DB connection settings from config.yaml and
# replaces group_mappings with test-specific entries.  SMTP is stripped so no
# real emails are sent.  All test persons use personNumbers 8011–8016.
#
# Departments and functions reuse existing DB rows (Landau-Stadt id=10,
# Atemschutzgeräteträger/in id=3) to avoid needing knowledge of the full
# departments/functions table schema.  Test isolation is achieved by using
# persontypes 98/99 that only exist during test runs.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
TEST_CONFIG="${SCRIPT_DIR}/test-config.yaml"

# ── CLI arguments ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|-c) CONFIG_FILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Load LDAP + DB connection settings from config.yaml ──────────────────
# Store the python output in a variable first (matching sync.py's pattern),
# which avoids a bash -n quirk with heredocs inside eval "$(...)" when a
# case statement precedes it.
_config_exports="$(python3 - "${CONFIG_FILE}" <<'PYEOF'
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
eval "${_config_exports}"

# ── Test constants ────────────────────────────────────────────────────────
# Person numbers 8011-8016 are reserved for tests only.
P_ALICE=8011
P_BOB=8012
P_CAROL=8013
P_DAVE=8014    # inactive person
P_EVE=8015     # wrong person type
P_FRANK=8016   # used for future-date membership tests
P_GRACE=8017   # second persontype — verifies prefix is read dynamically from persontypes.short
P_HEIDI=389    # short number — verifies zero-padding to 4 digits → expected CN "TI-0389"

# DB row IDs for the test persons (high range, no production overlap)
DB_ID_ALICE=9801
DB_ID_BOB=9802
DB_ID_CAROL=9803
DB_ID_DAVE=9804
DB_ID_EVE=9805
DB_ID_FRANK=9806
DB_ID_GRACE=9807
DB_ID_HEIDI=9808

# Person types used exclusively by tests.  IDs 98/99 do not exist in
# production; the distinct 'short' values let assertions verify the CN prefix
# comes from persontypes.short (not a hardcoded "P-").
TEST_PERSON_TYPE=99
TEST_PERSON_TYPE_SHORT="TI"
TEST_PERSON_TYPE_ALT=98
TEST_PERSON_TYPE_ALT_SHORT="TK"

# Reuse existing departments/functions — avoids needing to know their full
# table schema.  Test isolation relies on test persons having type 99 and
# unique test-prefixed LDAP group names (test-landau-stadt, test-atemschutz).
TEST_DEPT_ID=10                            # Landau-Stadt (pre-existing)
TEST_DEPT_NAME="Landau-Stadt"
TEST_FUNC_ID=3                             # Atemschutzgeräteträger/in (pre-existing)
TEST_FUNC_NAME="Atemschutzgeräteträger/in"

# LDAP group names used only by tests (prefixed "test-" to be unambiguous).
# These are separate from the real "landau-stadt" / "atemschutz" groups.
TEST_LDAP_GROUP_DEPT="test-landau-stadt"
TEST_LDAP_GROUP_FUNC="test-atemschutz"
TEST_LDAP_GROUP_UNION="test-union"

# Track results across all tests
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

# Collects assertion failures for the currently running test
_assertion_failures=()

# ── Database helpers ──────────────────────────────────────────────────────

# Execute a SQL statement (no output).
db_exec() {
  PGPASSWORD="${DB_PASS}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" \
    -U "${DB_USER}" -d "${DB_NAME}" \
    -v ON_ERROR_STOP=1 \
    -c "$1" > /dev/null
}

# ── LDAP helpers ──────────────────────────────────────────────────────────

# Returns 0 if the LDAP entry exists, 1 if it does not.
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

# Delete an LDAP entry.  Silently ignores "no such object" errors.
ldap_delete() {
  local dn="$1"
  ldapdelete -x \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
    "${dn}" > /dev/null 2>&1 || true
}

# Add an LDAP entry from an LDIF string.
ldap_add_entry() {
  echo "$1" | ldapadd -x \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
    > /dev/null 2>&1 || true
}

# Return sorted list of member DNs for an LDAP group.
ldap_get_members() {
  local group_cn="$1"
  ldapsearch -x -LLL \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
    -b "${LDAP_GROUPS_OU}" \
    "(&(objectClass=groupOfNames)(cn=${group_cn}))" member 2>/dev/null \
    | grep "^member:" \
    | sed 's/^member: //' \
    | sort
}

# ── Assertion helpers ─────────────────────────────────────────────────────
# Each assert_* function appends to _assertion_failures if the condition
# is not met.  _report_result() reads this array.

assert_ldap_group_exists() {
  local group_cn="$1"
  if ! ldap_entry_exists "cn=${group_cn},${LDAP_GROUPS_OU}"; then
    _assertion_failures+=("LDAP group '${group_cn}' should exist but does not")
  fi
}

assert_ldap_group_missing() {
  local group_cn="$1"
  if ldap_entry_exists "cn=${group_cn},${LDAP_GROUPS_OU}"; then
    _assertion_failures+=("LDAP group '${group_cn}' should NOT exist but does")
  fi
}

assert_ldap_group_has_member() {
  local group_cn="$1"
  local member_dn="$2"
  if ! ldap_get_members "${group_cn}" | grep -qxF "${member_dn}"; then
    _assertion_failures+=("Group '${group_cn}' should contain '${member_dn}' but does not")
  fi
}

assert_ldap_group_lacks_member() {
  local group_cn="$1"
  local member_dn="$2"
  if ldap_get_members "${group_cn}" | grep -qxF "${member_dn}"; then
    _assertion_failures+=("Group '${group_cn}' should NOT contain '${member_dn}' but does")
  fi
}


# ── Test infrastructure ───────────────────────────────────────────────────

# Write a test config.yaml that re-uses connection settings from the base
# config but only syncs Testpersonen (type 5) and maps only the groups
# passed as arguments.
#
# Each argument must be in the format:  ldap_group:type:source:description
# (colons in description are not supported — keep descriptions simple)
write_test_config() {
  python3 - "${CONFIG_FILE}" "$@" > "${TEST_CONFIG}" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as fh:
    config = yaml.safe_load(fh)

# Strip sections not needed (or that would cause side-effects) in tests.
config.pop('smtp', None)
config.pop('sync', None)
config.pop('group_mappings_file', None)

# Replace group_mappings with whatever was passed on the command line.
config['group_mappings'] = []
for arg in sys.argv[2:]:
    parts = arg.split(':', 3)
    config['group_mappings'].append({
        'ldap_group':  parts[0],
        'type':        parts[1],
        'source':      parts[2],
        'description': parts[3] if len(parts) > 3 else '',
    })

print(yaml.dump(config, allow_unicode=True, default_flow_style=False))
PYEOF
}

# Write a test config with a single LDAP group fed by multiple sources
# (new multi-source YAML syntax).
#
# Usage:  write_test_config_multisource GROUP_CN "type1:source1" "type2:source2" ...
write_test_config_multisource() {
  python3 - "${CONFIG_FILE}" "$@" > "${TEST_CONFIG}" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as fh:
    config = yaml.safe_load(fh)

config.pop('smtp', None)
config.pop('sync', None)
config.pop('group_mappings_file', None)

group_cn = sys.argv[2]
sources = []
for arg in sys.argv[3:]:
    mtype, source = arg.split(':', 1)
    sources.append({'type': mtype, 'source': source})

config['group_mappings'] = [{
    'ldap_group':  group_cn,
    'sources':     sources,
    'description': 'Multi-source test group',
}]

print(yaml.dump(config, allow_unicode=True, default_flow_style=False))
PYEOF
}

# Run sync.py with the test config.
# Output is suppressed; sync.py still writes to its own log file.
run_sync() {
  local rc=0
  python3 "${SCRIPT_DIR}/sync.py" --config "${TEST_CONFIG}" > /dev/null 2>&1 || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "  NOTE: sync.py exited with status ${rc} — check the log file"
  fi
}

# Print PASS or FAIL for the current test, then reset _assertion_failures.
report_result() {
  local test_name="$1"
  if [[ ${#_assertion_failures[@]} -eq 0 ]]; then
    echo "  PASS"
    (( PASS_COUNT++ )) || true
  else
    echo "  FAIL"
    for msg in "${_assertion_failures[@]}"; do
      echo "    ✗ ${msg}"
    done
    (( FAIL_COUNT++ )) || true
    FAILED_TESTS+=("${test_name}")
  fi
  _assertion_failures=()
}

# ── Cleanup helpers ───────────────────────────────────────────────────────

# Remove test LDAP groups.
delete_test_ldap_groups() {
  ldap_delete "cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}"
  ldap_delete "cn=${TEST_LDAP_GROUP_FUNC},${LDAP_GROUPS_OU}"
  ldap_delete "cn=${TEST_LDAP_GROUP_UNION},${LDAP_GROUPS_OU}"
  ldap_delete "cn=test-empty-8099,${LDAP_GROUPS_OU}"
}

# Remove all test DB membership rows so each test starts clean.
delete_test_db_memberships() {
  db_exec "
    DELETE FROM public.persondepartments
    WHERE \"personId\" IN (
      ${DB_ID_ALICE}, ${DB_ID_BOB},   ${DB_ID_CAROL},
      ${DB_ID_DAVE},  ${DB_ID_EVE},   ${DB_ID_FRANK},
      ${DB_ID_GRACE}, ${DB_ID_HEIDI}
    );
  "
  db_exec "
    DELETE FROM public.personfunctions
    WHERE \"personId\" IN (
      ${DB_ID_ALICE}, ${DB_ID_BOB},   ${DB_ID_CAROL},
      ${DB_ID_DAVE},  ${DB_ID_EVE},   ${DB_ID_FRANK},
      ${DB_ID_GRACE}, ${DB_ID_HEIDI}
    );
  "
}

# ═══════════════════════════════════════════════════════════════════════════
# Global setup — runs once before all tests
# ═══════════════════════════════════════════════════════════════════════════

global_setup() {
  echo "Setting up baseline test fixtures in the database …"

  # Insert two test-only person types.  The distinct 'short' values let
  # assertions prove that the CN prefix is read from persontypes.short
  # rather than hardcoded.  IDs 98/99 do not exist in production.
  # Using ON CONFLICT DO UPDATE so the short is refreshed even if an older
  # test run left a stale row (e.g. old 'TI99' short) behind.
  db_exec "
    INSERT INTO public.persontypes (id, name, short)
    VALUES (${TEST_PERSON_TYPE},     'TestIsoliert',  '${TEST_PERSON_TYPE_SHORT}'),
           (${TEST_PERSON_TYPE_ALT}, 'TestIsoliertK', '${TEST_PERSON_TYPE_ALT_SHORT}')
    ON CONFLICT (id) DO UPDATE
      SET name  = EXCLUDED.name,
          short = EXCLUDED.short;
  "

  # Insert test persons.  Most share TEST_PERSON_TYPE so their CN prefix is
  # '${TEST_PERSON_TYPE_SHORT}-'.  Grace uses TEST_PERSON_TYPE_ALT ('${TEST_PERSON_TYPE_ALT_SHORT}-').
  # Heidi has personNumber 389 to exercise zero-padding to 4 digits.
  # Dave is active=false to test that inactive persons are not synced.
  # Eve has a production persontype (2) to test that alternate shorts work too.
  db_exec "
    INSERT INTO public.people
      (id, \"persontypeId\", sex, \"lastName\", \"firstName\",
       \"personNumber\", active, \"exportFlag\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_PERSON_TYPE},     2, 'Testerin', 'Alice', ${P_ALICE}, true,  false),
      (${DB_ID_BOB},   ${TEST_PERSON_TYPE},     1, 'Tester',   'Bob',   ${P_BOB},   true,  false),
      (${DB_ID_CAROL}, ${TEST_PERSON_TYPE},     2, 'Tester',   'Carol', ${P_CAROL}, true,  false),
      (${DB_ID_DAVE},  ${TEST_PERSON_TYPE},     1, 'Tester',   'Dave',  ${P_DAVE},  false, false),
      (${DB_ID_EVE},   2,                      2, 'Tester',   'Eve',   ${P_EVE},   true,  false),
      (${DB_ID_FRANK}, ${TEST_PERSON_TYPE},     1, 'Tester',   'Frank', ${P_FRANK}, true,  false),
      (${DB_ID_GRACE}, ${TEST_PERSON_TYPE_ALT}, 2, 'Tester',   'Grace', ${P_GRACE}, true,  false),
      (${DB_ID_HEIDI}, ${TEST_PERSON_TYPE},     2, 'Tester',   'Heidi', ${P_HEIDI}, true,  false)
    ON CONFLICT (id) DO NOTHING;
  "
  # No INSERT into departments or functions — we reuse existing rows
  # (TEST_DEPT_ID=${TEST_DEPT_ID} and TEST_FUNC_ID=${TEST_FUNC_ID}) to avoid
  # needing to know their full table schema.
  echo "  → 8 test persons inserted (types ${TEST_PERSON_TYPE}='${TEST_PERSON_TYPE_SHORT}', ${TEST_PERSON_TYPE_ALT}='${TEST_PERSON_TYPE_ALT_SHORT}'); reusing existing dept/func rows"
}

# ── Global teardown — runs once after all tests ───────────────────────────

global_teardown() {
  echo ""
  echo "Cleaning up all test data …"
  delete_test_db_memberships
  delete_test_ldap_groups
  rm -f "${TEST_CONFIG}"
  echo "  → Done"
}

# ═══════════════════════════════════════════════════════════════════════════
# TESTS — Group membership synchronisation
# ═══════════════════════════════════════════════════════════════════════════

test_T01_absent_group_is_skipped_not_created() {
  echo "T01: Group absent from LDAP, members in DB → sync skips it (no group creation)"
  _assertion_failures=()

  # Arrange: Alice and Bob are in the test department, but the LDAP group does
  # not exist.  The sync must not create the group — it only manages existing ones.
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL),
      (${DB_ID_BOB},   ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: the LDAP group must still not exist
  assert_ldap_group_missing "${TEST_LDAP_GROUP_DEPT}"

  report_result "T01"
}

test_T02_stale_ldap_member_is_removed() {
  echo "T02: LDAP group contains a member who is not in the DB → stale member removed"
  _assertion_failures=()

  # Arrange: only Alice is in the DB department, but LDAP group also has 'old-user'
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=old-user,${LDAP_USERS_OU}
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: old-user removed, Alice stays
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "cn=old-user,${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  report_result "T02"
}

test_T03_missing_member_is_added_to_existing_group() {
  echo "T03: LDAP group exists but is missing a DB member → missing member is added"
  _assertion_failures=()

  # Arrange: Alice and Bob are in the DB department.  LDAP group has only Alice.
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL),
      (${DB_ID_BOB},   ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: both Alice and Bob are now members
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_BOB},${LDAP_USERS_OU}"

  report_result "T03"
}

test_T04_expired_department_membership_excluded() {
  echo "T04: Person's department memberUntil is in the past → removed from LDAP group"
  _assertion_failures=()

  # Arrange:
  #   Carol's membership ended yesterday → should be removed from the group
  #   Bob's membership is open-ended     → should remain in the group
  #   LDAP currently has both Carol and Bob
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_CAROL}, ${TEST_DEPT_ID}, '2020-01-01', (NOW() - INTERVAL '1 day')::date),
      (${DB_ID_BOB},   ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=TI-${P_CAROL},${LDAP_USERS_OU}
member: cn=TI-${P_BOB},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: Carol out (expired), Bob stays
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_CAROL},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_BOB},${LDAP_USERS_OU}"

  report_result "T04"
}

test_T05_future_memberFrom_is_not_yet_active() {
  echo "T05: Person's department memberFrom is in the future → not added to LDAP group"
  _assertion_failures=()

  # Arrange:
  #   Frank's membership starts tomorrow — too early to sync
  #   Alice's membership is already active
  #   LDAP group pre-created with Alice so sync has a group to work with
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_FRANK}, ${TEST_DEPT_ID}, (NOW() + INTERVAL '1 day')::date, NULL),
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: Alice is in the group, Frank is not
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_FRANK},${LDAP_USERS_OU}"

  report_result "T05"
}

test_T06_expired_function_assignment_excluded() {
  echo "T06: Person's function validUntil is in the past → not in the LDAP function group"
  _assertion_failures=()

  # Arrange:
  #   Carol's function cert expired years ago → she should be removed from the group
  #   Alice has a still-valid assignment     → she should remain
  #   LDAP group currently has both
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.personfunctions
      (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
    VALUES
      (${DB_ID_CAROL}, ${TEST_FUNC_ID}, '2018-01-01', '2022-12-31'),
      (${DB_ID_ALICE}, ${TEST_FUNC_ID}, '2021-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_FUNC},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_FUNC}
description: Test func group
member: cn=TI-${P_CAROL},${LDAP_USERS_OU}
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Carol removed (expired cert), Alice stays
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_FUNC}" "cn=TI-${P_CAROL},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_FUNC}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  report_result "T06"
}

test_T07_future_validFrom_for_function_excluded() {
  echo "T07: Person's function validFrom is in the future → not yet added to LDAP group"
  _assertion_failures=()

  # Arrange:
  #   Frank's function assignment starts tomorrow (not yet valid)
  #   Alice's assignment is already active
  #   LDAP group pre-created with Alice (no businessCategory, sync will add it)
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.personfunctions
      (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
    VALUES
      (${DB_ID_FRANK}, ${TEST_FUNC_ID}, (NOW() + INTERVAL '1 day')::date, NULL),
      (${DB_ID_ALICE}, ${TEST_FUNC_ID}, '2021-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_FUNC},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_FUNC}
description: Test func group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Alice stays, Frank not added
  assert_ldap_group_has_member             "${TEST_LDAP_GROUP_FUNC}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member           "${TEST_LDAP_GROUP_FUNC}" "cn=TI-${P_FRANK},${LDAP_USERS_OU}"

  report_result "T07"
}

test_T08_person_appears_in_multiple_groups() {
  echo "T08: Person qualifies for both a department group and a function group → added to both"
  _assertion_failures=()

  # Arrange: Alice has both a department membership and a function assignment.
  # Both LDAP groups are pre-created (empty placeholder member used at creation,
  # sync will set the correct membership).
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  db_exec "
    INSERT INTO public.personfunctions
      (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_FUNC_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_FUNC},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_FUNC}
description: Test func group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  # Config maps both groups — sync processes each independently
  write_test_config \
    "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group" \
    "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Alice is a member of both LDAP groups
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_FUNC}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  report_result "T08"
}

test_T09_group_membership_is_fully_replaced() {
  echo "T09: DB membership changes completely → old members removed, new member added"
  _assertion_failures=()

  # Arrange:
  #   LDAP group has Alice and Bob (from a previous sync state)
  #   DB now shows only Carol in this department
  #   Expected outcome: Alice and Bob removed, Carol added
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_CAROL}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}
member: cn=TI-${P_BOB},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_BOB},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_CAROL},${LDAP_USERS_OU}"

  report_result "T09"
}

test_T10_no_eligible_db_members_means_no_group_created() {
  echo "T10: No DB members qualify for a group → group is NOT created in LDAP"
  _assertion_failures=()

  # Arrange: map the group to a department name that does not exist in the DB
  # at all.  This guarantees zero eligible members regardless of what real
  # persons are assigned to real departments.
  delete_test_db_memberships
  delete_test_ldap_groups
  ldap_delete "cn=test-empty-8099,${LDAP_GROUPS_OU}"

  write_test_config "test-empty-8099:department:Nichtexistierend-Abteilung-8099:Empty test group"

  # Act
  run_sync

  # Assert: sync.sh should log a warning and leave LDAP unchanged
  assert_ldap_group_missing "test-empty-8099"

  report_result "T10"
}

test_T11_sync_is_idempotent() {
  echo "T11: Running sync twice produces the same LDAP state (no duplicate members)"
  _assertion_failures=()

  # Arrange: Alice is in the department; LDAP group pre-created with only Alice
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act: run sync twice in a row
  run_sync
  run_sync

  # Assert: Alice is in the group; Bob and Carol are NOT (no phantom additions)
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_BOB},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_CAROL},${LDAP_USERS_OU}"

  report_result "T11"
}

test_T12_user_with_multiple_roles_removed_from_one_group() {
  echo "T12: Person loses one assignment but keeps another → removed from one group only"
  _assertion_failures=()

  # Arrange:
  #   Alice is in the department (active) but her function cert expired yesterday.
  #   Bob has an active function cert.
  #   Both groups are pre-created in LDAP with Alice as member.
  #   After sync: Alice stays in the dept group, is removed from the func group.
  #   Bob is added to the func group (valid cert).
  #
  #   Note: groupOfNames requires at least one member attribute, so the func
  #   group must have a remaining desired member (Bob) when Alice is removed.
  #   A test with all desired members removed would violate the objectClass
  #   constraint and is a separate operational concern, not this test's focus.
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  db_exec "
    INSERT INTO public.personfunctions
      (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
    VALUES
      -- Alice's cert expired yesterday — she should be removed from the func group
      (${DB_ID_ALICE}, ${TEST_FUNC_ID}, '2020-01-01', (NOW() - INTERVAL '1 day')::date),
      -- Bob has a valid cert — he should be added to the func group
      (${DB_ID_BOB},   ${TEST_FUNC_ID}, '2022-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_FUNC},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_FUNC}
description: Test func group
member: cn=TI-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config \
    "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group" \
    "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Alice stays in dept group, is removed from func group; Bob is in func group
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_FUNC}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_FUNC}" "cn=TI-${P_BOB},${LDAP_USERS_OU}"

  report_result "T12"
}


test_T13_multi_source_group_unions_members() {
  echo "T13: Group mapped to department AND function → members from both sources are unioned"
  _assertion_failures=()

  # Arrange:
  #   Alice qualifies only via the department source.
  #   Bob qualifies only via the function source.
  #   Carol is pre-added to LDAP but qualifies via neither source — she must be removed.
  #   Both sources feed the same LDAP group.
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  db_exec "
    INSERT INTO public.personfunctions
      (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
    VALUES
      (${DB_ID_BOB}, ${TEST_FUNC_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_UNION},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_UNION}
description: Multi-source test group
member: cn=TI-${P_CAROL},${LDAP_USERS_OU}"

  write_test_config_multisource "${TEST_LDAP_GROUP_UNION}" \
    "department:${TEST_DEPT_NAME}" \
    "function:${TEST_FUNC_NAME}"

  # Act
  run_sync

  # Assert: Alice added (dept), Bob added (func), Carol removed (neither)
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_UNION}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_UNION}" "cn=TI-${P_BOB},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_UNION}" "cn=TI-${P_CAROL},${LDAP_USERS_OU}"

  report_result "T13"
}

test_T14_multi_source_dedupes_person_in_both() {
  echo "T14: Person qualifies via BOTH sources → added exactly once (no duplicate / no LDAP error)"
  _assertion_failures=()

  # Arrange: Alice qualifies via both the department and the function.
  # Running sync twice verifies idempotence (no phantom re-adds, no errors from
  # a same-DN-twice add on the second pass).
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  db_exec "
    INSERT INTO public.personfunctions
      (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_FUNC_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_UNION},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_UNION}
description: Multi-source test group
member: cn=placeholder,${LDAP_USERS_OU}"

  write_test_config_multisource "${TEST_LDAP_GROUP_UNION}" \
    "department:${TEST_DEPT_NAME}" \
    "function:${TEST_FUNC_NAME}"

  # Act: two runs to catch any "attribute or value exists" issues
  run_sync
  run_sync

  # Assert: Alice exactly once, placeholder gone
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_UNION}" "cn=TI-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_UNION}" "cn=placeholder,${LDAP_USERS_OU}"

  local alice_count
  alice_count=$(ldap_get_members "${TEST_LDAP_GROUP_UNION}" \
    | grep -cxF "cn=TI-${P_ALICE},${LDAP_USERS_OU}" || true)
  if [[ "${alice_count}" -ne 1 ]]; then
    _assertion_failures+=("Expected Alice to appear exactly once in ${TEST_LDAP_GROUP_UNION}, got ${alice_count}")
  fi

  report_result "T14"
}


test_T15_cn_prefix_follows_persontype_short() {
  echo "T15: Persons of different persontypes share one group → each CN uses its own persontype short"
  _assertion_failures=()

  # Arrange:
  #   Alice (persontype ${TEST_PERSON_TYPE}, short '${TEST_PERSON_TYPE_SHORT}') and
  #   Grace (persontype ${TEST_PERSON_TYPE_ALT}, short '${TEST_PERSON_TYPE_ALT_SHORT}')
  #   are both in the same department.  The resulting CNs must reflect their
  #   respective shorts — proving the prefix is read from persontypes.short
  #   instead of being hardcoded to "P-".
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL),
      (${DB_ID_GRACE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=placeholder,${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: each CN carries the short of its own persontype
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" \
    "cn=${TEST_PERSON_TYPE_SHORT}-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" \
    "cn=${TEST_PERSON_TYPE_ALT_SHORT}-${P_GRACE},${LDAP_USERS_OU}"
  # And the "P-" prefix must NOT be used for persons whose persontype short isn't "P"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" \
    "cn=P-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" \
    "cn=P-${P_GRACE},${LDAP_USERS_OU}"

  report_result "T15"
}

test_T16_person_number_is_zero_padded_to_four_digits() {
  echo "T16: Person number shorter than 4 digits → CN is zero-padded (389 → '0389')"
  _assertion_failures=()

  # Arrange: Heidi's personNumber is 389.  Expected CN: "${TEST_PERSON_TYPE_SHORT}-0389".
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_HEIDI}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: cn=placeholder,${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: padded CN present, unpadded CN absent
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" \
    "cn=${TEST_PERSON_TYPE_SHORT}-0${P_HEIDI},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" \
    "cn=${TEST_PERSON_TYPE_SHORT}-${P_HEIDI},${LDAP_USERS_OU}"

  report_result "T16"
}


# ═══════════════════════════════════════════════════════════════════════════
# Main — run all tests
# ═══════════════════════════════════════════════════════════════════════════

main() {
  echo ""
  echo "════════════════════════════════════════════════"
  echo "ldap-usergroup-sync — integration test suite"
  echo "════════════════════════════════════════════════"
  echo ""

  global_setup

  echo ""
  echo "── Group membership synchronisation ────────────"
  test_T01_absent_group_is_skipped_not_created
  test_T02_stale_ldap_member_is_removed
  test_T03_missing_member_is_added_to_existing_group
  test_T04_expired_department_membership_excluded
  test_T05_future_memberFrom_is_not_yet_active
  test_T06_expired_function_assignment_excluded
  test_T07_future_validFrom_for_function_excluded
  test_T08_person_appears_in_multiple_groups
  test_T09_group_membership_is_fully_replaced
  test_T10_no_eligible_db_members_means_no_group_created
  test_T11_sync_is_idempotent
  test_T12_user_with_multiple_roles_removed_from_one_group
  test_T13_multi_source_group_unions_members
  test_T14_multi_source_dedupes_person_in_both
  test_T15_cn_prefix_follows_persontype_short
  test_T16_person_number_is_zero_padded_to_four_digits

  global_teardown

  echo ""
  echo "════════════════════════════════════════════════"
  printf "Results: %d passed, %d failed\n" "${PASS_COUNT}" "${FAIL_COUNT}"
  if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo "Failed:"
    for t in "${FAILED_TESTS[@]}"; do
      echo "  - ${t}"
    done
  fi
  echo "════════════════════════════════════════════════"

  # Exit with a non-zero code if any test failed, so CI pipelines catch it.
  [[ ${FAIL_COUNT} -eq 0 ]]
}

main
