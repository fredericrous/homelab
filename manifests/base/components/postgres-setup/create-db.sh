#!/bin/sh
set -e

echo "🗄️  Setting up PostgreSQL database for ${APP_NAME}..."

# Install PostgreSQL client
apk add --no-cache postgresql-client

export VAULT_TOKEN=$(cat /vault-token/token)

# Get credentials from Vault
echo "Getting database credentials from Vault..."
vault status || { echo "Failed to connect to vault"; exit 1; }

DB_CREDS=$(vault kv get -format=json secret/${APP_NAME}/postgres 2>/dev/null || echo "{}")

if [ "$DB_CREDS" = "{}" ] || [ -z "$DB_CREDS" ]; then
  echo "No existing credentials in Vault, creating new ones..."
  DB_USER="${APP_NAME}"
  DB_PASS=$(head -c 16 /dev/urandom | base64 | tr -d "=+/")
  
  # Store in Vault for future use
  vault kv put secret/${APP_NAME}/postgres \
    username="$DB_USER" \
    password="$DB_PASS"
else
  DB_USER=$(echo "$DB_CREDS" | grep -o '"username":"[^"]*' | grep -o '[^"]*$')
  DB_PASS=$(echo "$DB_CREDS" | grep -o '"password":"[^"]*' | grep -o '[^"]*$')
fi

echo "Using database user: $DB_USER"

# Wait for PostgreSQL to be ready
until pg_isready -h "$PGHOST" -p 5432; do
  echo "Waiting for PostgreSQL to be ready..."
  sleep 5
done

# Check if database exists
if psql -lqt | cut -d \| -f 1 | grep -qw "${APP_NAME}"; then
  echo "✅ Database ${APP_NAME} already exists"
else
  echo "Creating database ${APP_NAME}..."
  psql <<EOF
CREATE USER "$DB_USER" WITH PASSWORD '$DB_PASS';
CREATE DATABASE "${APP_NAME}" OWNER "$DB_USER";
GRANT ALL PRIVILEGES ON DATABASE "${APP_NAME}" TO "$DB_USER";
EOF
  echo "✅ Database ${APP_NAME} created"
fi