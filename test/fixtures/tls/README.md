# TLS Test Fixtures

Self-signed certificates for development and testing. The `.pem` files are git-ignored and must be generated locally.

## Generate

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -keyout test/fixtures/tls/key.pem -out test/fixtures/tls/cert.pem \
  -days 3650 -nodes -subj "/CN=localhost"
```

This creates:
- `cert.pem` — Self-signed certificate (valid 10 years)
- `key.pem` — Unencrypted private key (EC P-256)

## Usage

Point your TLS config to these files:

```toml
[controller]
listen = "127.0.0.1:5679"
tls_cert = "test/fixtures/tls/cert.pem"
tls_key = "test/fixtures/tls/key.pem"
```

These certificates are for local development only. Use properly issued certificates in production.
