# The official etcd image has no shell, and a member's flags have to be
# changeable without editing compose: replacing a member means restarting it
# with different ones. So: the same binaries, plus a small wrapper.
FROM quay.io/coreos/etcd:v3.5.21 AS etcd
FROM debian:12.12-slim
COPY --from=etcd /usr/local/bin/etcd /usr/local/bin/etcdctl /usr/local/bin/etcdutl /usr/local/bin/
COPY run-etcd.sh /usr/local/bin/run-etcd
ENTRYPOINT ["/usr/local/bin/run-etcd"]
