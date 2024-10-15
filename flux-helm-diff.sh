#!/usr/bin/env bash
set -eu -o pipefail

helm_files=(${HELM_FILES[@]})
if [[ "${#helm_files[@]}" == "0" ]]; then
    echo "No Helm files specified, nothing to do"
    exit
fi
echo "${#helm_files[@]} Helm file(s) to render: ${helm_files[*]}"

output_msg() {
    if [[ -z "${2}" ]]; then
        echo "Need severity and message text" >&2
        return 1
    fi
    {
        # Alert level - https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts
        echo "> [!${1}]"
        shift

        # Message line(s)
        for msg in "$@"; do
            echo "> ${msg}"
            echo '>'
        done
        echo
    } >> "$GITHUB_OUTPUT"
}

helm_template() {
    set -eu -o pipefail

    # 'head' or 'base' ref - used for logging output
    ref="${1%%/*}"

    if [[ -z "${1}" ]]; then
        echo "Error: Need ${ref} file name to template" >&2
        output_msg CAUTION "Error: Need \`${ref}\` file name to template."
        return 1
    fi

    # Set test = <something> to run against Helm teplates under test/ directory
    if [ -z "${TEST:-}" ]; then
        helm_file="${1}"
    else
        helm_file="test/${1}"
    fi

    if [ ! -f "${helm_file}" ]; then
        echo "${ref} file \"${helm_file}\" not found" >&2
        if [[ "${ref}" == "base" ]]; then
            output_msg TIP "Helm file not found in \`${ref}\` ref, looks like a new Helm file."
            return
        else
            output_msg CAUTION "Error: Helm file not found in \`${ref}\` ref, cannot produce diff."
            return 1
        fi
    fi

    # Extracting chart properties
    release_name=$(yq '. | select(.kind == "HelmRelease").metadata.name' "${helm_file}")
    release_namespace=$(yq '. | select(.kind == "HelmRelease").metadata.namespace' "${helm_file}")
    chart_values=$(yq '. | select(.kind == "HelmRelease").spec.values' "${helm_file}")

    # Determine repo type
    # https://fluxcd.io/flux/components/source/helmrepositories/
    # https://fluxcd.io/flux/components/source/ocirepositories/
    # https://fluxcd.io/flux/components/source/gitrepositories/
    if [[ "HelmRepository" == "$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.sourceRef.kind' "${helm_file}")" ]]; then
        repo_type=helm
        repo_name=$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.sourceRef.name' "${helm_file}")
        repo_url=$(yq '. | select(.kind == "HelmRepository").spec.url' "${helm_file}")

        chart_name=$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.chart' "${helm_file}")
        chart_version=$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.version' "${helm_file}")

        if [[ "${repo_url}" = "oci://"* ]]; then
            url="${repo_url}/${chart_name}" # Syntax for chart repos is different from OCI repos (as HelmRepo kind)
        else
            url="${repo_url}"
        fi

    elif [[ "OCIRepository" == "$(yq '. | select(.kind == "HelmRelease").spec.chartRef.kind' "${helm_file}")" ]]; then
        repo_type=oci
        repo_name=$(yq '. | select(.kind == "HelmRelease").spec.chartRef.name' "${helm_file}")

        chart_name="${repo_name}"
        chart_version=$(yq '. | select(.kind == "OCIRepository").spec.ref.tag' "${helm_file}")

        url=$(yq '. | select(.kind == "OCIRepository").spec.url' "${helm_file}")

    elif [[ "GitRepository" == "$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.sourceRef.kind' "${helm_file}")" ]]; then
        repo_type=git
        repo_name=$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.sourceRef.name' "${helm_file}")
        repo_url=$(yq '. | select(.kind == "GitRepository").spec.url' "${helm_file}")
        repo_tag=$(yq '. | select(.kind == "GitRepository").spec.ref.tag' "${helm_file}")

        chart_name="${repo_name}"
        chart_version="${repo_tag}"
        chart_rel_path=$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.chart' "${helm_file}")

        url="${repo_url}/archive/refs/tags/${repo_tag}.tar.gz"

    else
        echo "Unrecognised ${ref} repo type" >&2
        if [[ "${ref}" == "base" ]]; then
            output_msg TIP "Unable to determine \`${ref}\` repo type, not rendering template."
            return
        else
            output_msg CAUTION "Error: Unable to determine \`${ref}\` repo type, cannot produce diff."
            return 1
        fi
    fi

    # Use Capabilities.KubeVersion
    kube_version=$(yq '. | foot_comment' "${helm_file}" | yq '.flux-helm-diff.kube-version')
    [[ "${kube_version}" == "null" ]] && kube_version=""

    # Use Capabilities.APIVersions
    mapfile -t api_versions < <(yq '. | foot_comment' "${helm_file}" | yq '.flux-helm-diff.api-versions[]')

    # Let's see what information we got out about the chart...
    echo "${ref} repo type:             ${repo_type}" >&2
    echo "${ref} repo name:             ${repo_name}" >&2
    echo "${ref} repo/chart URL:        ${url}" >&2
    echo "${ref} chart name:            ${chart_name}" >&2
    echo "${ref} chart version:         ${chart_version}" >&2
    echo "${ref} release name:          ${release_name}" >&2
    echo "${ref} release namespace:     ${release_namespace}" >&2
    echo "${ref} simulate Kube version: ${kube_version}" >&2
    echo "${ref} simulate API versions: $(IFS=,; echo "${api_versions[*]}")" >&2

    # Download chart
    release_id="${chart_name}-${chart_version}"
    chart_temp_path="./tmp/${release_name}-${release_id}-${ref}"
    mkdir -p "${chart_temp_path}"
    if [[ "${repo_type}" != "git" ]]; then
        # Syntax for pull Helm charts is different for OCI repos
        if [[ "${url}" = "https://"* ]]; then
            helm_pull_args=("${chart_name}" --repo "${url}")  # treat as array, to avoid adding single-quotes
        elif [[ "${url}" = "oci://"* ]]; then
            helm_pull_args=("${url}") # treat as array, to avoid adding single-quotes
        else
            echo "Unrecognised ${ref} repo type. Again. This should already be caught, so this should never happen.">&2
            return 1
        fi
        chart_file="${chart_temp_path}/${release_id}.tgz"
        helm pull ${helm_pull_args[@]} --version "${chart_version}" -d "${chart_temp_path}" || {
            echo "Helm failed to pull \"${url}\" to \"${chart_temp_path}\"" >&2
            output_msg CAUTION "Helm failed to pull \`${url}\` to \`${chart_temp_path}\`."
            return 1
        }
    else
        # Probably only works with GitHub
        chart_file="${chart_temp_path}/asset.tgz"
        curl --no-progress-meter -Lo "${chart_file}" "${url}" || {
            echo "cURL failed to download \"${url}\" to \"${chart_file}\"" >&2
            output_msg CAUTION "cURL failed to download \`${url}\` to \`${chart_file}\`."
            return 1
        }
    fi

    # Extract chart
    tar -xzf "${chart_file}" --directory "${chart_temp_path}"
    rm "${chart_file}" || true
    if [[ "${repo_type}" == "git" ]]; then
        find_chart_path=$(echo "${chart_rel_path}" | sed -e 's|^./|/|' -e 's|/$||')
        chart_path=$(find "${chart_temp_path}" -type d -path "*${find_chart_path}" | head -n 1)
    else
        chart_path="${chart_temp_path}/${chart_name}"
    fi

    # Check if chart is using .Capabilities.KubeVersion
    grep -R --include='*.yaml' --include='*.yml' --include='*.tpl' ".Capabilities.KubeVersion" "${chart_temp_path}" > /dev/null && {
        echo "${ref} uses \".Capabilities.KubeVersion\"" >&2
        if [[ ${#kube_version} -eq 0 ]]; then
            output_msg TIP "Chart in \`${ref}\` ref uses [\`.Capabilities.KubeVersion\`](https://helm.sh/docs/chart_template_guide/builtin_objects/) but is not specifying a Kubernetes version to simulate. Will use Helm's default Kubernetes version: \`${helm_default_kube_version}\`." \
                "See [Simulating Capabilities](https://github.com/marketplace/actions/flux-helm-diff#simulating-capabilities) for details."
            helm_kube_version=() # treat as array, to avoid adding single-quotes
        else
            output_msg TIP "Chart in \`${ref}\` ref uses [\`.Capabilities.KubeVersion\`](https://helm.sh/docs/chart_template_guide/builtin_objects/) and is simulating the following Kubernetes version: \`${kube_version}\`"
            helm_kube_version=(--kube-version "${kube_version}") # treat as array, to avoid adding single-quotes
        fi
    }

    # Check if chart is using .Capabilities.APIVersions
    grep -R --include='*.yaml' --include='*.yml' --include='*.tpl' ".Capabilities.APIVersions" "${chart_temp_path}" > /dev/null && {
        echo "${ref} uses \".Capabilities.APIVersions\"" >&2
        if [[ ${#api_versions[@]} -eq 0 ]]; then
            output_msg IMPORTANT "Chart in \`${ref}\` ref uses [\`.Capabilities.APIVersions\`](https://helm.sh/docs/chart_template_guide/builtin_objects/) but is not specifying any APIs to simulate. Only the built-in API versions are available for templating." \
                "See [Simulating Capabilities](https://github.com/marketplace/actions/flux-helm-diff#simulating-capabilities) for details."
        else
            output_msg TIP "Chart in \`${ref}\` ref uses [\`.Capabilities.APIVersions\`](https://helm.sh/docs/chart_template_guide/builtin_objects/) and is simulating the following APIs:" \
                "$(printf "\`%s\`\n" "${api_versions[@]}")"
        fi
    }

    # Render template
    return_code=0
    template_out=$(helm template "${release_name}" "${chart_path}" -n "${release_namespace}" -f <(echo "${chart_values}") --api-versions "$(IFS=,; echo "${api_versions[*]}")" ${helm_kube_version[@]} 2>&1) || return_code=$?
    rm -rf "${chart_temp_path}"
    if [ $return_code -ne 0 ]; then
        echo "$template_out" >&2
        output_msg CAUTION "Error rendering \`${ref}\` ref: \`${template_out}\`."
        return 1
    fi

    # Cleanup template, removing comments, output
    template_clean=$(yq -P 'sort_keys(..) comments=""' <(echo "${template_out}"))
    echo "$template_clean"
}

# Get default Helm capabilities
helm_capabilities=$(helm template --repo https://abstrask.github.io/helm-charts helm-capabilities) || true
helm_default_kube_version=$(yq '.helmCapabilities.kubeVersion' <<< "${helm_capabilities}")
echo -e "\nHelm default Kubernetes version: ${helm_default_kube_version}"
kube_api_versions=$(yq '.helmCapabilities.apiVersions' <<< "${helm_capabilities}")
echo -e "\nHelm built-in API versions:\n${kube_api_versions}"

EOF=$(dd if=/dev/urandom bs=15 count=1 status=none | base64)
echo "markdown<<$EOF" > "$GITHUB_OUTPUT"
echo "## Flux Helm diffs" >> "$GITHUB_OUTPUT"

any_failed=0
for helm_file in "${helm_files[@]}"; do

    # Begin output
    echo -e "\nProcessing file \"$helm_file\""
    echo -e "\n### \`${helm_file}\`\n" >> "$GITHUB_OUTPUT"

    # Template before
    base_out=$(helm_template "base/${helm_file}") || {
        any_failed=1
        continue
    }

    # Template after
    head_out=$(helm_template "head/${helm_file}") || {
        any_failed=1
        continue
    }

    # Template diff
    diff_out=$(diff --unified=5 <(echo "${base_out}") <(echo "${head_out}")) || true
    echo "Diff has $(echo "$diff_out" | wc -l) line(s)"
    if [[ -z "${diff_out}" ]]; then
        echo '> [!NOTE]'
        echo '> No changes'
    else
        echo '```diff'
        echo "${diff_out}"
        echo '```'
    fi >> "$GITHUB_OUTPUT"

done

{
    echo "$EOF"
    echo "any_failed=$any_failed"
} >> "$GITHUB_OUTPUT"

if [ -d "./tmp" ]; then rm -rf "./tmp"; fi
echo -e "\nAll done"