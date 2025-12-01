#!/bin/sh
# Alpine-based image uses /bin/sh (busybox ash), not bash
set -e

# Set default backend URL if not provided (host:port format, no protocol)
export BACKEND_URL="${BACKEND_URL:-backend:8000}"

echo "Configuring nginx with BACKEND_URL: ${BACKEND_URL}"

# Substitute environment variables in nginx config template
# Only substitute BACKEND_URL, preserve nginx variables like $http_upgrade
envsubst '${BACKEND_URL}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Validate the generated nginx configuration before starting
echo "Validating nginx configuration..."
if ! nginx -t -c /etc/nginx/nginx.conf; then
    echo "ERROR: nginx configuration validation failed" >&2
    exit 1
fi

# Execute the main command (nginx)
exec "$@"
