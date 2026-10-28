#!/usr/bin/env python3
import os
import sys


prompt = sys.argv[1].lower()
if prompt.startswith("username"):
    print(os.environ["GIT_PUSH_USERNAME"])
elif prompt.startswith("password"):
    print(os.environ["GIT_PUSH_PAT"])
else:
    raise SystemExit("Unexpected Git credential prompt")
