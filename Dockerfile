# syntax=docker/dockerfile:1
FROM elixir:1.19-alpine AS build

ARG MIX_ENV=prod

ENV MIX_ENV=$MIX_ENV \
    MIX_HOME=/app/.mix \
    HEX_HOME=/app/.hex \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LC_CTYPE=C.UTF-8

RUN apk add --no-cache \
    git \
    make \
    build-base \
    rust \
    cargo

WORKDIR /app
COPY --exclude=entrypoint.sh . .

# Install dependencies at the versions recorded in mix.lock.
RUN mkdir -p /app/.mix /app/.hex && \
    mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get

RUN export SKIP_RUNTIME_CONFIG=1 && \
    mix assets.setup && \
    mix compile && \
    mix assets.deploy && \
    cd deps/eda/native/eda_dave && \
    cargo build --release && \
    mkdir -p /app/_build/${MIX_ENV}/lib/eda/priv/native && \
    cp target/release/libeda_dave.so /app/_build/${MIX_ENV}/lib/eda/priv/native/eda_dave.so

FROM elixir:1.19-alpine

ENV MIX_ENV=prod \
    MIX_HOME=/app/.mix \
    HEX_HOME=/app/.hex \
    HOME=/app \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LC_CTYPE=C.UTF-8

RUN apk add --no-cache \
    ffmpeg \
    git \
    libstdc++

WORKDIR /app
COPY --from=build /app .
COPY entrypoint.sh /app
# A private build checkout can supply mode-600 files and mode-700 directories.
# Make the packaged public source and build artifacts readable by non-root users.
RUN chmod -R a+rX /app && chmod 0755 /app/entrypoint.sh

VOLUME ["/app/priv/static/uploads"]
EXPOSE 4000
ENTRYPOINT ["/app/entrypoint.sh"]
