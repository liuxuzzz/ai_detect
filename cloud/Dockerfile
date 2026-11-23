FROM node:22-alpine AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web ./
RUN npm run build

FROM rust:1.88-bookworm AS server
WORKDIR /server
COPY server/Cargo.toml server/Cargo.lock ./
COPY server/src ./src
COPY server/config ./config
COPY server/migrations ./migrations
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=server /server/target/release/aijiance-cloud /usr/local/bin/aijiance-cloud
COPY --from=web /web/dist ./static
ENV APP_ENV=prod
ENV RUST_LOG=info
EXPOSE 6600
CMD ["aijiance-cloud"]
