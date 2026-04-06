# HTTP API Reference

The ztick HTTP API provides a RESTful interface for managing scheduled jobs and rules. This is an optional interface that runs alongside the native TCP protocol.

## OpenAPI Specification

The complete API contract is defined in **[openapi.yaml](../../openapi.yaml)** at the repository root, written in OpenAPI v3.1.1 format. You can import this specification into:

- **Swagger Editor** — https://editor.swagger.io/ (paste the raw YAML)
- **Postman** — File → Import → paste `openapi.yaml`
- **Code generation tools** — Generate client SDKs in your language
- **API documentation tools** — Swagger UI, ReDoc, etc.

## Server Configuration

The HTTP API listens on a separate port from the native TCP protocol:

```toml
[controller]
listen = "127.0.0.1:5680"     # HTTP API port (separate from TCP)
```

## Authentication

All API endpoints require Bearer token authentication, configurable via the `auth_file`:

```bash
# Request with token
curl -H "Authorization: Bearer YOUR_TOKEN" http://127.0.0.1:5680/jobs
```

The `/health` and `/openapi.json` endpoints do not require authentication.

## Core Endpoints

### Jobs (CRUD)

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `PUT` | `/jobs/{id}` | Create or update a job |
| `GET` | `/jobs/{id}` | Retrieve a specific job |
| `DELETE` | `/jobs/{id}` | Delete a job |
| `GET` | `/jobs?prefix=<string>` | List jobs matching a prefix |

**Example: Create a job**

```bash
curl -X PUT http://127.0.0.1:5680/jobs/deploy.v1 \
  -H "Authorization: Bearer token123" \
  -H "Content-Type: application/json" \
  -d '{
    "execution": "2026-04-10T12:00:00Z"
  }'
```

**Response:**
```json
{
  "id": "deploy.v1",
  "status": "planned",
  "execution": 1744286400000000000
}
```

### Rules (CRUD)

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `PUT` | `/rules/{id}` | Create or update a rule |
| `DELETE` | `/rules/{id}` | Delete a rule |
| `GET` | `/rules?prefix=<string>` | List rules matching a prefix |

**Example: Create a rule**

```bash
curl -X PUT http://127.0.0.1:5680/rules/notify-slack \
  -H "Authorization: Bearer token123" \
  -H "Content-Type: application/json" \
  -d '{
    "pattern": "deploy.",
    "runner": {
      "type": "direct",
      "executable": "/usr/bin/curl",
      "args": ["-X", "POST", "https://hooks.slack.com/..."]
    }
  }'
```

### Health & Discovery

| Endpoint | Purpose | Auth Required |
|----------|---------|----------------|
| `GET /health` | Server health check | No |
| `GET /openapi.json` | OpenAPI specification as JSON | No |

**Example: Check health**

```bash
curl http://127.0.0.1:5680/health
```

**Response:**
```json
{
  "status": "ok"
}
```

## Runner Types

The API supports three runner types for rule execution:

### Shell Runner

Execute a shell command (requires shell configured in `[shell]` section):

```json
{
  "type": "shell",
  "command": "/usr/bin/notify --channel ops"
}
```

### Direct Runner

Execute a binary directly without shell invocation (safer, more predictable):

```json
{
  "type": "direct",
  "executable": "/usr/bin/curl",
  "args": ["-s", "http://example.com/webhook"]
}
```

### AWF Runner

Execute an AWF (AI Workflow) via the `awf` CLI. Useful for automating AI agent pipelines on a schedule:

```json
{
  "pattern": "code-review.",
  "runner": "awf",
  "args": ["code-review"]
}
```

With optional input parameters (key=value pairs passed via `--input` flags):

```json
{
  "pattern": "report.",
  "runner": "awf",
  "args": ["generate-report", "--input", "format=pdf", "--input", "target=main"]
}
```

Spawns `awf run <workflow>` (or `awf run <workflow> --input key1=value1 --input key2=value2` when inputs are provided). Requires the `awf` CLI binary in `$PATH`.

## Error Responses

All error responses follow this format:

```json
{
  "error": "human-readable error message"
}
```

Common HTTP status codes:

| Status | Scenario |
|--------|----------|
| `200 OK` | Success |
| `400 Bad Request` | Invalid request body (malformed JSON, missing required fields) |
| `404 Not Found` | Job or rule does not exist |
| `500 Internal Server Error` | Server error |

## Timestamp Format

Job execution timestamps are specified as **ISO 8601 strings** in requests:

```json
{
  "execution": "2026-04-10T12:00:00Z"
}
```

In responses, timestamps are represented as **nanoseconds since Unix epoch**:

```json
{
  "execution": 1744286400000000000
}
```

## See Also

- [TCP Protocol Reference](protocol.md) — Native binary protocol
- [Data Types](types.md) — Job, Rule, and Runner structures
- [Configuration](configuration.md) — Server setup
