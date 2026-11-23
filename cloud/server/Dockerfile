FROM rust:1.88-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY config ./config
COPY migrations ./migrations
RUN cargo build --release --locked
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /src/target/release/aijiance-cloud /usr/local/bin/aijiance-cloud
ENV APP_ENV=prod
ENV RUST_LOG=info
EXPOSE 6601
CMD ["aijiance-cloud"]
