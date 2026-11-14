# syntax=docker/dockerfile:1
# check=error=true

# Default target remains the immutable Mac/AWS production image.
# Local editing uses the explicit development target via bin/dev-docker.
# For standalone Docker use:
# docker build -t quickflow .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name quickflow quickflow

# compose.yaml uses this image for normal operation and bypasses automatic db:prepare.

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim@sha256:58479f164d5947f852da27a4436c89bb986a811f959c40552bc7f6ccaabcc9c9 AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Opt-in local development target. The final/default target below stays production.
FROM base AS development
ENV RAILS_ENV="development" BUNDLE_DEPLOYMENT="0" BUNDLE_WITHOUT=""
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libffi-dev libpq-dev libyaml-dev pkg-config unzip nodejs procps && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
COPY bin/install-qpdf bin/install-qpdf
RUN bin/install-qpdf && cp -a vendor/qpdf /opt/quickflow-qpdf
COPY Gemfile Gemfile.lock ./
RUN bundle install
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
RUN mkdir -p /rails/tmp /rails/log /rails/storage /rails/public/assets /rails/vendor/qpdf && \
    chown -R rails:rails /rails
USER 1000:1000
EXPOSE 80

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libffi-dev libpq-dev libvips libyaml-dev pkg-config unzip && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY bin/install-qpdf bin/install-qpdf
RUN bin/install-qpdf
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
