# --- Build image
FROM ruby:2.5.5-alpine3.10 as builder

# bundle install deps
RUN apk add --update ca-certificates git build-base openssl-dev
RUN gem install bundler -v '>= 2'

# bundle install
COPY . /app
RUN cd /app && bundle

# --- Runtime image
FROM ruby:2.5.5-alpine3.10

COPY --from=builder /app /app
COPY --from=builder /usr/local/bundle /usr/local/bundle

RUN apk --update upgrade && apk add --no-cache ca-certificates

RUN addgroup -g 1000 -S app \
  && adduser -u 1000 -S app -G app \
  && chown -R app: /app

USER app
WORKDIR /app
ENTRYPOINT ["./docker/entrypoint"]
