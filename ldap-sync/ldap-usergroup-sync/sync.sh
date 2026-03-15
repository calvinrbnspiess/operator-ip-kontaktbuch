#!/usr/bin/env bash
# Version 1 — 15-03-2026
# ═══════════════════════════════════════════════════════════════════════════
# ldap-usergroup-sync
#
# Reads group memberships from PostgreSQL and keeps LDAP in sync.
# Only groups listed in config.yaml are ever modified.
#
# Usage:
#   ./sync.sh [--config <path>] [--dry-run]
#
# Options:
#   --config <path>   Path to config.yaml  (default: ./config.yaml)
#   --dry-run, -n     Print planned changes but apply nothing
#   --help,    -h     Show this help
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"
LOG_DIR="${SCRIPT_DIR}/logs"
DRY_RUN=false

# ─── Parse CLI arguments ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config|-c)  CONFIG_FILE="$2"; shift 2 ;;
    --dry-run|-n) DRY_RUN=true;     shift   ;;
    --help|-h)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Logging ────────────────────────────────────────────────────────────────
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sync-$(date +%Y-%m-%d).log"

_log() {
  local level="$1"; shift
  local line; line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
  echo "${line}" | tee -a "${LOG_FILE}"
}
log_info()   { _log "INFO  " "$@"; }
log_warn()   { _log "WARN  " "$@"; }
log_error()  { _log "ERROR " "$@"; }
log_change() { _log "CHANGE" "$@"; }
log_dry()    { _log "DRY   " "$@"; }

# ─── Dependency check ───────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in ldapsearch ldapmodify ldapadd psql python3; do
    command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Install them or run inside the provided Docker container."
    exit 1
  fi
  # Verify python3 has PyYAML
  if ! python3 -c "import yaml" &>/dev/null; then
    log_error "Python3 module 'yaml' (PyYAML) is not installed."
    exit 1
  fi
}

# ─── Load configuration ─────────────────────────────────────────────────────
load_config() {
  [[ -f "${CONFIG_FILE}" ]] || {
    log_error "Config file not found: ${CONFIG_FILE}"
    exit 1
  }

  # Use Python to validate and export all scalar config values as shell vars.
  local py_out
  py_out="$(python3 - "${CONFIG_FILE}" <<'PYEOF'
import sys, yaml, os

with open(sys.argv[1]) as fh:
    c = yaml.safe_load(fh)

def esc(v):
    """Single-quote escape for shell."""
    return "'" + str(v).replace("'", "'\\''") + "'"

l = c['ldap']
d = c['database']
s = c['sync']

pairs = [
    ("LDAP_HOST",         l['host']),
    ("LDAP_PORT",         l['port']),
    ("LDAP_BIND_DN",      l['bind_dn']),
    ("LDAP_BIND_PW",      l['bind_password']),
    ("LDAP_BASE_DN",      l['base_dn']),
    ("LDAP_USERS_OU",     l['users_ou']),
    ("LDAP_GROUPS_OU",    l['groups_ou']),
    ("DB_HOST",           d['host']),
    ("DB_PORT",           d['port']),
    ("DB_NAME",           d['name']),
    ("DB_USER",           d['user']),
    ("DB_PASS",           d['password']),
    ("SYNC_GID_NUMBER",   s['gid_number']),
    ("SYNC_HOME_BASE",    s['home_base']),
    ("SYNC_CREATE_USERS",       'true' if s.get('create_users', True) else 'false'),
    ("SYNC_SET_DEFAULT_PW",    'true' if s.get('set_default_password', True) else 'false'),
    ("SYNC_DEFAULT_PW",        s.get('default_password', 'ChangeMe123!')),
    ("SYNC_TYPE_IDS",          ','.join(str(i) for i in s.get('person_type_ids', []))),
]

for name, val in pairs:
    print(f"{name}={esc(val)}")
PYEOF
)"
  eval "${py_out}"
}

# ─── LDAP helpers ───────────────────────────────────────────────────────────

# Run ldapsearch, return stdout (stderr suppressed).
_ldap_search() {
  ldapsearch -x -LLL \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
    -b "$1" "$2" ${3:+"$3"} 2>/dev/null
}

# Apply an LDIF passed as $1. In dry-run mode only log.
# Never aborts the whole script on LDAP errors — logs them instead.
_ldap_apply() {
  local op="$1"   # "modify" or "add"
  local ldif="$2"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_dry "$(echo "${ldif}" | head -2) …"
    return 0
  fi
  local cmd
  case "${op}" in
    modify) cmd=ldapmodify ;;
    add)    cmd=ldapadd    ;;
    *)      log_error "Unknown op: ${op}"; return 1 ;;
  esac
  local output rc=0
  output=$(echo "${ldif}" | "${cmd}" -x \
    -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
    -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" 2>&1) || rc=$?
  echo "${output}" | tee -a "${LOG_FILE}"
  if [[ ${rc} -ne 0 ]]; then
    # Benign: "value already exists" (20) or "no such attribute" (16) are fine
    # to see when the state is already correct.
    if echo "${output}" | grep -qiE "already exists|no such attribute|already a member"; then
      log_warn "LDAP op skipped (already in desired state): ${output}"
    else
      log_error "LDAP op failed (rc=${rc}): ${output}"
    fi
  fi
  return 0  # Never abort the whole sync for a single entry
}

# Returns 0 (true) if the entry with given DN exists in LDAP.
ldap_entry_exists() {
  local dn="$1"
  local base="${dn#*,}"   # everything after the first RDN is the search base
  local rdn="${dn%%,*}"   # first RDN is the filter component
  local attr="${rdn%%=*}"
  local val="${rdn#*=}"
  local hits
  hits=$(_ldap_search "${base}" "(${attr}=${val})" dn 2>/dev/null \
         | grep -c "^dn:" || true)
  [[ "${hits}" -gt 0 ]]
}

# ─── Database helpers ───────────────────────────────────────────────────────

# Run a SQL query, output tab-separated rows (no header, no trailing spaces).
db_query() {
  PGPASSWORD="${DB_PASS}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" \
    -U "${DB_USER}" -d "${DB_NAME}" \
    -t -A -F $'\t' \
    -c "$1"
}

# ─── Password helpers ────────────────────────────────────────────────────────

# Return a {SSHA} hashed password suitable for use as an LDAP userPassword.
# SSHA = SHA-1(password + salt) + salt, base64-encoded, prefixed with {SSHA}.
# A fresh 4-byte random salt is used on every call.
ssha_hash() {
  python3 -c "
import hashlib, os, base64, sys
pw   = sys.argv[1].encode('utf-8')
salt = os.urandom(4)
print('{SSHA}' + base64.b64encode(hashlib.sha1(pw + salt).digest() + salt).decode())
" "$1"
}

# ─── Phase 1: User sync ─────────────────────────────────────────────────────

sync_users() {
  log_info "──────────────────────────────────────────────"
  log_info "Phase 1 — Syncing users"
  log_info "──────────────────────────────────────────────"

  # Build optional WHERE clause for person type IDs
  local type_clause=""
  if [[ -n "${SYNC_TYPE_IDS:-}" ]]; then
    type_clause="AND p.\"persontypeId\" IN (${SYNC_TYPE_IDS})"
  fi

  local query
  query="
    SELECT
      p.\"personNumber\",
      p.\"firstName\",
      p.\"lastName\"
    FROM public.people p
    WHERE p.\"personNumber\" IS NOT NULL
      AND p.active = TRUE
      ${type_clause}
    ORDER BY p.\"personNumber\";
  "

  local created=0 updated=0 skipped=0

  while IFS=$'\t' read -r person_number first_name last_name; do
    [[ -z "${person_number}" ]] && continue

    local uid="P-${person_number}"
    local dn="uid=${uid},${LDAP_USERS_OU}"
    local home_dir="${SYNC_HOME_BASE}/p-${person_number}"
    local cn="${first_name} ${last_name}"

    if ldap_entry_exists "${dn}"; then
      # ── User exists: ensure posixAccount attributes are present ──────────
      local has_posix
      has_posix=$(_ldap_search "${LDAP_USERS_OU}" "(uid=${uid})" objectClass \
                  | grep -c "^objectClass: posixAccount" || true)

      if [[ "${has_posix}" -gt 0 ]]; then
        log_info "User ${uid}: already has posixAccount — skipped"
        (( skipped++ )) || true
        continue
      fi

      log_change "User ${uid}: adding POSIX attributes (uidNumber=${person_number})"
      _ldap_apply modify "$(cat <<LDIF
dn: ${dn}
changetype: modify
add: objectClass
objectClass: posixAccount
-
add: objectClass
objectClass: shadowAccount
-
add: uidNumber
uidNumber: ${person_number}
-
add: gidNumber
gidNumber: ${SYNC_GID_NUMBER}
-
add: homeDirectory
homeDirectory: ${home_dir}
-
add: loginShell
loginShell: /bin/bash
LDIF
)"
      (( updated++ )) || true

    else
      # ── User does not exist ───────────────────────────────────────────────
      if [[ "${SYNC_CREATE_USERS}" != "true" ]]; then
        log_info "User ${uid}: not in LDAP and create_users=false — skipped"
        (( skipped++ )) || true
        continue
      fi

      log_change "User ${uid}: creating (${first_name} ${last_name}, uidNumber=${person_number})"

      # Build the LDIF as a string so we can conditionally include userPassword.
      # Omitting userPassword entirely creates the account in a locked state —
      # the user cannot authenticate until an admin sets a password.
      local new_user_ldif
      new_user_ldif="dn: ${dn}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ${uid}
cn: ${cn}
sn: ${last_name}
givenName: ${first_name}
uidNumber: ${person_number}
gidNumber: ${SYNC_GID_NUMBER}
homeDirectory: ${home_dir}
loginShell: /bin/bash"
      if [[ "${SYNC_SET_DEFAULT_PW}" == "true" ]]; then
        new_user_ldif+="
userPassword: $(ssha_hash "${SYNC_DEFAULT_PW}")"
        log_info "User ${uid}: default password will be set as SSHA hash"
      else
        log_info "User ${uid}: no default password set (account locked until admin sets one)"
      fi

      _ldap_apply add "${new_user_ldif}"
      (( created++ )) || true
    fi

  done < <(db_query "${query}")

  log_info "Phase 1 done — created=${created}, updated=${updated}, skipped=${skipped}"
}

# ─── Phase 2: Group membership sync ─────────────────────────────────────────

# Return the sorted list of current 'member' values for a group (full DNs).
_current_members() {
  local group_dn="$1"
  # Extract just the CN value:  "cn=korbfahrer,ou=groups,…" → "korbfahrer"
  local rdn="${group_dn%%,*}"   # "cn=korbfahrer"
  local cn_val="${rdn#*=}"      # "korbfahrer"
  _ldap_search "${LDAP_GROUPS_OU}" "(&(objectClass=groupOfNames)(cn=${cn_val}))" member \
    | grep "^member:" \
    | sed 's/^member: //' \
    | sort
}

# Return the sorted list of desired members (as full user DNs) from Postgres.
# Arguments: type ("department"|"function"), source name
_desired_members() {
  local type="$1"
  local source="$2"
  # Single-quote escape the source value to avoid SQL injection via config.
  local safe_source; safe_source="${source//\'/\'\'}"

  local query
  if [[ "${type}" == "department" ]]; then
    query="
      SELECT DISTINCT
        'uid=P-' || p.\"personNumber\" || ',${LDAP_USERS_OU}'
      FROM public.people p
      JOIN public.persondepartments pd ON pd.\"personId\" = p.id
      JOIN public.departments       d  ON d.id = pd.\"departmentId\"
      WHERE p.\"personNumber\" IS NOT NULL
        AND p.active = TRUE
        AND d.name = '${safe_source}'
        AND (pd.\"memberFrom\"  IS NULL OR pd.\"memberFrom\"  <= NOW())
        AND (pd.\"memberUntil\" IS NULL OR pd.\"memberUntil\" >= NOW())
      ORDER BY 1;
    "
  elif [[ "${type}" == "function" ]]; then
    query="
      SELECT DISTINCT
        'uid=P-' || p.\"personNumber\" || ',${LDAP_USERS_OU}'
      FROM public.people p
      JOIN public.personfunctions pf ON pf.\"personId\" = p.id
      JOIN public.functions        f  ON f.id = pf.\"funcId\"
      WHERE p.\"personNumber\" IS NOT NULL
        AND p.active = TRUE
        AND f.name = '${safe_source}'
        AND (pf.\"validFrom\"  IS NULL OR pf.\"validFrom\"  <= NOW())
        AND (pf.\"validUntil\" IS NULL OR pf.\"validUntil\" >= NOW())
      ORDER BY 1;
    "
  else
    log_error "Unknown mapping type '${type}' for source '${source}'"
    return 1
  fi

  db_query "${query}"
}

# Ensure the LDAP group exists; create it if needed.
# groupOfNames requires at least one 'member' at creation time.
# We pass the first desired member so the initial add satisfies the schema.
_ensure_group() {
  local group_cn="$1"
  local type="$2"          # "department" or "function"
  local description="${3:-}"
  local first_member="$4"
  local group_dn="cn=${group_cn},${LDAP_GROUPS_OU}"

  if ldap_entry_exists "${group_dn}"; then
    return 0
  fi

  log_change "Group '${group_cn}': creating in LDAP (businessCategory=${type})"

  # Build the LDIF line by line so we never emit a blank line when description
  # is absent.  In LDIF format a blank line is a record separator, which would
  # split this into two broken records and cause ldapadd to fail.
  local ldif
  ldif="dn: ${group_dn}
objectClass: top
objectClass: groupOfNames
cn: ${group_cn}
businessCategory: ${type}"
  [[ -n "${description}" ]] && ldif+="
description: ${description}"
  ldif+="
member: ${first_member}"

  _ldap_apply add "${ldif}"
}

sync_group() {
  local group_cn="$1"
  local type="$2"
  local source="$3"
  local description="${4:-}"
  local group_dn="cn=${group_cn},${LDAP_GROUPS_OU}"

  log_info "Group '${group_cn}' (type=${type}, source='${source}')"

  # Collect desired members from DB
  local -a desired=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && desired+=("${line}")
  done < <(_desired_members "${type}" "${source}")

  if [[ ${#desired[@]} -eq 0 ]]; then
    log_warn "Group '${group_cn}': no eligible members found in DB — skipping"
    return 0
  fi

  # Track whether the group was just created (first member was implicit).
  local group_created=false
  if ! ldap_entry_exists "${group_dn}"; then
    _ensure_group "${group_cn}" "${type}" "${description}" "${desired[0]}"
    group_created=true
  else
    # Ensure businessCategory is present on pre-existing groups.
    local has_biz_cat
    has_biz_cat=$(_ldap_search "${LDAP_GROUPS_OU}" "(cn=${group_cn})" businessCategory \
                  | grep -c "^businessCategory:" || true)
    if [[ "${has_biz_cat}" -eq 0 ]]; then
      log_change "Group '${group_cn}': adding businessCategory=${type}"
      _ldap_apply modify "$(cat <<LDIF
dn: ${group_dn}
changetype: modify
add: businessCategory
businessCategory: ${type}
LDIF
)"
    fi
  fi

  # Collect current members (reflects the just-created state if applicable).
  local -a current=()
  while IFS= read -r line; do
    [[ -n "${line}" ]] && current+=("${line}")
  done < <(_current_members "${group_dn}")

  # Count the initial member (inserted via ldapadd) as an add.
  local added=0 removed=0
  if [[ "${group_created}" == "true" ]]; then
    (( added++ )) || true
  fi

  # ── Add missing members ──────────────────────────────────────────────────
  for member_dn in "${desired[@]}"; do
    if ! printf '%s\n' "${current[@]}" | grep -qxF "${member_dn}"; then
      log_change "Group '${group_cn}': + ${member_dn}"
      _ldap_apply modify "$(cat <<LDIF
dn: ${group_dn}
changetype: modify
add: member
member: ${member_dn}
LDIF
)"
      (( added++ )) || true
    fi
  done

  # ── Remove excess members ────────────────────────────────────────────────
  # Since desired is non-empty and all desired members have already been added
  # above, the group is guaranteed to have at least |desired| members at this
  # point — so removal is always safe.
  for member_dn in "${current[@]}"; do
    if ! printf '%s\n' "${desired[@]}" | grep -qxF "${member_dn}"; then
      log_change "Group '${group_cn}': - ${member_dn}"
      _ldap_apply modify "$(cat <<LDIF
dn: ${group_dn}
changetype: modify
delete: member
member: ${member_dn}
LDIF
)"
      (( removed++ )) || true
    fi
  done

  log_info "Group '${group_cn}' done — added=${added}, removed=${removed}"
}

sync_groups() {
  log_info "──────────────────────────────────────────────"
  log_info "Phase 2 — Syncing group memberships"
  log_info "──────────────────────────────────────────────"

  # Read group_mappings from YAML via Python and pipe into the loop.
  while IFS=$'\t' read -r group_cn type source description; do
    sync_group "${group_cn}" "${type}" "${source}" "${description}"
  done < <(python3 - "${CONFIG_FILE}" <<'PYEOF'
import sys, yaml

with open(sys.argv[1]) as fh:
    c = yaml.safe_load(fh)

for m in c.get('group_mappings', []):
    desc = m.get('description', '')
    print(f"{m['ldap_group']}\t{m['type']}\t{m['source']}\t{desc}")
PYEOF
)

  log_info "Phase 2 done"
}

# ─── Connectivity pre-flight ────────────────────────────────────────────────

check_connectivity() {
  log_info "Checking LDAP connectivity …"
  if ! ldapsearch -x -LLL \
      -H "ldap://${LDAP_HOST}:${LDAP_PORT}" \
      -D "${LDAP_BIND_DN}" -w "${LDAP_BIND_PW}" \
      -b "${LDAP_BASE_DN}" -s base "(objectClass=*)" dn &>/dev/null; then
    log_error "Cannot reach LDAP at ${LDAP_HOST}:${LDAP_PORT} — aborting"
    exit 1
  fi
  log_info "LDAP OK"

  log_info "Checking PostgreSQL connectivity …"
  if ! PGPASSWORD="${DB_PASS}" psql \
      -h "${DB_HOST}" -p "${DB_PORT}" \
      -U "${DB_USER}" -d "${DB_NAME}" \
      -c "SELECT 1" &>/dev/null; then
    log_error "Cannot reach PostgreSQL at ${DB_HOST}:${DB_PORT} — aborting"
    exit 1
  fi
  log_info "PostgreSQL OK"
}

# ─── Entry point ────────────────────────────────────────────────────────────

main() {
  log_info "════════════════════════════════════════════════"
  log_info "ldap-usergroup-sync starting"
  log_info "Config : ${CONFIG_FILE}"
  log_info "Log    : ${LOG_FILE}"
  [[ "${DRY_RUN}" == "true" ]] && \
    log_info "Mode   : DRY RUN — no changes will be written"
  log_info "════════════════════════════════════════════════"

  check_deps
  load_config
  check_connectivity
  sync_users
  sync_groups

  log_info "════════════════════════════════════════════════"
  log_info "ldap-usergroup-sync finished"
  log_info "════════════════════════════════════════════════"
}

main
