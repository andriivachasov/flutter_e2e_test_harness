# Seed profiles (R16)

One JSON object per file; the file name (without `.json`) is the profile
name tests reference in the manifest (`seed: {A: user-with-history}`) or
mid-test (`sync.seed('user-with-history')`).

The harness never interprets the object: it posts it as `data` to the
backend's test-only seed endpoint together with the target user
(`{"uid","email","profile","data"}`). The shape is therefore the example
backend's contract:

    {"notes": ["text", ...],
     "messages": [{"from": "<email>|me", "to": "<email>|me", "text": "..."}]}

`me` resolves to the seeded user's email.
