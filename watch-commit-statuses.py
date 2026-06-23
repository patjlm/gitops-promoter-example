#!/usr/bin/env -S uv run --quiet --script
# /// script
# dependencies = ["requests"]
# ///

import json
import subprocess
import sys
import time
from datetime import datetime

REPO = "patjlm/gitops-promoter-example"
BRANCH = "argocd-notifications-example"

# Track last printed state per (sha, context)
# When HEAD changes, we drop old commits to avoid memory bloat
last_state = {}  # (sha, context) -> (state, description)
current_sha = None

print(f"Watching commit statuses for {REPO} on {BRANCH}...", file=sys.stderr)

while True:
    try:
        # Get HEAD commit SHA
        result = subprocess.run(
            ["gh", "api", f"repos/{REPO}/git/ref/heads/{BRANCH}", "--jq", ".object.sha"],
            capture_output=True,
            text=True,
            check=True
        )
        sha = result.stdout.strip()
        short_sha = sha[:7]

        # If HEAD changed, drop all old commits from memory
        if current_sha != sha:
            if current_sha is not None:
                # Keep only statuses for the new commit
                last_state = {k: v for k, v in last_state.items() if k[0] == sha}
            current_sha = sha

        # Get all statuses for this commit
        result = subprocess.run(
            ["gh", "api", f"repos/{REPO}/commits/{sha}/status", "--jq", ".statuses[]"],
            capture_output=True,
            text=True,
            check=True
        )

        for line in result.stdout.strip().split('\n'):
            if not line:
                continue

            status = json.loads(line)
            context = status['context']
            state = status['state']
            desc = status['description']

            key = (sha, context)
            current_state_tuple = (state, desc)

            # Only print if state changed from last printed
            if last_state.get(key) != current_state_tuple:
                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                print(f"[{timestamp}] {short_sha} | {context} | {state} | {desc}")
                last_state[key] = current_state_tuple

    except subprocess.CalledProcessError:
        pass  # Ignore API errors, retry next iteration
    except KeyboardInterrupt:
        break

    time.sleep(5)
