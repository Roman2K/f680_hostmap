# --- Build image
FROM ruby:2.7.1-alpine3.11 as builder
WORKDIR /app

# bundle install deps
RUN apk add --update ca-certificates git build-base openssl-dev
RUN gem install bundler -v '>= 2'

# bundle install
COPY Gemfile* ./
RUN bundle

# --- Runtime image
FROM ruby:2.7.1-alpine3.11
WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
RUN apk --update upgrade && apk add --no-cache ca-certificates

COPY . .
RUN addgroup -g 122 -S docker
RUN addgroup -g 1000 -S app \
  && adduser -u 1000 -S app -G app \
  && addgroup app docker \
  && chown -R app: .

USER app
ENTRYPOINT ["./docker/entrypoint"]
