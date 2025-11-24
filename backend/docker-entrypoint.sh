#!/bin/sh
set -e

# 1. Hydrate volume if empty (Running as root)
if [ ! -f "/app/prisma/schema.prisma" ]; then
    echo "Mount is empty. Hydrating /app/prisma..."
    cp -R /app/prisma_template/. /app/prisma/
else
    # Volume exists but may be missing new migrations from an upgrade
    # Always sync schema and migrations from template to ensure upgrades work
    echo "Syncing schema and migrations from template..."
    cp /app/prisma_template/schema.prisma /app/prisma/schema.prisma
    cp -R /app/prisma_template/migrations/. /app/prisma/migrations/
fi

# 2. Fix permissions unconditionally (Running as root)
echo "Fixing filesystem permissions..."
chown -R nodejs:nodejs /app/uploads
chown -R nodejs:nodejs /app/prisma
chmod 755 /app/uploads

# Ensure database file has proper permissions
if [ -f "/app/prisma/dev.db" ]; then
    echo "Database file found, ensuring write permissions..."
    chmod 666 /app/prisma/dev.db
fi

# 3. Run Migrations (Drop privileges to nodejs)
echo "Running database migrations..."
su-exec nodejs npx prisma migrate deploy

# 4. Start Application (Drop privileges to nodejs)
echo "Starting application as nodejs..."
exec su-exec nodejs node dist/index.js
