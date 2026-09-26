# syntax=docker/dockerfile:1

# aiconshell runtime image.
#
# Targets:
#   app           - Rails web / Solid Queue workers without AI CLIs.
#                   Missing AI credentials or binaries never block this image.
#   ai            - `app` plus Node.js, git, and the Claude/Codex subscription
#                   CLIs (pinned, overridable versions). The Muse CLI is an
#                   authenticated distribution: operators supply an authorized
#                   Linux binary via a BuildKit secret, and the build COPIES it
#                   into /usr/local/bin/muse intentionally. Only the secret
#                   mount itself is ephemeral (it never lands in a layer);
#                   without the secret the binary is simply absent and the
#                   provider fails at execution time. Auth credentials always
#                   stay outside the image (mounted volumes, never baked in).
#   runtime       - Final target, selects app by default; build arg
#                   RUNTIME_TARGET=ai selects the CLI image for Railway.
#
#   docker build -t aiconshell:app .
#   docker build --target ai --no-cache -t aiconshell:ai \
#     --secret id=muse_cli,src=$HOME/.cache/aiconshell/muse-cli/muse .
# (--no-cache: BuildKit caches secret-mount layers, so toggling the
# secret without it can reuse a stale layer.)
#
# See docs/deployment.md ("AI CLI provisioning") for the operator flow.

ARG RUBY_VERSION=3.4.9
ARG RUNTIME_TARGET=app
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Base packages: curl (healthchecks, ClickHouse setup), jemalloc (memory),
# postgresql-client (db diagnostics; migrations run through Rails).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development"

# Private AI auth homes. Backed by named/persisted volumes in compose and
# Railway so subscription token refresh can write without touching the image.
# The AI lane resolves these via CLAUDE_CONFIG_DIR / CODEX_HOME /
# AICONSHELL_MUSE_HOME (see lib/aiconshell/ai/config.rb); their *contents*
# (credentials) live only in the mounted volumes, never in image layers.
# /workspaces is the execution-workspace root (AICONSHELL_EXECUTION_ROOT):
# also a persisted volume at runtime, outside the application source.
# Everything is owned by uid/gid 1000 (rails) so workers can write.
RUN mkdir -p /private/claude /private/codex /private/muse /workspaces && \
    groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails /private /workspaces

# Throw-away build stage to reduce size of final images.
FROM base AS build

# Packages needed to build gems.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems.
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code.
COPY . .

# Precompile bootsnap code for faster boot times.
RUN bundle exec bootsnap precompile app/ lib/

# Precompile assets for production without requiring a real secret.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Optional CLI-enabled worker image. Select with --target ai or RUNTIME_TARGET=ai.
FROM base AS ai

# Pinned, overridable toolchain. Verify replacements at:
#   https://nodejs.org/dist/ (v${NODE_VERSION} linux x64+arm64 tarballs)
#   https://registry.npmjs.org/@anthropic-ai%2fclaude-code
#   https://registry.npmjs.org/@openai%2fcodex
ARG NODE_VERSION=24.21.0
ARG CLAUDE_CODE_VERSION=2.1.283
ARG CODEX_VERSION=0.157.1
ARG TARGETARCH

# Node.js from the official tarball (multi-arch) for the Node-based CLIs.
RUN set -e; \
    case "${TARGETARCH:-amd64}" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH:-<unset>}" >&2; exit 1 ;; \
    esac; \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y xz-utils ca-certificates git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
      -o /tmp/node.tar.xz; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1; \
    rm -f /tmp/node.tar.xz; \
    node --version && npm --version

# Subscription CLIs from their official npm packages (no API-key fallback;
# authentication happens at runtime via the mounted private volumes).
RUN npm install -g --no-audit --no-fund \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" && \
    npm cache clean --force && \
    claude --version && \
    codex --version

# Muse CLI: authenticated distribution supplied by the operator at build time.
# `install` copies the binary into /usr/local/bin/muse ON PURPOSE: the
# executable is part of the ai image. What disappears after the build is
# only the secret mount (/run/secrets/muse_cli leaves no layer behind).
# Without `--secret id=muse_cli,src=<authorized Linux binary>` the image
# still builds; `muse` is simply absent and the provider fails at execution
# time. Never commit the binary or credentials into the repository.
RUN --mount=type=secret,id=muse_cli,required=false \
    if [ -f /run/secrets/muse_cli ]; then \
      install -m 0755 /run/secrets/muse_cli /usr/local/bin/muse && \
      muse --version && \
      echo "muse CLI installed from build secret into the image"; \
    else \
      echo "muse CLI not supplied; skipping (see docs/deployment.md)"; \
    fi

# App artifacts (gems + code) shared with the default image.
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails
RUN chown -R rails:rails db log tmp

ENV AICONSHELL_CLAUDE_BIN="/usr/local/bin/claude" \
    AICONSHELL_CODEX_BIN="/usr/local/bin/codex" \
    AICONSHELL_MUSE_BIN="/usr/local/bin/muse"

USER 1000:1000

ENTRYPOINT ["/rails/script/docker-entrypoint"]
EXPOSE 3000
CMD ["./bin/jobs", "--config-file=config/queue_execution.yml", "--skip-recurring"]

# Default runtime image for web and workers.
FROM base AS app

# Built artifacts: gems, application.
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Run and own only the runtime files as a non-root user for security.
RUN chown -R rails:rails db log tmp
USER 1000:1000

# Entrypoint runs db:prepare only when AICONSHELL_RUN_DB_SETUP=1 (the
# compose `migrate` service); web and workers boot straight into their
# commands. ClickHouse schema setup is a separate one-shot service
# (`clickhouse-init`) so logging outages never block application startup.
ENTRYPOINT ["/rails/script/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime.
# Thruster and Puma both honor PORT (Railway injects it; compose sets 3000).
EXPOSE 3000
CMD ["./bin/thrust", "./bin/rails", "server"]

# Railway forwards declared service variables as Docker build arguments.
# Keep explicit app/ai targets for Compose while selecting the final target
# with the nonsecret RUNTIME_TARGET service variable on repo-backed services.
FROM ${RUNTIME_TARGET} AS runtime
