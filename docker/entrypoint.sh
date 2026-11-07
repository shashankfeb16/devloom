#!/bin/sh
set -eu

if [ "$#" -eq 2 ] && [ "$1" = "mix" ] && [ "$2" = "phx.server" ]; then
  echo "Preparing Devloom development workspace..."
  mix deps.get --check-locked
  mix assets.setup
  mix assets.build
  mix ecto.create
  mix ecto.migrate
fi

exec "$@"
