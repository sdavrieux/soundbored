#!/bin/sh
set -eu

# Run migrations
echo "Running database migrations..."
mix ecto.migrate --no-compile

# Start Phoenix server in foreground
# Using exec ensures proper signal handling and process management
echo "Starting Phoenix server..."
exec mix phx.server --no-compile
