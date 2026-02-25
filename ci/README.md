# CI

## Triggering the Nightly Job Manually

1. Obtain an API token by visiting <https://oauth-openshift.apps.ci.l2s4.p1.openshiftapps.com/oauth/token/request>
2. Log in with `oc login`
3. Start the job:

```bash
curl -X POST \
    -H "Authorization: Bearer $(oc whoami -t)" \
    'https://gangway-ci.apps.ci.l2s4.p1.openshiftapps.com/v1/executions/' \
    -d '{"job_name": "periodic-ci-openshift-online-rosa-regional-platform-main-nightly", "job_execution_type": "1"}'
```

## AWS Credentials

The nightly job (`periodic-ci-openshift-online-rosa-regional-platform-main-nightly`) uses two AWS accounts (regional and management). It runs on a daily cron (`0 7 * * *`).

Credentials are stored in Vault at `kv/selfservice/cluster-secrets-rosa-regional-platform-int/nightly-static-aws-credentials` and mounted at `/var/run/rosa-credentials/` with keys `regional_access_key`, `regional_secret_key`, `management_access_key`, `management_secret_key`.

### Where things are defined

- **CI job config**: [`openshift/release` — `ci-operator/config/openshift-online/rosa-regional-platform/`](https://github.com/openshift/release/tree/master/ci-operator/config/openshift-online/rosa-regional-platform)

## Test Results

Results are available on the [OpenShift CI Prow dashboard](https://prow.ci.openshift.org/?job=periodic-ci-openshift-online-rosa-regional-platform-main-nightly).
