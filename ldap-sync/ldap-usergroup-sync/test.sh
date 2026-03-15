#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# test.sh — Integration tests for sync.sh
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
# The test config inherits LDAP/DB connection settings from config.yaml but
# restricts person_type_ids to [99] (TestIsoliert — created by this script)
# so that real persons AND seed.sh persons (type 5) are never touched.
# All test persons use personNumbers 8011–8016.
#
# Departments and functions reuse existing DB rows (Landau-Stadt id=10,
# Atemschutzgeräteträger/in id=3) to avoid needing knowledge of the full
# departments/functions table schema.  Isolation is guaranteed by the
# person_type_ids=[99] filter — only our test persons appear in any query.
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
# Store the python output in a variable first (matching sync.sh's pattern),
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
s = c['sync']
for name, val in [
    ("LDAP_HOST",       l['host']),
    ("LDAP_PORT",       l['port']),
    ("LDAP_BIND_DN",    l['bind_dn']),
    ("LDAP_BIND_PW",    l['bind_password']),
    ("LDAP_BASE_DN",    l['base_dn']),
    ("LDAP_USERS_OU",   l['users_ou']),
    ("LDAP_GROUPS_OU",  l['groups_ou']),
    ("SYNC_HOME_BASE",  s.get('home_base', '/home')),
    ("SYNC_GID_NUMBER", str(s.get('gid_number', 100))),
    ("DB_HOST",         d['host']),
    ("DB_PORT",         d['port']),
    ("DB_NAME",         d['name']),
    ("DB_USER",         d['user']),
    ("DB_PASS",         d['password']),
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
P_EVE=8015     # wrong person type (type=2, excluded by test config filter)
P_FRANK=8016   # used for future-date membership tests

# DB row IDs for the test persons (high range, no production overlap)
DB_ID_ALICE=9801
DB_ID_BOB=9802
DB_ID_CAROL=9803
DB_ID_DAVE=9804
DB_ID_EVE=9805
DB_ID_FRANK=9806

# Person type used exclusively for test persons.
# Type 99 does not exist in production; the test config filters for [99] only,
# so seed.sh persons (type 5) and real persons (type 1) are never touched.
TEST_PERSON_TYPE=99

# Reuse existing departments/functions — avoids needing to know their full
# table schema.  Only test persons (type 99) ever appear in these groups
# because the sync config filters by person_type_ids=[99].
TEST_DEPT_ID=10                            # Landau-Stadt (pre-existing)
TEST_DEPT_NAME="Landau-Stadt"
TEST_FUNC_ID=3                             # Atemschutzgeräteträger/in (pre-existing)
TEST_FUNC_NAME="Atemschutzgeräteträger/in"

# LDAP group names used only by tests (prefixed "test-" to be unambiguous).
# These are separate from the real "landau-stadt" / "atemschutz" groups.
TEST_LDAP_GROUP_DEPT="test-landau-stadt"
TEST_LDAP_GROUP_FUNC="test-atemschutz"

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

assert_ldap_user_exists() {
  local uid="$1"
  if ! ldap_entry_exists "uid=${uid},${LDAP_USERS_OU}"; then
    _assertion_failures+=("User '${uid}' should exist in LDAP but does not")
  fi
}

assert_ldap_user_missing() {
  local uid="$1"
  if ldap_entry_exists "uid=${uid},${LDAP_USERS_OU}"; then
    _assertion_failures+=("User '${uid}' should NOT exist in LDAP but does")
  fi
}

assert_ldap_user_has_posix() {
  local uid="$1"
  local count
  count=$(ldapsearch -x -LLL \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
    -b "${LDAP_USERS_OU}" "(uid=${uid})" objectClass 2>/dev/null \
    | grep -c "^objectClass: posixAccount" || true)
  if [[ "${count}" -eq 0 ]]; then
    _assertion_failures+=("User '${uid}' should have posixAccount objectClass but does not")
  fi
}

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

# Restrict to type 99 (TestIsoliert) so neither production persons (type 1)
# nor seed.sh persons (type 5) are ever touched during tests.
config['sync']['person_type_ids'] = [99]

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

# Run sync.sh with the test config.  We call it via `bash` rather than
# executing it directly so that it works even if the mounted host directory
# does not have the execute bit set (common with bind mounts on macOS/Windows).
# Output is suppressed; sync.sh still writes to its own log file.
run_sync() {
  local rc=0
  bash "${SCRIPT_DIR}/sync.sh" --config "${TEST_CONFIG}" > /dev/null 2>&1 || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    echo "  NOTE: sync.sh exited with status ${rc} — check the log file"
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

# Remove test LDAP users (called at the start of Phase 1 tests and at teardown).
delete_test_ldap_users() {
  for p_num in ${P_ALICE} ${P_BOB} ${P_CAROL} ${P_DAVE} ${P_EVE} ${P_FRANK}; do
    ldap_delete "uid=p-${p_num},${LDAP_USERS_OU}"
  done
}

# Remove test LDAP groups.
delete_test_ldap_groups() {
  ldap_delete "cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}"
  ldap_delete "cn=${TEST_LDAP_GROUP_FUNC},${LDAP_GROUPS_OU}"
  ldap_delete "cn=test-empty-8099,${LDAP_GROUPS_OU}"
}

# Remove all test DB membership rows so each test starts clean.
delete_test_db_memberships() {
  db_exec "
    DELETE FROM public.persondepartments
    WHERE \"personId\" IN (
      ${DB_ID_ALICE}, ${DB_ID_BOB}, ${DB_ID_CAROL},
      ${DB_ID_DAVE},  ${DB_ID_EVE}, ${DB_ID_FRANK}
    );
  "
  db_exec "
    DELETE FROM public.personfunctions
    WHERE \"personId\" IN (
      ${DB_ID_ALICE}, ${DB_ID_BOB}, ${DB_ID_CAROL},
      ${DB_ID_DAVE},  ${DB_ID_EVE}, ${DB_ID_FRANK}
    );
  "
}

# ═══════════════════════════════════════════════════════════════════════════
# Global setup — runs once before all tests
# ═══════════════════════════════════════════════════════════════════════════

global_setup() {
  echo "Setting up baseline test fixtures in the database …"

  # Insert a test-only person type (99 = TestIsoliert).
  # The test sync config filters for person_type_ids=[99], which means
  # production persons (type 1) and seed.sh persons (type 5) are completely
  # invisible to sync.sh during test runs.
  db_exec "
    INSERT INTO public.persontypes (id, name, short)
    VALUES (${TEST_PERSON_TYPE}, 'TestIsoliert', 'TI99')
    ON CONFLICT (id) DO NOTHING;
  "

  # Insert test persons.  All get type 99 except Eve (type 2) who is used
  # to test that the person_type_ids filter correctly excludes her.
  # Dave is active=false to test that inactive persons are not synced.
  db_exec "
    INSERT INTO public.people
      (id, \"persontypeId\", sex, \"lastName\", \"firstName\",
       \"personNumber\", active, \"exportFlag\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_PERSON_TYPE}, 2, 'Testerin', 'Alice', ${P_ALICE}, true,  false),
      (${DB_ID_BOB},   ${TEST_PERSON_TYPE}, 1, 'Tester',   'Bob',   ${P_BOB},   true,  false),
      (${DB_ID_CAROL}, ${TEST_PERSON_TYPE}, 2, 'Tester',   'Carol', ${P_CAROL}, true,  false),
      (${DB_ID_DAVE},  ${TEST_PERSON_TYPE}, 1, 'Tester',   'Dave',  ${P_DAVE},  false, false),
      (${DB_ID_EVE},   2,                  2, 'Tester',   'Eve',   ${P_EVE},   true,  false),
      (${DB_ID_FRANK}, ${TEST_PERSON_TYPE}, 1, 'Tester',   'Frank', ${P_FRANK}, true,  false)
    ON CONFLICT (id) DO NOTHING;
  "
  # No INSERT into departments or functions — we reuse existing rows
  # (TEST_DEPT_ID=${TEST_DEPT_ID} and TEST_FUNC_ID=${TEST_FUNC_ID}) to avoid
  # needing to know their full table schema.
  echo "  → 6 test persons (type ${TEST_PERSON_TYPE}) inserted; reusing existing dept/func rows"
}

# ── Global teardown — runs once after all tests ───────────────────────────

global_teardown() {
  echo ""
  echo "Cleaning up all test data …"
  delete_test_db_memberships
  delete_test_ldap_users
  delete_test_ldap_groups
  rm -f "${TEST_CONFIG}"
  echo "  → Done"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1 TESTS — User synchronisation
# ═══════════════════════════════════════════════════════════════════════════

test_T01_new_user_is_created_in_ldap() {
  echo "T01: Active person in DB but absent from LDAP → user is created with POSIX attributes"
  _assertion_failures=()

  # Arrange: make sure Alice does not exist in LDAP
  delete_test_ldap_users
  write_test_config   # no group mappings needed for a user-only test

  # Act
  run_sync

  # Assert: Alice should now exist and have posixAccount
  assert_ldap_user_exists    "p-${P_ALICE}"
  assert_ldap_user_has_posix "p-${P_ALICE}"

  report_result "T01"
}

test_T02_existing_user_without_posix_gets_posix_added() {
  echo "T02: User in LDAP without posixAccount → sync adds posixAccount"
  _assertion_failures=()

  # Arrange: put Bob in LDAP as a plain inetOrgPerson (no POSIX attributes)
  ldap_delete "uid=p-${P_BOB},${LDAP_USERS_OU}"
  ldap_add_entry "dn: uid=p-${P_BOB},${LDAP_USERS_OU}
objectClass: inetOrgPerson
uid: p-${P_BOB}
cn: Bob Tester
sn: Tester
givenName: Bob
userPassword: OldPassword1!"

  write_test_config

  # Act
  run_sync

  # Assert: posixAccount should have been added to the existing entry
  assert_ldap_user_has_posix "p-${P_BOB}"

  report_result "T02"
}

test_T03_inactive_user_is_not_created() {
  echo "T03: Inactive person (active=false) → not created in LDAP"
  _assertion_failures=()

  # Arrange: Dave is inactive in the DB; ensure he is absent from LDAP
  ldap_delete "uid=p-${P_DAVE},${LDAP_USERS_OU}"
  write_test_config

  # Act
  run_sync

  # Assert: Dave must remain absent
  assert_ldap_user_missing "p-${P_DAVE}"

  report_result "T03"
}

test_T04_wrong_persontype_is_not_synced() {
  echo "T04: Person with persontypeId not in the filter list → not synced"
  _assertion_failures=()

  # Arrange: Eve has persontypeId=2; the test config only allows type 5.
  ldap_delete "uid=p-${P_EVE},${LDAP_USERS_OU}"
  write_test_config

  # Act
  run_sync

  # Assert: Eve must remain absent
  assert_ldap_user_missing "p-${P_EVE}"

  report_result "T04"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2 TESTS — Group membership synchronisation
# ═══════════════════════════════════════════════════════════════════════════

test_T05_new_group_is_created_with_correct_members() {
  echo "T05: Group absent from LDAP, members in DB → group is created with all members"
  _assertion_failures=()

  # Arrange: Alice and Bob are both in the test department; no LDAP group yet
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

  # Assert: group created with both Alice and Bob
  assert_ldap_group_exists      "${TEST_LDAP_GROUP_DEPT}"
  assert_ldap_group_has_member  "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member  "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_BOB},${LDAP_USERS_OU}"

  report_result "T05"
}

test_T06_stale_ldap_member_is_removed() {
  echo "T06: LDAP group contains a member who is not in the DB → stale member removed"
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
member: uid=old-user,${LDAP_USERS_OU}
member: uid=p-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: old-user removed, Alice stays
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "uid=old-user,${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"

  report_result "T06"
}

test_T07_missing_member_is_added_to_existing_group() {
  echo "T07: LDAP group exists but is missing a DB member → missing member is added"
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
member: uid=p-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: both Alice and Bob are now members
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_BOB},${LDAP_USERS_OU}"

  report_result "T07"
}

test_T08_expired_department_membership_excluded() {
  echo "T08: Person's department memberUntil is in the past → removed from LDAP group"
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
member: uid=p-${P_CAROL},${LDAP_USERS_OU}
member: uid=p-${P_BOB},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: Carol out (expired), Bob stays
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_CAROL},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_BOB},${LDAP_USERS_OU}"

  report_result "T08"
}

test_T09_future_memberFrom_is_not_yet_active() {
  echo "T09: Person's department memberFrom is in the future → not added to LDAP group"
  _assertion_failures=()

  # Arrange:
  #   Frank's membership starts tomorrow — too early to sync
  #   Alice's membership is already active
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_FRANK}, ${TEST_DEPT_ID}, (NOW() + INTERVAL '1 day')::date, NULL),
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert: Alice is in the group, Frank is not
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_FRANK},${LDAP_USERS_OU}"

  report_result "T09"
}

test_T10_expired_function_assignment_excluded() {
  echo "T10: Person's function validUntil is in the past → not in the LDAP function group"
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
member: uid=p-${P_CAROL},${LDAP_USERS_OU}
member: uid=p-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Carol removed (expired cert), Alice stays
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_FUNC}" "uid=p-${P_CAROL},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_FUNC}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"

  report_result "T10"
}

test_T11_future_validFrom_for_function_excluded() {
  echo "T11: Person's function validFrom is in the future → not yet added to LDAP group"
  _assertion_failures=()

  # Arrange:
  #   Frank's function assignment starts tomorrow (not yet valid)
  #   Alice's assignment is already active
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.personfunctions
      (\"personId\", \"funcId\", \"validFrom\", \"validUntil\")
    VALUES
      (${DB_ID_FRANK}, ${TEST_FUNC_ID}, (NOW() + INTERVAL '1 day')::date, NULL),
      (${DB_ID_ALICE}, ${TEST_FUNC_ID}, '2021-01-01', NULL);
  "

  write_test_config "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Alice added, Frank not
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_FUNC}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_FUNC}" "uid=p-${P_FRANK},${LDAP_USERS_OU}"

  report_result "T11"
}

test_T12_person_appears_in_multiple_groups() {
  echo "T12: Person qualifies for both a department group and a function group → added to both"
  _assertion_failures=()

  # Arrange: Alice has both a department membership and a function assignment
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

  # Config maps both groups — sync processes each independently
  write_test_config \
    "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group" \
    "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Alice is a member of both LDAP groups
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_FUNC}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"

  report_result "T12"
}

test_T13_group_membership_is_fully_replaced() {
  echo "T13: DB membership changes completely → old members removed, new member added"
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
member: uid=p-${P_ALICE},${LDAP_USERS_OU}
member: uid=p-${P_BOB},${LDAP_USERS_OU}"

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act
  run_sync

  # Assert
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_BOB},${LDAP_USERS_OU}"
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_CAROL},${LDAP_USERS_OU}"

  report_result "T13"
}

test_T14_no_eligible_db_members_means_no_group_created() {
  echo "T14: No DB members qualify for a group → group is NOT created in LDAP"
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

  report_result "T14"
}

test_T15_sync_is_idempotent() {
  echo "T15: Running sync twice produces the same LDAP state (no duplicate members)"
  _assertion_failures=()

  # Arrange: Alice is in the department; no LDAP group yet
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "

  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group"

  # Act: run sync twice in a row
  run_sync
  run_sync

  # Assert: Alice is in the group; Bob and Carol are NOT (no phantom additions)
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_BOB},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_CAROL},${LDAP_USERS_OU}"

  report_result "T15"
}

test_T17_group_without_description_is_created_correctly() {
  echo "T17: Group mapping with no description → group still created (no blank-line LDIF bug)"
  _assertion_failures=()

  # This test guards against a specific bug where an empty description caused
  # a blank line in the LDIF, splitting the add record and silently failing.
  delete_test_db_memberships
  delete_test_ldap_groups
  db_exec "
    INSERT INTO public.persondepartments
      (\"personId\", \"departmentId\", \"memberFrom\", \"memberUntil\")
    VALUES
      (${DB_ID_ALICE}, ${TEST_DEPT_ID}, '2020-01-01', NULL);
  "

  # Pass an empty description (four-field format with trailing colon but no value)
  write_test_config "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:"

  # Act
  run_sync

  # Assert: group was created despite empty description
  assert_ldap_group_exists     "${TEST_LDAP_GROUP_DEPT}"
  assert_ldap_group_has_member "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"

  report_result "T17"
}

test_T16_user_with_multiple_roles_removed_from_one_group() {
  echo "T16: Person loses one assignment but keeps another → removed from one group only"
  _assertion_failures=()

  # Arrange:
  #   Alice is in both the department AND has the function.
  #   LDAP has her in both groups.
  #   Now her function cert expires — she should be removed from the func group
  #   but remain in the dept group.
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
      -- Function cert expired yesterday
      (${DB_ID_ALICE}, ${TEST_FUNC_ID}, '2020-01-01', (NOW() - INTERVAL '1 day')::date);
  "
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_DEPT},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_DEPT}
description: Test dept group
member: uid=p-${P_ALICE},${LDAP_USERS_OU}"
  ldap_add_entry "dn: cn=${TEST_LDAP_GROUP_FUNC},${LDAP_GROUPS_OU}
objectClass: top
objectClass: groupOfNames
cn: ${TEST_LDAP_GROUP_FUNC}
description: Test func group
member: uid=p-${P_ALICE},${LDAP_USERS_OU}"

  write_test_config \
    "${TEST_LDAP_GROUP_DEPT}:department:${TEST_DEPT_NAME}:Test dept group" \
    "${TEST_LDAP_GROUP_FUNC}:function:${TEST_FUNC_NAME}:Test func group"

  # Act
  run_sync

  # Assert: Alice stays in dept group, is removed from func group
  assert_ldap_group_has_member   "${TEST_LDAP_GROUP_DEPT}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"
  assert_ldap_group_lacks_member "${TEST_LDAP_GROUP_FUNC}" "uid=p-${P_ALICE},${LDAP_USERS_OU}"

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
  echo "── Phase 1: User synchronisation ───────────────"
  test_T01_new_user_is_created_in_ldap
  test_T02_existing_user_without_posix_gets_posix_added
  test_T03_inactive_user_is_not_created
  test_T04_wrong_persontype_is_not_synced

  echo ""
  echo "── Phase 2: Group membership synchronisation ───"
  test_T05_new_group_is_created_with_correct_members
  test_T06_stale_ldap_member_is_removed
  test_T07_missing_member_is_added_to_existing_group
  test_T08_expired_department_membership_excluded
  test_T09_future_memberFrom_is_not_yet_active
  test_T10_expired_function_assignment_excluded
  test_T11_future_validFrom_for_function_excluded
  test_T12_person_appears_in_multiple_groups
  test_T13_group_membership_is_fully_replaced
  test_T14_no_eligible_db_members_means_no_group_created
  test_T15_sync_is_idempotent
  test_T16_user_with_multiple_roles_removed_from_one_group
  test_T17_group_without_description_is_created_correctly

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
