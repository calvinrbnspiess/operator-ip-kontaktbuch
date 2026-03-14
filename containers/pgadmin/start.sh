#!/bin/sh

echo "10.5.0.4:5432:*:${POSTGRES_USER}:${POSTGRES_PASSWORD}" > /pgpass
chmod 600 //pgpass

cat <<EOF > /pgadmin4/servers.json
{
  "Servers": {
    "1": {
      "Group": "Servers",
      "Name": "Local Database",
      "Host": "postgres",
      "Port": 5432,
      "MaintenanceDB": "${POSTGRES_DB}",
      "Username": "${POSTGRES_USER}",
      "PassFile": "/pgpass",
      "SSLMode": "prefer",
      "Shared": true
    }
  }
}
EOF

exec /entrypoint.sh