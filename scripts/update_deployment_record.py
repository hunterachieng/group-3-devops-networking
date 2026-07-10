#!/usr/bin/env python3
"""Rewrite the deployment record block in README.md between the
DEPLOYMENT_RECORD markers with real values from a CI run, and refresh the
copy-pasteable deploy/verify commands between the DEPLOYMENT_COMMANDS markers
so they reference the exact image tag that was just published.

Usage:
  update_deployment_record.py --commit <full_sha> --tag <sha-xxxxxxx> \
      --run-url <url> --dockerhub-username <user> --app-name <repo>
"""
import argparse
import re
import sys
from pathlib import Path

README = Path(__file__).resolve().parent.parent / "README.md"
START = "<!-- DEPLOYMENT_RECORD:START -->"
END = "<!-- DEPLOYMENT_RECORD:END -->"
CMD_START = "<!-- DEPLOYMENT_COMMANDS:START -->"
CMD_END = "<!-- DEPLOYMENT_COMMANDS:END -->"


def build_block(commit: str, tag: str, run_url: str, user: str, app: str) -> str:
    return f"""{START}
| Field | Value |
|---|---|
| Commit | [`{commit}`]({run_url.rsplit('/actions/', 1)[0]}/commit/{commit}) |
| Image tag | `{tag}` |
| Run | [{run_url.rsplit('/', 1)[-1]}]({run_url}) |

Images published to Docker Hub after each merge to `main`:

```
{user}/{app}-order:{tag}
{user}/{app}-inventory:{tag}
{user}/{app}-payment:{tag}
```
{END}"""


def build_commands_block(tag: str, user: str, app: str) -> str:
    labels_fmt = "{{json .Config.Labels}}"
    return f"""{CMD_START}
### Deploy

```bash
cp .env.example .env
export DOCKERHUB_USERNAME={user}
export APP_NAME={app}
./scripts/deploy.sh {tag}
```

### Verify after deploy

All `docker compose -f docker-compose.prod.yml` commands need three variables.
Create `.env` with the real values in one command (docker compose reads it automatically):

```bash
cat > .env <<'EOF'
IMAGE_TAG={tag}
DOCKERHUB_USERNAME={user}
APP_NAME={app}
EOF
```

```bash
# Pull images from Docker Hub
docker pull {user}/{app}-order:{tag}
docker pull {user}/{app}-inventory:{tag}
docker pull {user}/{app}-payment:{tag}
```

```bash
# Stack status
docker compose -f docker-compose.prod.yml ps

# Gateway health
curl http://localhost:8080/health

# End-to-end checkout
curl -s -X POST http://localhost:8080/checkout \\
  -H 'Content-Type: application/json' \\
  -d '{{"items":["SKU-1"],"amount":100}}' | python3 -m json.tool
```

```bash
# Verify image traceability — labels must show the commit SHA and source repo
docker image inspect {user}/{app}-order:{tag} \\
  --format '{labels_fmt}' | python3 -m json.tool
```

```bash
# Verify internal services are unreachable from the host
curl --connect-timeout 2 http://localhost:3002/health && echo "FAIL" || echo "PASS: inventory not exposed"
curl --connect-timeout 2 http://localhost:3003/health && echo "FAIL" || echo "PASS: payment not exposed"
```

```bash
# Verify containers run as non-root
docker compose -f docker-compose.prod.yml exec order whoami
# Expected: appuser
```

```bash
# Tear down
docker compose -f docker-compose.prod.yml down -v
```
{CMD_END}"""


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--commit", required=True, help="full 40-char commit hash")
    p.add_argument("--tag", required=True, help="e.g. sha-a1b2c3d")
    p.add_argument("--run-url", required=True)
    p.add_argument("--dockerhub-username", required=True)
    p.add_argument("--app-name", required=True)
    args = p.parse_args()

    text = README.read_text()
    for marker in (START, END, CMD_START, CMD_END):
        if marker not in text:
            print(f"ERROR: marker {marker} not found in README.md", file=sys.stderr)
            return 1

    updated = text
    record_pattern = re.compile(re.escape(START) + r".*?" + re.escape(END), re.DOTALL)
    updated = record_pattern.sub(
        build_block(
            args.commit, args.tag, args.run_url,
            args.dockerhub_username, args.app_name,
        ),
        updated,
        count=1,
    )

    commands_pattern = re.compile(
        re.escape(CMD_START) + r".*?" + re.escape(CMD_END), re.DOTALL
    )
    updated = commands_pattern.sub(
        build_commands_block(args.tag, args.dockerhub_username, args.app_name),
        updated,
        count=1,
    )

    if updated == text:
        print("No change needed.")
        return 0

    README.write_text(updated)
    print(f"Updated {README} with commit {args.commit[:7]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
