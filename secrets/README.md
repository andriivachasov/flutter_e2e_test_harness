# secrets/

Machine-local credentials. **Gitignored** — nothing in here (except this
README) is ever committed.

Put the dedicated test-project service-account JSON here and point
`firebase.service_account_key_path` in `e2e.local.yaml` at it:

    firebase:
      mode: real
      service_account_key_path: secrets/firebase-service-account.json

Alternatively export `E2E_FIREBASE_SERVICE_ACCOUNT=/abs/path.json` and keep
the file outside the repo entirely.
