# check=skip=InvalidDefaultArgInFrom

# Versions are supplied by the generated Compose build arguments.
ARG RUBY_VERSION
FROM ruby:${RUBY_VERSION}-slim-bookworm@sha256:a0636a941ef86063f17b343f6c96f271f8eeedd76febf035bb6d57bc5024682b AS builder

ARG RSPEC_VERSION
ARG AIRBORNE_VERSION
RUN gem install rspec --version "${RSPEC_VERSION}" --no-document \
  && gem install airborne --version "${AIRBORNE_VERSION}" --no-document

FROM ruby:${RUBY_VERSION}-slim-bookworm@sha256:a0636a941ef86063f17b343f6c96f271f8eeedd76febf035bb6d57bc5024682b
COPY --from=builder /usr/local/bundle /usr/local/bundle
ENV GEM_HOME=/usr/local/bundle
ENV PATH=/usr/local/bundle/bin:$PATH

WORKDIR /app
COPY spec ./spec
COPY fixtures ./fixtures
CMD ["rspec"]
