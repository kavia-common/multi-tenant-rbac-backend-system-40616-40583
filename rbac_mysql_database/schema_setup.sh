#!/usr/bin/env bash
# Usage:
#   bash schema_setup.sh
# Description:
#   - Reads MySQL connection info from rbac_mysql_database/db_connection.txt
#   - Executes DDL to create multi-tenant RBAC tables
#   - IMPORTANT: Executes exactly one SQL statement per mysql -e invocation (no .sql files)
# Notes:
#   - The MySQL port is sourced from db_connection.txt; no hardcoded port in this script.
#   - Ensure MySQL server is running and db_connection.txt is present (startup.sh generates it).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [[ ! -f "${CONN_FILE}" ]]; then
  echo "Error: ${CONN_FILE} not found. Run startup.sh first to generate it."
  exit 1
fi

# Parse db_connection.txt expecting a line like:
# mysql -u appuser -pdbuser123 -h localhost -P 5000 myapp
LINE="$(cat "${CONN_FILE}" | tr -d '\r' | xargs)"
if [[ -z "${LINE}" ]]; then
  echo "Error: db_connection.txt is empty."
  exit 1
fi

# Extract connection parts
# Default values
MYSQL_USER=""
MYSQL_PASS=""
MYSQL_HOST="localhost"
MYSQL_PORT=""
MYSQL_DB=""

read -ra PARTS <<< "${LINE}"
for (( i=0; i<${#PARTS[@]}; i++ )); do
  token="${PARTS[$i]}"
  case "${token}" in
    -u)
      MYSQL_USER="${PARTS[$((i+1))]}"
      ;;
    -u*)
      MYSQL_USER="${token#-u}"
      ;;
    -p)
      MYSQL_PASS="${PARTS[$((i+1))]}"
      ;;
    -p*)
      MYSQL_PASS="${token#-p}"
      ;;
    -h)
      MYSQL_HOST="${PARTS[$((i+1))]}"
      ;;
    -h*)
      MYSQL_HOST="${token#-h}"
      ;;
    -P)
      MYSQL_PORT="${PARTS[$((i+1))]}"
      ;;
    -P*)
      MYSQL_PORT="${token#-P}"
      ;;
    *)
      # The last token without dash could be DB name
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

echo "Applying RBAC schema to database '${MYSQL_DB}' on ${MYSQL_HOST}:${MYSQL_PORT} ..."

# Create tables (one statement per command).
# organizations
"${MYSQL_BASE_CMD[@]}" -e "CREATE TABLE IF NOT EXISTS organizations (id BIGINT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) UNIQUE NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP) ENGINE=InnoDB;"
# users
"${MYSQL_BASE_CMD[@]}" -e "CREATE TABLE IF NOT EXISTS users (id BIGINT AUTO_INCREMENT PRIMARY KEY, org_id BIGINT NOT NULL, email VARCHAR(255) NOT NULL, password_hash VARCHAR(255) NOT NULL, is_active TINYINT(1) DEFAULT 1, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, UNIQUE KEY uq_users_org_email(org_id,email), INDEX idx_users_org_email(org_id,email), CONSTRAINT fk_users_org FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE) ENGINE=InnoDB;"
# roles
"${MYSQL_BASE_CMD[@]}" -e "CREATE TABLE IF NOT EXISTS roles (id BIGINT AUTO_INCREMENT PRIMARY KEY, org_id BIGINT NOT NULL, name VARCHAR(255) NOT NULL, description TEXT NULL, UNIQUE KEY uq_roles_org_name(org_id,name), INDEX idx_roles_org_name(org_id,name), CONSTRAINT fk_roles_org FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE) ENGINE=InnoDB;"
# permissions
"${MYSQL_BASE_CMD[@]}" -e "CREATE TABLE IF NOT EXISTS permissions (id BIGINT AUTO_INCREMENT PRIMARY KEY, org_id BIGINT NOT NULL, name VARCHAR(255) NOT NULL, description TEXT NULL, UNIQUE KEY uq_permissions_org_name(org_id,name), INDEX idx_permissions_org_name(org_id,name), CONSTRAINT fk_permissions_org FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE) ENGINE=InnoDB;"
# role_permissions
"${MYSQL_BASE_CMD[@]}" -e "CREATE TABLE IF NOT EXISTS role_permissions (id BIGINT AUTO_INCREMENT PRIMARY KEY, role_id BIGINT NOT NULL, permission_id BIGINT NOT NULL, UNIQUE KEY uq_role_permission(role_id,permission_id), CONSTRAINT fk_role_permissions_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE, CONSTRAINT fk_role_permissions_permission FOREIGN KEY (permission_id) REFERENCES permissions(id) ON DELETE CASCADE) ENGINE=InnoDB;"
# user_roles
"${MYSQL_BASE_CMD[@]}" -e "CREATE TABLE IF NOT EXISTS user_roles (id BIGINT AUTO_INCREMENT PRIMARY KEY, user_id BIGINT NOT NULL, role_id BIGINT NOT NULL, UNIQUE KEY uq_user_role(user_id,role_id), CONSTRAINT fk_user_roles_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE, CONSTRAINT fk_user_roles_role FOREIGN KEY (role_id) REFERENCES roles(id) ON DELETE CASCADE) ENGINE=InnoDB;"
# audit_logs
"${MYSQL_BASE_CMD[@]}" -e "CREATE TABLE IF NOT EXISTS audit_logs (id BIGINT AUTO_INCREMENT PRIMARY KEY, org_id BIGINT NOT NULL, actor_user_id BIGINT NULL, action VARCHAR(100) NOT NULL, resource_type VARCHAR(100) NOT NULL, resource_id BIGINT NULL, metadata JSON NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, INDEX idx_audit_org_created(org_id, created_at), CONSTRAINT fk_audit_org FOREIGN KEY (org_id) REFERENCES organizations(id) ON DELETE CASCADE, CONSTRAINT fk_audit_actor FOREIGN KEY (actor_user_id) REFERENCES users(id) ON DELETE SET NULL) ENGINE=InnoDB;"

echo "Schema setup complete."
