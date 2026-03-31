# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.x.x   | :white_check_mark: |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via email to: alexandre@vanoix.com

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Resolution**: Depends on severity
  - Critical: Within 1 week
  - High: Within 2 weeks
  - Medium: Within 1 month
  - Low: Next release

### Disclosure Policy

- We follow coordinated disclosure
- Credit will be given in release notes (unless you prefer anonymity)
- We may request a CVE for critical vulnerabilities

## Security Considerations

ztick is a time-based job scheduler that executes shell commands via configured
rules. This combination introduces specific security risks:

### Operational Risks

- **Arbitrary Code Execution:** ztick executes shell commands defined in rules
  using the system shell. It runs with the same permissions as the user executing
  the binary.
- **TCP Protocol Exposure:** ztick listens on a TCP port (`127.0.0.1:5678` by
  default). Ensure the listen address is not exposed to untrusted networks
  without TLS enabled.
- **TLS Configuration:** When using TLS, ztick enforces TLS 1.3 via system
  OpenSSL. Ensure certificates are kept up to date and private keys are properly
  protected.

### Data Security

- **Persistence Files:** The append-only logfile contains all scheduled jobs and
  rules. Protect logfile access with appropriate file permissions.
- **Configuration Files:** Config files may contain file paths and network
  addresses. Treat them as sensitive and do not commit secrets.

### Safe Usage Best Practices

1. **Bind locally:** Keep the default `127.0.0.1` listen address unless TLS is
   configured.
2. **Enable TLS:** Use `tls_cert` and `tls_key` configuration for any
   non-loopback deployment.
3. **Least Privilege:** Run ztick with the minimum necessary permissions. Avoid
   running as root.
4. **File Permissions:** Restrict read/write access to logfile and config files.
5. **Keep Updated:** Keep ztick and its dependencies updated to the latest
   version.

## Security Updates

Subscribe to security advisories:
- Watch this repository (Releases only)
- Check [GitHub Security Advisories](https://github.com/awf-project/ztick/security/advisories)
