---
title: "Configuring Client Authentication"
---

Token-based client authentication restricts access to the ztick scheduler by requiring clients to authenticate before issuing commands.

## Overview

When authentication is enabled:
1. Every TCP connection must send an `AUTH <token>` command first
2. All subsequent commands are restricted to the token's assigned **namespace**
3. Identifiers (jobs, rules) outside the namespace are rejected with `ERROR`
4. Connections that don't authenticate within 5 seconds are automatically closed

When authentication is disabled (default), connections are accepted immediately and can issue any command — this maintains backward compatibility with existing deployments.

## Quick Start

### 1. Create an Auth File

Create `auth.toml` with your tokens:

```toml
[token.deploy]
secret = "sk_deploy_a1b2c3d4e5f6"
namespace = "deploy."

[token.backup]
secret = "sk_backup_x9y8z7w6v5u4"
namespace = "backup."

[token.admin]
secret = "sk_admin_top_secret"
namespace = "*"
```

Each `[token.<name>]` section defines:
- **name** — Identifier for the token (e.g., `deploy`, `backup`)
- **secret** — Authentication value sent by the client
- **namespace** — Prefix that limits which jobs/rules this token can access

### 2. Enable in Config

Add `auth_file` to your ztick config:

```toml
[controller]
listen = "127.0.0.1:5678"
auth_file = "auth.toml"
```

### 3. Restart the Server

```bash
zig build run -- -c /path/to/config.toml
```

The server now requires authentication on all connections.

## Auth File Syntax

### Token Sections

Each `[token.<name>]` defines one token:

```toml
[token.my_service]
secret = "sk_my_service_secret"
namespace = "myapp."
```

- `secret` — Any string (spaces allowed). This value is sent in the `AUTH` command
- `namespace` — A prefix that the token can access, or `"*"` for unrestricted access

### Multiple Tokens

You can have as many tokens as needed:

```toml
[token.deploy]
secret = "deploy_secret"
namespace = "deploy."

[token.backup]
secret = "backup_secret"
namespace = "backup."

[token.monitoring]
secret = "monitor_secret"
namespace = "monitoring."
```

### Wildcard Namespace

A token with `namespace = "*"` can access all jobs and rules:

```toml
[token.admin]
secret = "admin_token"
namespace = "*"
```

### Invalid Configurations

The server rejects auth files with:
- **Duplicate secrets** — Two tokens cannot share the same secret
- **Empty namespace** — `namespace = ""` is invalid (use `"*"` for unrestricted)
- **Missing fields** — Every token must have `secret` and `namespace`

Example of invalid file (will fail at startup):

```toml
# ERROR: duplicate secret
[token.service1]
secret = "shared_secret"
namespace = "svc1."

[token.service2]
secret = "shared_secret"  # Duplicate!
namespace = "svc2."
```

## Namespace Enforcement

### Namespace Prefix Matching

A token with namespace `deploy.` can access any identifier starting with `deploy.`:

```bash
# Allowed (matches "deploy.")
AUTH sk_deploy_a1b2c3d4e5f6
SET deploy.daily 2026-04-01 12:00:00    # OK
SET deploy.release.v1.2.3 2026-04-01    # OK
GET deploy.weekly                        # OK
QUERY deploy.                            # OK (filters results)

# Rejected (doesn't match "deploy.")
SET backup.daily 2026-04-01 12:00:00    # ERROR
GET app.task                             # ERROR
REMOVE monitoring.alert                  # ERROR
```

### Wildcard Access

A token with `namespace = "*"` can access all identifiers:

```bash
AUTH sk_admin_top_secret
SET deploy.daily ...     # OK
SET backup.weekly ...    # OK
QUERY monitoring.        # OK (returns all results)
RULE SET any.rule ...    # OK
```

### QUERY Filtering

When authentication is enabled, `QUERY` results are automatically filtered to the token's namespace:

```bash
# Assuming 3 jobs exist: deploy.x, backup.y, app.z

# With deploy.* token:
QUERY            # Returns only: deploy.x
QUERY deploy.    # Returns only: deploy.x
QUERY backup.    # Returns: (empty, no matches in namespace)

# With *-token:
QUERY            # Returns all: deploy.x, backup.y, app.z
QUERY backup.    # Returns only: backup.y
```

### Rule Namespace Enforcement

`RULE SET` commands are restricted by namespace on **both** the rule identifier and the rule pattern:

```bash
# With deploy.* token, these are allowed:
RULE SET deploy.rule1 deploy. shell ...   # Both ID and pattern in namespace
RULE SET rule.deploy. deploy. shell ...   # OK: pattern matches namespace

# These are rejected:
RULE SET backup.rule backup. shell ...    # ERROR: ID outside namespace
RULE SET deploy.rule backup. shell ...    # ERROR: pattern outside namespace
```

## Client Authentication

### Using socat

Authenticate and send a command:

```bash
(echo "AUTH sk_deploy_a1b2c3d4e5f6"; \
 echo "r1 SET deploy.daily 2026-04-01 12:00:00") | \
socat - TCP:localhost:5678

# Output:
# OK
# r1 OK
```

### Using Python

```python
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('localhost', 5678))

# Authenticate
sock.send(b'AUTH sk_deploy_a1b2c3d4e5f6\n')
response = sock.recv(1024).decode()
print(f"Auth: {response}")  # Auth: OK

# Send a command
sock.send(b'r1 SET deploy.job.1 2026-04-01 12:00:00\n')
response = sock.recv(1024).decode()
print(f"Set: {response}")  # Set: r1 OK

sock.close()
```

### Using Bash

```bash
# Simple bash TCP connection
exec 3<>/dev/tcp/localhost/5678

# Authenticate
echo "AUTH sk_deploy_a1b2c3d4e5f6" >&3
read -t 2 response <&3
echo "Auth response: $response"

# Send a command
echo "r1 SET deploy.daily 2026-04-01 12:00:00" >&3
read -t 2 response <&3
echo "Command response: $response"

exec 3>&-
```

## Security Considerations

### Plaintext Tokens

By default, tokens are transmitted over unencrypted TCP. **Always use TLS in production**:

```toml
[controller]
listen = "127.0.0.1:5679"
tls_cert = "/path/to/cert.pem"
tls_key = "/path/to/key.pem"
auth_file = "auth.toml"
```

### File Permissions

Restrict the auth file to prevent unauthorized access:

```bash
# Readable only by the ztick process owner
chmod 600 auth.toml
```

### Token Rotation

To change a token:
1. Edit the auth file with a new secret
2. Restart the ztick server
3. Update clients with the new secret

Note: There is no hot-reload of the auth file — a server restart is required for changes to take effect.

## Troubleshooting

### "Connection closed" on AUTH

**Symptom**: Connection closes after AUTH command

**Causes:**
- Incorrect secret — The provided secret doesn't match any token in the auth file
- Auth file not configured — Check that `auth_file` is set in the config
- Auth timeout — 5 seconds passed before AUTH was sent

**Fix**: Verify the secret matches the auth file and try again:

```bash
# Check auth.toml for the correct secret
grep "secret" auth.toml

# Test the token
(echo "AUTH sk_correct_secret"; sleep 1) | socat - TCP:localhost:5678
```

### "ERROR" response on a command

**Symptom**: Command is rejected with `ERROR` after successful AUTH

**Causes:**
- Identifier outside namespace — The job/rule identifier doesn't match the token's namespace prefix

**Fix**: Check that the identifier starts with the namespace:

```bash
# Token namespace is "deploy.", so these work:
echo "r1 SET deploy.daily 2026-04-01 12:00:00" | socat - TCP:localhost:5678

# This fails:
echo "r1 SET backup.daily 2026-04-01 12:00:00" | socat - TCP:localhost:5678
```

## Disabling Authentication

To disable authentication:
1. Remove or comment out the `auth_file` line in the config
2. Restart the server

Clients can then issue commands directly without AUTH.

## Examples

### Multi-Tenant Setup

Separate services with isolated namespaces:

```toml
[token.billing]
secret = "sk_billing_abc123"
namespace = "billing."

[token.shipping]
secret = "sk_shipping_def456"
namespace = "shipping."

[token.inventory]
secret = "sk_inventory_ghi789"
namespace = "inventory."
```

Each service authenticates with its own secret and can only access jobs/rules with its namespace prefix.

### Admin Token

Unrestricted access for administrative operations:

```toml
[token.admin]
secret = "sk_admin_zzz999"
namespace = "*"
```

### Environment-Based Secrets

Use environment variables in your deployment script:

```bash
# Inject token from env var into config
cat > auth.toml << EOF
[token.app]
secret = "${ZTICK_TOKEN}"
namespace = "app."
EOF

zig build run -- -c config.toml
```
