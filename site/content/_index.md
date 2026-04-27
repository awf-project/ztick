---
title: "ztick — Push-Driven Job Scheduler in Zig"
description: "A time-based job scheduler with hexagonal architecture, explicit memory management, and minimal dependencies."
lead: "Your application decides when to schedule. ztick faithfully executes."
date: 2026-04-27
draft: false
---

## Why ztick?

Periodic schedulers (cron, systemd timers) trigger work at fixed intervals regardless of the target system's state. When load is already high, they make it worse.

ztick inverts this logic: the application decides when to schedule a job based on its own state. It sends a `SET` command over TCP at the moment it sees fit, and ztick faithfully executes it at the requested time.

This is an **explicit push model** — the application drives, ztick executes.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/awf-project/ztick/main/scripts/install.sh | sh
```

Or build from source:

```bash
git clone https://github.com/awf-project/ztick.git
cd ztick
make build
```

## Quick Start

Run the server with default settings:

```bash
zig build run
```

Schedule a job over TCP:

```bash
echo "SET deploy.daily $(date +%s%N -d 'tomorrow 03:00')" | nc 127.0.0.1 5678
```

Or define a rule that matches a job prefix and runs a shell command:

```bash
echo 'RULE SET deploy.* deploy.* shell "/usr/local/bin/deploy.sh"' | nc 127.0.0.1 5678
```
