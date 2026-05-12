# Custom Postgres image with init.sql baked in.
# Used for ECS where we can't volume-mount files from the host.
#
# The base postgres image runs any .sql / .sh file in /docker-entrypoint-initdb.d/
# on first startup (when PGDATA is empty). On subsequent starts, the directory
# is ignored (data already exists). That's the documented behavior.
#
# Build for ARM64 to match our Graviton ECS hosts:
#   docker buildx build --platform linux/arm64 -t <ecr-url>:latest --push .

FROM postgres:16-alpine

# Copy the init script into the auto-run directory.
COPY init.sql /docker-entrypoint-initdb.d/init.sql
