#!/usr/bin/env bash
# Usage:
#   bash seed_data.sh
# Description:
#   - Seeds database with a sample organization, admin user, roles, permissions, and assignments.
#   - Reads MySQL connection info from rbac_mysql_database/db_connection.txt.
#   - Executes inserts one statement per mysql -e invocation (no .sql files).
# Notes:
#   - The MySQL port is sourced from db_connection.txt; no hardcoded port in this script.
#   - Replace the bcrypt hash with a real value later if needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [[ ! -f "${CONN_FILE}" ]]; then
  echo "Error: ${CONN_FILE} not found. Run startup.sh and schema_setup.sh first."
  exit 1
fi

LINE="$(cat "${CONN_FILE}" | tr -d '\r' | xargs)"
if [[ -z "${LINE}" ]]; then
  echo "Error: db_connection.txt is empty."
  exit 1
fi

MYSQL_USER=""
MYSQL_PASS=""
MYSQL_HOST="localhost"
MYSQL_PORT=""
MYSQL_DB=""

read -ra PARTS <<< "${LINE}"
for (( i=0; i<${#PARTS[@]}; i++ )); do
  token="${PARTS[$i]}"
  case "${token}" in
    -u) MYSQL_USER="${PARTS[$((i+1))]}" ;;
    -u*) MYSQL_USER="${token#-u}" ;;
    -p) MYSQL_PASS="${PARTS[$((i+1))]}" ;;
    -p*) MYSQL_PASS="${token#-p}" ;;
    -h) MYSQL_HOST="${PARTS[$((i+1))]}" ;;
    -h*) MYSQL_HOST="${token#-h}" ;;
    -P) MYSQL_PORT="${PARTS[$((i+1))]}" ;;
    -P*) MYSQL_PORT="${token#-P}" ;;
    *)
      if [[ "${token}" != mysql && "${token}" != -* ]]; then
        MYSQL_DB="${token}"
      fi
      ;;
  esac
done

if [[ -z "${MYSQL_USER}" || -z "${MYSQL_PASS}" || -z "${MYSQL_HOST}" || -z "${MYSQL_PORT}" || -z "${MYSQL_DB}" ]]; then
  echo "Parsed connection: user='${MYSQL_USER}' host='${MYSQL_HOST}' port='${MYSQL_PORT}' db='${MYSQL_DB}'"
  echo "Error: Failed to parse all required fields from ${CONN_FILE}."
  exit 1
fi

MYSQL_BASE_CMD=(mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" -p"${MYSQL_PASS}" "${MYSQL_DB}")

echo "Seeding RBAC data into '${MYSQL_DB}' on ${MYSQL_HOST}:${MYSQL_PORT} ..."

# Seed data values
ORG_NAME="Acme Corp"
ADMIN_EMAIL="admin@acme.example"
# Placeholder bcrypt hash; replace later with real hash if desired.
ADMIN_PW_HASH="\$2b\$12\$exampleplaceholderforbcrypthashdontuseinprod1234567890abcd"

# Insert organization (ignore if exists)
"${MYSQL_BASE_CMD[@]}" -e "INSERT INTO organizations (name) VALUES ('${ORG_NAME}') ON DUPLICATE KEY UPDATE name=VALUES(name);"

# Capture org_id
ORG_ID="$("${MYSQL_BASE_CMD[@]}" -N -e "SELECT id FROM organizations WHERE name='${ORG_NAME}' LIMIT 1;")"
if [[ -z "${ORG_ID}" ]]; then
  echo "Error: Failed to fetch org_id."
  exit 1
fi

# Insert permissions
"${MYSQL_BASE_CMD[@]}" -e "INSERT INTO permissions (org_id, name, description) VALUES (${ORG_ID}, 'user.read', 'Read user data') ON DUPLICATE KEY UPDATE description=VALUES(description);"
"${MYSQL_BASE_CMD[@]}" -e "INSERT INTO permissions (org_id, name, description) VALUES (${ORG_ID}, 'user.write', 'Write user data') ON DUPLICATE KEY UPDATE description=VALUES(description);"
"${MYSQL_BASE_CMD[@]}" -e "INSERT INTO permissions (org_id, name, description) VALUES (${ORG_ID}, 'role.manage', 'Manage roles') ON DUPLICATE KEY UPDATE description=VALUES(description);"

# Capture permission IDs
PERM_READ_ID="$("${MYSQL_BASE_CMD[@]}" -N -e "SELECT id FROM permissions WHERE org_id=${ORG_ID} AND name='user.read' LIMIT 1;")"
PERM_WRITE_ID="$("${MYSQL_BASE_CMD[@]}" -N -e "SELECT id FROM permissions WHERE org_id=${ORG_ID} AND name='user.write' LIMIT 1;")"
PERM_ROLE_MGMT_ID="$("${MYSQL_BASE_CMD[@]}" -N -e "SELECT id FROM permissions WHERE org_id=${ORG_ID} AND name='role.manage' LIMIT 1;")"

# Insert roles
"${MYSQL_BASE_CMD[@]}" -e "INSERT INTO roles (org_id, name, description) VALUES (${ORG_ID}, 'admin', 'Administrator role') ON DUPLICATE KEY UPDATE description=VALUES(description);"
"${MYSQL_BASE_CMD[@]}" -e "INSERT INTO roles (org_id, name, description) VALUES (${ORG_ID}, 'member', 'Standard member role') ON DUPLICATE KEY UPDATE description=VALUES(description);"

# Capture role IDs
ROLE_ADMIN_ID="$("${MYSQL_BASE_CMD[@]}" -N -e "SELECT id FROM roles WHERE org_id=${ORG_ID} AND name='admin' LIMIT 1;")"
ROLE_MEMBER_ID="$("${MYSQL_BASE_CMD[@]}" -N -e "SELECT id FROM roles WHERE org_id=${ORG_ID} AND name='member' LIMIT 1;")"

# Map role_permissions (ignore duplicates)
if [[ -n "${ROLE_ADMIN_ID}" && -n "${PERM_READ_ID}" ]]; then
  "${MYSQL_BASE_CMD[@]}" -e "INSERT IGNORE INTO role_permissions (role_id, permission_id) VALUES (${ROLE_ADMIN_ID}, ${PERM_READ_ID});"
fi
if [[ -n "${ROLE_ADMIN_ID}" && -n "${PERM_WRITE_ID}" ]]; then
  "${MYSQL_BASE_CMD[@]}" -e "INSERT IGNORE INTO role_permissions (role_id, permission_id) VALUES (${ROLE_ADMIN_ID}, ${PERM_WRITE_ID});"
fi
if [[ -n "${ROLE_ADMIN_ID}" && -n "${PERM_ROLE_MGMT_ID}" ]]; then
  "${MYSQL_BASE_CMD[@]}" -e "INSERT IGNORE INTO role_permissions (role_id, permission_id) VALUES (${ROLE_ADMIN_ID}, ${PERM_ROLE_MGMT_ID});"
fi
if [[ -n "${ROLE_MEMBER_ID}" && -n "${PERM_READ_ID}" ]]; then
  "${MYSQL_BASE_CMD[@]}" -e "INSERT IGNORE INTO role_permissions (role_id, permission_id) VALUES (${ROLE_MEMBER_ID}, ${PERM_READ_ID});"
fi

# Insert admin user (upsert by org+email)
"${MYSQL_BASE_CMD[@]}" -e "INSERT INTO users (org_id, email, password_hash, is_active) VALUES (${ORG_ID}, '${ADMIN_EMAIL}', '${ADMIN_PW_HASH}', 1) ON DUPLICATE KEY UPDATE password_hash=VALUES(password_hash), is_active=VALUES(is_active);"

# Capture user_id
USER_ID="$("${MYSQL_BASE_CMD[@]}" -N -e "SELECT id FROM users WHERE org_id=${ORG_ID} AND email='${ADMIN_EMAIL}' LIMIT 1;")"
if [[ -z "${USER_ID}" ]]; then
  echo "Error: Failed to fetch admin user id."
  exit 1
fi

# Assign roles to user (ignore duplicates)
if [[ -n "${USER_ID}" && -n "${ROLE_ADMIN_ID}" ]]; then
  "${MYSQL_BASE_CMD[@]}" -e "INSERT IGNORE INTO user_roles (user_id, role_id) VALUES (${USER_ID}, ${ROLE_ADMIN_ID});"
fi

echo "Seed data applied successfully."
