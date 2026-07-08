# Kyverno policy denials (captured live, 2026-07-08T10:21Z)

Three deliberately-violating Deployments applied to a preview-labeled
namespace; each rejected at admission. Phase 3 acceptance evidence.

## 1. Root container
```
Error from server: error when creating "/tmp/claude-1000/-run-media-bazzite-HERAMB-Project-backups-prlab/4653ba67-27dd-4ebd-bbf9-ff9fbfb21253/scratchpad/v1.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Deployment/policy-test/violate-root was blocked due to the following policies 

disallow-root-user:
  autogen-run-as-non-root: 'validation error: Preview containers must not run as root.
    Set securityContext.runAsNonRoot=true at the pod level, or on every container
    (including init containers). rule autogen-run-as-non-root[0] failed at path /spec/template/spec/securityContext/runAsNonRoot/
    rule autogen-run-as-non-root[1] failed at path /spec/template/spec/containers/0/securityContext/'
```
## 2. Missing resources requests/limits
```
Error from server: error when creating "/tmp/claude-1000/-run-media-bazzite-HERAMB-Project-backups-prlab/4653ba67-27dd-4ebd-bbf9-ff9fbfb21253/scratchpad/v2.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Deployment/policy-test/violate-limits was blocked due to the following policies 

require-requests-limits:
  autogen-require-container-requests-limits: 'validation error: Preview containers
    must declare resources.requests and resources.limits for both cpu and memory.
    rule autogen-require-container-requests-limits failed at path /spec/template/spec/containers/0/resources/limits/'
```
## 3. Disallowed registry (docker.io)
```
Error from server: error when creating "/tmp/claude-1000/-run-media-bazzite-HERAMB-Project-backups-prlab/4653ba67-27dd-4ebd-bbf9-ff9fbfb21253/scratchpad/v3.yaml": admission webhook "validate.kyverno.svc-fail" denied the request: 

resource Deployment/policy-test/violate-registry was blocked due to the following policies 

restrict-image-registries:
  autogen-allowed-registries-only: 'validation error: Preview images must come from
    211374268683.dkr.ecr.us-east-1.amazonaws.com or public.ecr.aws/docker/library
    (got a disallowed registry). rule autogen-allowed-registries-only failed at path
    /spec/template/spec/containers/0/image/'
```
