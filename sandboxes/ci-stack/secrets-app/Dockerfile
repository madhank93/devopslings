# Runtime for module 16's services. Each lesson mounts its own script; this
# image only carries the Postgres driver they share.
FROM python:3.12-slim
RUN pip install --no-cache-dir 'psycopg[binary]==3.3.5'
WORKDIR /app
