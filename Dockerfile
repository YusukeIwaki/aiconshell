# syntax=docker/dockerfile:1

# aiconshell runtime image.
#
# Targets:
#   app           - Rails web / Solid Queue workers without AI CLIs.
#                   Missing AI credentials or binaries never block this image.
#   ai            - `app` plus Node.js, git, and the Claude/Codex/Muse
#                   subscription CLIs (pinned, overridable versions).
#                   Muse is the official public native Linux artifact
#                   (pinned version + per-arch SHA256, verified at build
#                   time). No build-time login, API key, or auth cache is
#                   needed. Auth credentials always stay outside the image
#                   (mounted volumes, never baked in).
#   runtime       - Final target, selects app by default; build arg
#                   RUNTIME_TARGET=ai selects the CLI image for Railway.
#
#   docker build -t aiconshell:app .
#   docker build --target ai -t aiconshell:ai .
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

# Precompile assets for production without requiring real secrets. The
# build-time Rails boot runs WorkflowSettings.validate!, which requires
# AICONSHELL_EXECUTION_ROOT in production, so point it at a dummy path
# that is never used at runtime (validate! only reads the string; the real
# root comes from the runtime environment and its persisted volume).
RUN SECRET_KEY_BASE_DUMMY=1 AICONSHELL_EXECUTION_ROOT=/tmp/aiconshell-build-root ./bin/rails assets:precompile

# CLI-enabled worker image. Select with --target ai or RUNTIME_TARGET=ai.
FROM base AS ai

# Pinned, overridable toolchain. Verify replacements at:
#   https://nodejs.org/dist/ (v${NODE_VERSION} linux x64+arm64 tarballs)
#   https://registry.npmjs.org/@anthropic-ai%2fclaude-code
#   https://registry.npmjs.org/@openai%2fcodex
#   https://api.meta.ai/muse-code/channels/muse-stable (MUSE_VERSION + per-arch SHA256)
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

# Muse CLI: pinned native Linux binary from the official public
# distribution (same channel manifest as
# https://api.meta.ai/muse-code/channels/muse-stable).
# No build-time login, API key, or auth cache: the artifact URL is public
# and unauthenticated. This pins the binary itself (not the auto-updating
# launcher) and verifies the per-arch SHA256 before install. Bump
# MUSE_VERSION together with both MUSE_SHA256_* digests. Never commit the
# binary or credentials into the repository.
ARG MUSE_VERSION=1.4.0-R4302.1
ARG MUSE_SHA256_AMD64=ad21c22965f8600b4473b4ab8354ff7cc483d4cb681b46f2952561d855c8ed86
ARG MUSE_SHA256_ARM64=79cfba1b9e417b370bdb9154a546c524b7f32a34026e6164b6f3f122f0ea3386
RUN set -e; \
    case "${TARGETARCH:-amd64}" in \
      amd64) MUSE_ARTIFACT=muse-x86-linux; MUSE_SHA256=${MUSE_SHA256_AMD64} ;; \
      arm64) MUSE_ARTIFACT=muse-aarch64-linux; MUSE_SHA256=${MUSE_SHA256_ARM64} ;; \
      *) echo "unsupported TARGETARCH for muse: ${TARGETARCH:-<unset>}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --proto '=https' --proto-redir '=https' \
      --connect-timeout 15 --max-time 600 --retry 2 \
      "https://lookaside.facebook.com/lookaside/muse/download/?channel=muse&version=${MUSE_VERSION}&file=${MUSE_ARTIFACT}" \
      -o /tmp/muse; \
    echo "${MUSE_SHA256}  /tmp/muse" | sha256sum -c -; \
    install -m 0755 /tmp/muse /usr/local/bin/muse; \
    rm -f /tmp/muse; \
    muse --version

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
