FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends goaccess python3 ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*
WORKDIR /test
