#!/usr/bin/env -S uv run --quiet --script
# /// script
# dependencies = []
# ///

import json
import subprocess
import sys
import time
from datetime import datetime

REPO = "patjlm/gitops-promoter-example"
BRANCH = "argocd-notifications-example"

# Track last printed state per (sha, check_run_name)
# When HEAD changes, we drop old commits to avoid memory bloat
last_state = {}  # (sha, name) -> (status, conclusion, title)
current_sha = None

print(f"Watching check runs for {REPO} on {BRANCH}...", file=sys.stderr)

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
                # Keep only check runs for the new commit
                last_state = {k: v for k, v in last_state.items() if k[0] == sha}
            current_sha = sha

        # Get all check runs for this commit
        result = subprocess.run(
            ["gh", "api", f"repos/{REPO}/commits/{sha}/check-runs", "--jq", ".check_runs[]"],
            capture_output=True,
            text=True,
            check=True
        )

        for line in result.stdout.strip().split('\n'):
            if not line:
                continue

            check_run = json.loads(line)
            name = check_run['name']
            status = check_run['status']
            conclusion = check_run.get('conclusion') or ''
            title = check_run.get('output', {}).get('title') or ''

            key = (sha, name)
            current_state_tuple = (status, conclusion, title)

            # Only print if state changed from last printed
            if last_state.get(key) != current_state_tuple:
                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

                # Format status line
                if status == 'completed':
                    state_str = f"{status}:{conclusion}"
                else:
                    state_str = status

                print(f"[{timestamp}] {short_sha} | {name} | {state_str} | {title}")
                last_state[key] = current_state_tuple

    except subprocess.CalledProcessError:
        pass  # Ignore API errors, retry next iteration
    except KeyboardInterrupt:
        break

    time.sleep(5)
