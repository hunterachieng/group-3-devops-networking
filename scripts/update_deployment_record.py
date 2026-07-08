#!/usr/bin/env python3
"""Rewrite the deployment record block in README.md between the
DEPLOYMENT_RECORD markers with real values from a CI run.

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


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--commit", required=True, help="full 40-char commit hash")
    p.add_argument("--tag", required=True, help="e.g. sha-a1b2c3d")
    p.add_argument("--run-url", required=True)
    p.add_argument("--dockerhub-username", required=True)
    p.add_argument("--app-name", required=True)
    args = p.parse_args()

    text = README.read_text()
    if START not in text or END not in text:
        print("ERROR: markers not found in README.md", file=sys.stderr)
        return 1

    pattern = re.compile(re.escape(START) + r".*?" + re.escape(END), re.DOTALL)
    new_block = build_block(
        args.commit, args.tag, args.run_url,
        args.dockerhub_username, args.app_name,
    )
    updated = pattern.sub(new_block, text, count=1)

    if updated == text:
        print("No change needed.")
        return 0

    README.write_text(updated)
    print(f"Updated {README} with commit {args.commit[:7]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())