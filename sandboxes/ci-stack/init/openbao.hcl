# One node of integrated (raft) storage on a volume: a real, sealed server
# rather than dev mode, so secrets survive a restart of the container.
storage "raft" {
  path    = "/openbao/file/storage"
  node_id = "bao"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

api_addr     = "http://bao:8200"
cluster_addr = "http://127.0.0.1:8201"
ui           = true
