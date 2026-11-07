# Development image. The manifest digest supports both ARM64 and AMD64.
FROM elixir:1.19.7-otp-28-slim@sha256:b0082436839969c6eac09ee99515980322d8ecadd302ff7b9fd6547aa24cddf9

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ca-certificates curl inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Leave MIX_ENV unset: Mix defaults to dev and automatically selects test for tests.
ENV HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt

RUN mix local.hex --force && mix local.rebar --force
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get --check-locked
COPY config ./config
RUN mix deps.compile
COPY . .
RUN mix assets.setup && mix compile --warnings-as-errors && mix assets.build

# Keep this outside the source mount so Windows cannot mask executable permissions.
COPY docker/entrypoint.sh /usr/local/bin/devloom-entrypoint
RUN chmod +x /usr/local/bin/devloom-entrypoint

EXPOSE 4000
ENTRYPOINT ["devloom-entrypoint"]
CMD ["mix", "phx.server"]
