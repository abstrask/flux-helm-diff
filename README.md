# Flux Helm chart diff action

A composite GitHub Action for use with PR workflows in repos with [Flux Helm manifests](https://fluxcd.io/flux/use-cases/helm/).

It extracts the repo URL, chart name and version and values, and renders the supplied list of templates before and after PR, and produce a diff report in markdown format.

It makes it easy to determine the *effect* on the rendered Kubernetes manifests, e.g. when bumping chart version or changing the supplied Helm values.

Combine with these awesome projects for maximum workflow smoothness:

- [dorny/paths-filter](https://github.com/dorny/paths-filter): Only run workflow if Helm files were changed
- [alexellis/arkade-get](https://github.com/alexellis/arkade-get): Install dependencies
- [tj-actions/changed-files](https://github.com/tj-actions/changed-files): Extract list of changed Helm files
- [mshick/add-pr-comment](https://github.com/mshick/add-pr-comment): Add diff report as comment to PR
- [Renovate](https://github.com/renovatebot/renovate): Automatically create PRs when new charts versions are available)

## Dependencies

Requires [Helm](https://helm.sh/) and [yq](https://mikefarah.gitbook.io/yq). Both can be installed using [Arkade](https://github.com/alexellis/arkade-get) if needed.

## Inputs

- `helm_files`: List of changed Helm files, probably as output by [tj-actions/changed-files](https://github.com/tj-actions/changed-files)

## Outputs

- `diff_markdown`: Markdown report with per-Helm file changes, to be passed to [mshick/add-pr-comment](https://github.com/mshick/add-pr-comment)
- `any_failed`: Will be set to `1` if the `helm` command fails on any of the files

In `diff_markdown` the output for each file will either be:

- That of the `diff` command
- "No changes"
- Error message produced by Helm command if failed

## Usage

### TL;DR

```yaml
- id: helm_diff
  name: Flux Helm diff
  uses: abstrask/flux-helm-diff@main
  with:
    helm_files: ${{ steps.changed_files_helm.outputs.all_changed_files }}
```

### Full Example

Run on pull requests:


```yaml
name: Run Helm diff
on:
  - pull_request_target
```

Filter on changed Helm files (under `infrastructure/base/`):

```yaml
jobs:
  path_filter:
    name: Filter Helm templates
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read # fix "Resource not accessible by integration" error
    outputs:
      helm: ${{ steps.filter.outputs.helm }}
    steps:
      - id: checkout_head
        uses: actions/checkout@v4
        with:
          ref: ${{ github.head_ref }}

      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            helm:
              - 'infrastructure/base/*/helm.yaml'
```

Run diff job only if any Helm files were changed:

```yaml
  helm_diff:
    name: Diff changed Helm templates
    needs: path_filter
    if: ${{ needs.path_filter.outputs.helm == 'true' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
```

Install `helm` and `yq`:

```yaml
    steps:
      - id: dependencies
        name: Install dependencies
        uses: alexellis/arkade-get@master
        with:
          helm: latest
          yq: latest
```

Checkout base and head:

```yaml
      - id: checkout_base
        uses: actions/checkout@v4
        with:
          ref: ${{ github.base_ref }}
          path: base

      - id: checkout_head
        uses: actions/checkout@v4
        with:
          ref: ${{ github.head_ref }}
          path: head
```

Produce list of changed Helm files:

```yaml
      - name: Get changed Helm files
        id: changed_files_helm
        uses: tj-actions/changed-files@v44
        with:
          files: |
            infrastructure/base/*/helm.yaml
```

Render templates and generate diff report:

```yaml
      - id: helm_diff
        name: Helm diff
        uses: abstrask/actions-playground@main
        with:
          helm_files: ${{ steps.changed_files_helm.outputs.all_changed_files }}

```

Add diff report as comment to PR:

```yaml
      - id: pr_comment
        name: Add PR comment
        uses: mshick/add-pr-comment@v2
        if: contains(fromJSON('["pull_request_target"]'), github.event_name)
        with:
          message-id: diff
          refresh-message-position: true
          message: |
            ${{ steps.helm_diff.outputs.diff_markdown }}

```

Optionally, cause check to fail, if any Helm file failed to render:

```yaml
      - id: fail_job
        name: Diff failed?
        uses: actions/github-script@v7
        if: ${{ steps.helm_diff.outputs.any_failed == 1 }}
        with:
          script: |
            core.setFailed('Failed to run diff')
```

See [example-workflow.yaml](example-workflow.yaml) for coherent example.

## Example Output/PR comment

### infrastructure/base/dcgm-exporter/helm.yaml
```
No changes
```

### infrastructure/base/nvidia-device-plugin/helm.yaml
```
(abbreviated)

+# Source: nvidia-device-plugin/templates/daemonset-device-plugin.yml
 apiVersion: apps/v1
 kind: DaemonSet
 metadata:
   labels:
     app.kubernetes.io/instance: nvidia-device-plugin
     app.kubernetes.io/managed-by: Helm
     app.kubernetes.io/name: nvidia-device-plugin
-    app.kubernetes.io/version: 0.14.5
-    helm.sh/chart: nvidia-device-plugin-0.14.5
+    app.kubernetes.io/version: 0.15.0
+    helm.sh/chart: nvidia-device-plugin-0.15.0
   name: nvidia-device-plugin
   namespace: nvidia-device-plugin
 spec:
   selector:
     matchLabels:
@@ -19,15 +75,42 @@
       annotations: {}
       labels:
         app.kubernetes.io/instance: nvidia-device-plugin
         app.kubernetes.io/name: nvidia-device-plugin
     spec:
+      affinity:
+        nodeAffinity:
+          requiredDuringSchedulingIgnoredDuringExecution:
+            nodeSelectorTerms:
+              - matchExpressions:
+                  - key: feature.node.kubernetes.io/pci-10de.present
+                    operator: In
+                    values:
+                      - "true"
+              - matchExpressions:
+                  - key: feature.node.kubernetes.io/cpu-model.vendor_id
+                    operator: In
+                    values:
+                      - NVIDIA
+              - matchExpressions:
+                  - key: nvidia.com/gpu.present
+                    operator: In
+                    values:
+                      - "true"
       containers:
-        - env:
+        - command:
+            - nvidia-device-plugin
+          env:
+            - name: MPS_ROOT
+              value: /run/nvidia/mps
             - name: NVIDIA_MIG_MONITOR_DEVICES
               value: all
-          image: nvcr.io/nvidia/k8s-device-plugin:v0.14.5
+            - name: NVIDIA_VISIBLE_DEVICES
+              value: all
+            - name: NVIDIA_DRIVER_CAPABILITIES
+              value: compute,utility
+          image: nvcr.io/nvidia/k8s-device-plugin:v0.15.0
           imagePullPolicy: IfNotPresent
           name: nvidia-device-plugin-ctr
           resources:
             limits:
               memory: 64Mi

(abbreviated)
```

### infrastructure/base/weave-gitops/helm.yaml
```
Error: looks like "oci://ghcr.io/weaveworks/charts" is not a valid chart repository or cannot be reached: object required
```

## Testing

```bash
helm_files=($(find ./test/head -type f -name 'helm.yaml' | sed "s|^./test/head/||" | sort))
GITHUB_OUTPUT=debug.out HELM_FILES="${helm_files[@]}" TEST=1 ./flux-helm-diff.sh; cat debug.out
```

### Testing files

| Name                    | Scenario tested                                                              | Expected output                                 |
| ----------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------- |
| `dcgm-exporter`         | Chart added in `head` that doesn't exist in `base`                           | Diff shows entire rendered template as added    |
| `metaflow`              | Very non-standard way of publishing charts (not sure if should be supported) | TBD                                             |
| `nvidia-device-plugin`  | HelmRepository (using `https`), minor chart version bump                     | Diff (with potentially breaking `nodeAffinity`) |
| `weave-gitops-helm2oci` | Repository type changed from HelmRepository (type `oci`) to OCIRepository    | No changes                                      |
| `weave-gitops-helmrepo` | HelmRepository with type `oci`                                               | Diff                                            |
| `weave-gitops-ocirepo`  | OCIRepository                                                                | Diff                                            |

## Known Shortcomings

- [x] Charts installed via OCI repositories fail to render, because the helm template syntax is unnecessarily inconsistent
- [x] Difficult to test locally - pass files as variable instead?
- [x] Also produce report for new Helm files added
- [ ] Potentially also support “in-tree” charts, GitRepository source, (like Metaflow), that are not packaged separately
- [ ] Kustomize diff too?
- [ ] Naively assumes there exactly only chart source in the Helm file. Could select by ${repo_name} so be sure.