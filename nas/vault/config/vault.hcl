ui = true
disable_mlock = true

listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}

storage "file" {
  path = "/vault/data"
}

# API Address for clustering
api_addr = "http://192.168.1.42:8200"