#!/usr/bin/env python3
"""
ldap-usergroup-sync — Group membership synchroniser
Version 3 — 2026-04-17

Reads group memberships from PostgreSQL and keeps existing LDAP groups in sync.
Only modifies groups explicitly listed in the group mappings config.
Never creates new groups — they must already exist in LDAP.

Usage:
    ./sync.py [--config <path>] [--dry-run]

Options:
    --config <path>   Path to config.yaml (default: ./config.yaml)
    --dry-run, -n     Print planned changes but apply nothing
    --help,    -h     Show this help
"""

import argparse
import logging
import re
import smtplib
import sys
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path

import jinja2
import psycopg2
import yaml
from ldap3 import ALL, BASE, MODIFY_ADD, MODIFY_DELETE, Connection, Server
from ldap3.utils.conv import escape_filter_chars

SCRIPT_DIR = Path(__file__).parent
LOG_DIR = SCRIPT_DIR / "logs"

_JINJA_ENV = jinja2.Environment(autoescape=True)

_REPORT_TEMPLATE = _JINJA_ENV.from_string("""\
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<style>
  body  { font-family: Arial, sans-serif; font-size: 14px; color: #333; }
  h2    { color: #2c3e50; }
  h3    { margin-top: 24px; }
  table { border-collapse: collapse; width: 100%; margin-top: 12px; }
  th, td { border: 1px solid #ddd; padding: 8px 12px; text-align: left; vertical-align: middle; }
  th    { background: #f4f4f4; font-weight: bold; }
  tr:nth-child(even) { background: #fafafa; }
  code  { background: #f0f0f0; padding: 1px 4px; border-radius: 3px; }
  .badge { color: #fff; padding: 2px 6px; border-radius: 3px; font-size: 12px; }
  .badge-add    { background: #28a745; }
  .badge-remove { background: #dc3545; }
  .badge-dry    { background: #f0ad4e; padding: 2px 8px; }
</style>
</head>
<body>
<h2>
  {% if dry_run %}<span class="badge badge-dry">DRY RUN</span>&nbsp;{% endif %}
  LDAP Gruppenzuweisungen
</h2>
<p>
  <b>Zeitpunkt:</b> {{ now }}<br>
  <b>&Auml;nderungen:</b> {{ change_count }} bei {{ user_count }} Nutzer(n)
</p>

<table>
  <thead>
    <tr>
      <th>Name</th>
      <th>Kennung</th>
      <th>Gruppen&auml;nderungen</th>
      <th>DN</th>
    </tr>
  </thead>
  <tbody>
    {% for user in users %}
    <tr>
      <td>{{ user.name or "—" }}</td>
      <td>{{ user.user_id or "—" }}</td>
      <td>
        {% for g in user.added %}
          <span class="badge badge-add">+ {{ g }}</span>
        {% endfor %}
        {% for g in user.removed %}
          <span class="badge badge-remove">− {{ g }}</span>
        {% endfor %}
      </td>
      <td><code style="font-size:12px">{{ user.dn }}</code></td>
    </tr>
    {% else %}
    <tr><td colspan="4">Keine &Auml;nderungen</td></tr>
    {% endfor %}
  </tbody>
</table>

<h3>Nutzer nicht in LDAP vorhanden</h3>
{% if missing_users %}
<ul>
  {% for u in missing_users %}
  <li><code style="font-size:12px">{{ u }}</code></li>
  {% endfor %}
</ul>
{% else %}
<p>Keine</p>
{% endif %}

<h3>Gruppen nicht in LDAP vorhanden</h3>
{% if missing_groups %}
<ul>
  {% for g in missing_groups %}
  <li><code style="font-size:12px">{{ g }}</code></li>
  {% endfor %}
</ul>
{% else %}
<p>Keine</p>
{% endif %}

</body>
</html>""")

_DN_SPECIAL = re.compile(r'[,+"\\\<\>;=#]')

_MEMBER_QUERIES: dict[str, str] = {
    "department": """
        SELECT DISTINCT
               'cn=P-' || p."personNumber" || ',' || %s,
               p."firstName", p."lastName",
               'P-' || p."personNumber"
        FROM public.people p
        JOIN public.persondepartments pd ON pd."personId" = p.id
        JOIN public.departments       d  ON d.id = pd."departmentId"
        WHERE p."personNumber" IS NOT NULL
          AND p.active = TRUE
          AND d.name = %s
          AND (pd."memberFrom"  IS NULL OR pd."memberFrom"  <= NOW())
          AND (pd."memberUntil" IS NULL OR pd."memberUntil" >= NOW())
        ORDER BY 1
    """,
    "function": """
        SELECT DISTINCT
               'cn=P-' || p."personNumber" || ',' || %s,
               p."firstName", p."lastName",
               'P-' || p."personNumber"
        FROM public.people p
        JOIN public.personfunctions pf ON pf."personId" = p.id
        JOIN public.functions        f  ON f.id = pf."funcId"
        WHERE p."personNumber" IS NOT NULL
          AND p.active = TRUE
          AND f.name = %s
          AND (pf."validFrom"  IS NULL OR pf."validFrom"  <= NOW())
          AND (pf."validUntil" IS NULL OR pf."validUntil" >= NOW())
        ORDER BY 1
    """,
}


# ─── Logging ────────────────────────────────────────────────────────────────

def setup_logging(log_file: Path) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(levelname)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[
            logging.StreamHandler(sys.stdout),
            logging.FileHandler(log_file, encoding="utf-8"),
        ],
    )


def log_change(action: str, group: str, dn: str, note: str = "") -> None:
    symbol = "+" if action == "add" else "-"
    suffix = f"  [{note}]" if note else ""
    logging.info("  %s  %-24s  %s%s", symbol, group, dn, suffix)


# ─── Input validation ────────────────────────────────────────────────────────

def _validate_rdn_value(value: str, field: str) -> None:
    """
    Reject values containing RFC 4514 DN special characters.

    We build group DNs by simple string concatenation
    (cn=<group_cn>,<groups_ou>), so a group_cn containing a bare comma
    or other DN metachar would silently point the operation at a different
    LDAP entry.  Fail loudly instead.
    """
    if _DN_SPECIAL.search(value):
        raise ValueError(
            f"Config field '{field}' contains a DN special character: {value!r}. "
            "Use a plain alphanumeric CN."
        )


def _safe_header(value: str) -> str:
    """
    Strip CR and LF from an email header value.

    Python's legacy email.message API does not reject multiline values,
    which would allow SMTP header injection if the config were tampered with.
    """
    return value.replace("\r", "").replace("\n", "")


# ─── Configuration ───────────────────────────────────────────────────────────

def _load_group_mappings(config_path: Path, mappings_file: str) -> list:
    mappings_path = Path(mappings_file)
    if not mappings_path.is_absolute():
        mappings_path = config_path.parent / mappings_path
    with open(mappings_path, encoding="utf-8") as fh:
        return yaml.safe_load(fh).get("group_mappings", [])


def load_config(config_path: Path) -> dict:
    with open(config_path, encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh)
    if "group_mappings_file" in cfg and "group_mappings" not in cfg:
        cfg["group_mappings"] = _load_group_mappings(config_path, cfg["group_mappings_file"])
    return cfg


# ─── LDAP helpers ────────────────────────────────────────────────────────────

def connect_ldap(cfg: dict) -> Connection:
    ldap_cfg = cfg["ldap"]
    server = Server(ldap_cfg["host"], port=int(ldap_cfg["port"]), get_info=ALL)
    return Connection(
        server,
        user=ldap_cfg["bind_dn"],
        password=ldap_cfg["bind_password"],
        auto_bind=True,
    )


def ldap_entry_exists(conn: Connection, dn: str) -> bool:
    """Return True if the entry with the given DN exists in LDAP.

    Uses a BASE-scope search on the DN itself — no filter construction,
    no DN parsing, no attribute-type injection risk.
    """
    conn.search(
        search_base=dn,
        search_filter="(objectClass=*)",
        search_scope=BASE,
        attributes=[],
    )
    return bool(conn.entries)


def get_current_members(conn: Connection, group_cn: str, groups_ou: str) -> set[str]:
    """Return the set of current member DNs (lowercased) for the given group."""
    safe_cn = escape_filter_chars(group_cn)
    conn.search(
        search_base=groups_ou,
        search_filter=f"(&(objectClass=groupOfNames)(cn={safe_cn}))",
        attributes=["member"],
    )
    if not conn.entries:
        return set()
    members = conn.entries[0].entry_attributes_as_dict.get("member", [])
    return {str(m).lower() for m in members}


def ldap_modify(conn: Connection, dn: str, changes: dict, dry_run: bool) -> bool:
    """Apply an LDAP modify operation. Returns True on success (or dry_run)."""
    if dry_run:
        return True
    conn.modify(dn, changes)
    result = conn.result
    code = result.get("result", -1)
    if code == 0:
        return True
    # 20 = "attribute or value exists" (add of already-present member)
    # 16 = "no such attribute"          (delete of already-absent member)
    if code in (16, 20):
        logging.warning("LDAP op skipped (already in desired state): %s", result.get("description"))
        return True
    logging.error("LDAP modify failed (code=%d): %s", code, result.get("description"))
    return False


# ─── Database helpers ────────────────────────────────────────────────────────

def connect_db(cfg: dict):
    db_cfg = cfg["database"]
    return psycopg2.connect(
        host=db_cfg["host"],
        port=int(db_cfg["port"]),
        dbname=db_cfg["name"],
        user=db_cfg["user"],
        password=db_cfg["password"],
    )


def get_desired_members(db_conn, mapping: dict, users_ou: str) -> list[tuple[str, str, str, str]]:
    """Query PostgreSQL for the desired group members.

    Returns a list of (dn, firstName, lastName, userId) tuples.
    Uses parameterised queries throughout — no SQL injection possible.
    personNumber is a numeric DB column; the resulting DN strings are safe.
    """
    mtype = mapping["type"]
    source = mapping["source"]

    query = _MEMBER_QUERIES.get(mtype)
    if query is None:
        raise ValueError(f"Unknown mapping type: {mtype!r}")

    with db_conn.cursor() as cur:
        cur.execute(query, (users_ou, source))
        return [(row[0], row[1] or "", row[2] or "", row[3]) for row in cur.fetchall()]


# ─── Group sync ──────────────────────────────────────────────────────────────


def sync_group(
    ldap_conn: Connection,
    db_conn,
    mapping: dict,
    users_ou: str,
    groups_ou: str,
    dry_run: bool,
) -> tuple[list[dict], bool]:
    """Sync one group's membership.

    Returns (changes, group_missing) where changes is a list of:
        {"group": str, "action": "add"|"remove", "dn": str,
         "user_exists": bool, "first_name": str, "last_name": str, "user_id": str}
    and group_missing is True if the LDAP group does not exist.
    """
    group_cn = mapping["ldap_group"]
    mtype = mapping.get("type", "")
    source = mapping.get("source", "")

    logging.info("Group '%s'  type=%-12s  source='%s'", group_cn, mtype, source)

    _validate_rdn_value(group_cn, "ldap_group")

    group_dn = f"cn={group_cn},{groups_ou}"

    if not ldap_entry_exists(ldap_conn, group_dn):
        logging.warning(
            "  !  Group '%s' does not exist in LDAP — skipping (create it manually first)",
            group_cn,
        )
        return [], True

    desired_raw = get_desired_members(db_conn, mapping, users_ou)
    if not desired_raw:
        logging.warning("  !  Group '%s': no eligible members found in DB — skipping", group_cn)
        return [], False

    # Build lookup maps: lower-cased DN → original DN and → user info
    dn_by_lower = {dn.lower(): dn for dn, _, _, _ in desired_raw}
    info_by_lower = {dn.lower(): (first, last, uid) for dn, first, last, uid in desired_raw}
    desired_lower = set(dn_by_lower)
    current_lower = get_current_members(ldap_conn, group_cn, groups_ou)

    changes = []

    for lower_dn in sorted(desired_lower - current_lower):
        member_dn = dn_by_lower[lower_dn]
        first, last, uid = info_by_lower[lower_dn]
        user_exists = ldap_entry_exists(ldap_conn, member_dn)
        log_change("add", group_cn, member_dn, "" if user_exists else "user not found in LDAP")
        ldap_modify(ldap_conn, group_dn, {"member": [(MODIFY_ADD, [member_dn])]}, dry_run)
        changes.append({
            "group": group_cn, "action": "add", "dn": member_dn,
            "user_exists": user_exists, "first_name": first, "last_name": last, "user_id": uid,
        })

    for member_dn in sorted(current_lower - desired_lower):
        log_change("remove", group_cn, member_dn)
        ldap_modify(ldap_conn, group_dn, {"member": [(MODIFY_DELETE, [member_dn])]}, dry_run)
        # Extract uid from DN (e.g. "uid=P-1001,ou=..." → "P-1001")
        rdn = member_dn.split(",", 1)[0]
        removed_uid = rdn.split("=", 1)[1] if "=" in rdn else ""
        changes.append({
            "group": group_cn, "action": "remove", "dn": member_dn,
            "user_exists": True, "first_name": "", "last_name": "", "user_id": removed_uid,
        })

    added = sum(1 for c in changes if c["action"] == "add")
    removed = sum(1 for c in changes if c["action"] == "remove")
    unchanged = len(desired_lower) - added
    logging.info("  Group '%s' done — +%d  -%d  (%d unchanged)", group_cn, added, removed, unchanged)
    return changes, False


# ─── Email notification ──────────────────────────────────────────────────────

def _group_changes_by_user(changes: list) -> dict:
    """Group changes by user DN.

    Returns {dn: {"added": [...], "removed": [...], "user_exists": bool,
                   "first_name": str, "last_name": str, "user_id": str}}.
    """
    by_user = {}
    for c in changes:
        dn = c["dn"].lower()
        if dn not in by_user:
            by_user[dn] = {
                "added": [], "removed": [],
                "user_exists": c.get("user_exists", True),
                "first_name": c.get("first_name", ""),
                "last_name": c.get("last_name", ""),
                "user_id": c.get("user_id", ""),
            }
        if c["action"] == "add":
            by_user[dn]["added"].append(c["group"])
        else:
            by_user[dn]["removed"].append(c["group"])
        # Enrich with name/id from any record that has them
        if c.get("first_name") and not by_user[dn]["first_name"]:
            by_user[dn]["first_name"] = c["first_name"]
            by_user[dn]["last_name"] = c["last_name"]
            by_user[dn]["user_id"] = c["user_id"]
        if not c.get("user_exists", True):
            by_user[dn]["user_exists"] = False
    return by_user


def build_html_report(changes: list, missing_groups: list[str], dry_run: bool) -> str:
    by_user = _group_changes_by_user(changes)

    users = []
    for dn in sorted(by_user):
        info = by_user[dn]
        users.append({
            "name": f"{info['first_name']} {info['last_name']}".strip(),
            "user_id": info["user_id"],
            "added": sorted(info["added"]),
            "removed": sorted(info["removed"]),
            "dn": dn,
        })

    missing_users = sorted(
        {f"{info['first_name']} {info['last_name']} ({info['user_id']})"
         for info in by_user.values() if not info["user_exists"] and info["user_id"]},
    )

    return _REPORT_TEMPLATE.render(
        dry_run=dry_run,
        now=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        change_count=len(changes),
        user_count=len(by_user),
        users=users,
        missing_users=missing_users,
        missing_groups=sorted(missing_groups),
    )


def send_email(cfg: dict, changes: list, missing_groups: list[str], dry_run: bool) -> None:
    smtp_cfg = cfg.get("smtp")
    if not smtp_cfg:
        logging.info("No SMTP config — skipping email notification")
        return
    if not changes and not missing_groups:
        logging.info("No changes — skipping email notification")
        return

    recipients = smtp_cfg["to"] if isinstance(smtp_cfg["to"], list) else [smtp_cfg["to"]]
    now_str = datetime.now().strftime("%Y-%m-%d")
    subject = f"[LDAP Sync] {len(changes)} Gruppenzuweisungen - {now_str}"
    if dry_run:
        subject = f"[DRY RUN] {subject}"

    msg = MIMEMultipart("alternative")
    msg["Subject"] = _safe_header(subject)
    msg["From"] = _safe_header(smtp_cfg["from"])
    msg["To"] = _safe_header(", ".join(_safe_header(r) for r in recipients))
    msg.attach(MIMEText(build_html_report(changes, missing_groups, dry_run), "html", "utf-8"))

    if dry_run:
        logging.info("[DRY] Would send email '%s' to %s", subject, msg["To"])
        return

    try:
        with smtplib.SMTP(smtp_cfg["host"], int(smtp_cfg.get("port", 587))) as server:
            if smtp_cfg.get("starttls", True):
                server.starttls()
            if smtp_cfg.get("user"):
                server.login(smtp_cfg["user"], smtp_cfg["password"])
            server.sendmail(smtp_cfg["from"], recipients, msg.as_string())
        logging.info("Email notification sent to %s", msg["To"])
    except Exception as exc:
        logging.error("Failed to send email notification: %s", exc)


# ─── Entry point ─────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="LDAP group membership synchroniser (group assignments only)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--config", "-c",
        default=str(SCRIPT_DIR / "config.yaml"),
        help="Path to config.yaml (default: ./config.yaml)",
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="Print planned changes but apply nothing",
    )
    args = parser.parse_args()

    log_file = LOG_DIR / f"sync-{datetime.now().strftime('%Y-%m-%d')}.log"
    setup_logging(log_file)

    logging.info("=" * 56)
    logging.info("ldap-usergroup-sync")
    logging.info("  Config : %s", args.config)
    logging.info("  Log    : %s", log_file)
    if args.dry_run:
        logging.info("  Mode   : DRY RUN — no changes will be written")
    logging.info("=" * 56)

    config = load_config(Path(args.config))

    logging.info("Checking LDAP connectivity …")
    try:
        ldap_conn = connect_ldap(config)
        logging.info("  LDAP OK")
    except Exception as exc:
        logging.error("  Cannot connect to LDAP: %s — aborting", exc)
        sys.exit(1)

    logging.info("Checking PostgreSQL connectivity …")
    try:
        db_conn = connect_db(config)
        logging.info("  PostgreSQL OK")
    except Exception as exc:
        logging.error("  Cannot connect to PostgreSQL: %s — aborting", exc)
        sys.exit(1)

    smtp_cfg = config.get("smtp")
    if smtp_cfg:
        logging.info("Checking SMTP connectivity …")
        try:
            with smtplib.SMTP(smtp_cfg["host"], int(smtp_cfg.get("port", 587)), timeout=10) as server:
                if smtp_cfg.get("starttls", True):
                    server.starttls()
                if smtp_cfg.get("user"):
                    server.login(smtp_cfg["user"], smtp_cfg["password"])
            logging.info("  SMTP OK")
        except Exception as exc:
            logging.error("  Cannot connect to SMTP: %s — aborting", exc)
            sys.exit(1)

    users_ou = config["ldap"]["users_ou"]
    groups_ou = config["ldap"]["groups_ou"]

    logging.info("-" * 56)
    logging.info("Syncing group memberships")
    logging.info("-" * 56)

    all_changes = []
    missing_groups = []
    for mapping in config.get("group_mappings", []):
        try:
            changes, group_missing = sync_group(ldap_conn, db_conn, mapping, users_ou, groups_ou, args.dry_run)
            all_changes.extend(changes)
            if group_missing:
                missing_groups.append(mapping["ldap_group"])
        except Exception as exc:
            logging.error("Error syncing group '%s': %s", mapping.get("ldap_group"), exc)

    logging.info("-" * 56)
    logging.info("Group sync complete — total changes: %d", len(all_changes))

    send_email(config, all_changes, missing_groups, args.dry_run)

    db_conn.close()
    ldap_conn.unbind()

    logging.info("=" * 56)
    logging.info("ldap-usergroup-sync finished")
    logging.info("=" * 56)


if __name__ == "__main__":
    main()
