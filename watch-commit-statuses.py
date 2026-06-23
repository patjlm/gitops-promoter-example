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

# Track last printed state per context
# Maps context -> (sha, state, description)
# This way we print whenever an app changes commit OR status
last_state = {}  # context -> (sha, state, description)

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
            desc = status['description'].strip()  # Remove trailing newlines

            current_state_tuple = (sha, state, desc)

            # Print if this context changed (different commit OR different state)
            if last_state.get(context) != current_state_tuple:
                timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                print(f"[{timestamp}] {short_sha} | {context} | {state} | {desc}")
                sys.stdout.flush()  # Ensure immediate output
                last_state[context] = current_state_tuple

    except subprocess.CalledProcessError:
        pass  # Ignore API errors, retry next iteration
    except KeyboardInterrupt:
        break

    time.sleep(5)
