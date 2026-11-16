FROM quay.io/coreos/etcd:v3.5.21 AS etcd
FROM python:3.12.11-slim-bookworm
RUN pip install --no-cache-dir 'psycopg[binary]==3.2.10'
# Background jobs in /ha/app/scheduler.sh coordinate through etcd.
COPY --from=etcd /usr/local/bin/etcdctl /usr/local/bin/
COPY app.py /srv/app.py
CMD ["python3", "-u", "/srv/app.py"]
