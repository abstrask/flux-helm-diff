#!/usr/bin/env bash
set -eu -o pipefail

helm_files=(${HELM_FILES[@]})
if [ "${#helm_files[@]}" == "0" ]; then
    echo "No Helm files specified, nothing to do"
    exit
fi
echo "${#helm_files[@]} Helm file(s) to render: ${helm_files[*]}"

helm_template() {
    set -eu -o pipefail
    if [ -z "${1}" ]; then
        echo "Error: Need file name to template" >&2
        return 2
    fi

    # 'head' or 'base' ref - used for logging output
    ref="${1%%/*}"

    # Set test = <something> to run against Helm teplates under test/
    if [ -z "${TEST:-}" ]; then
        helm_file="${1}"
    else
        helm_file="test/${1}"
    fi

    if [ ! -f "${helm_file}" ]; then
        # echo "Warn: File \"${helm_file}\" not found, skipping"
        echo "File \"${helm_file}\" not found, skipping" >&2
        return 1
    fi

    # Determine repo type - HelmRepository or OCIRepository
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
        chart_path=$(yq '. | select(.kind == "HelmRelease").spec.chart.spec.chart' "${helm_file}")

        # Download and extract release artifact - may only work with GitHub?
        release_id="${repo_name}_${repo_tag}"
        mkdir -p "./tmp/${release_id}"
        curl --no-progress-meter -Lo "${release_id}.tar.gz" "${repo_url}/archive/refs/tags/${repo_tag}.tar.gz"
        tar -xzf "${release_id}.tar.gz" --directory "./tmp/${release_id}"
        rm "./${release_id}.tar.gz" || true

        # Find the chart directory
        find_chart_path=$(echo "${chart_path}" | sed -e 's|^./|/|' -e 's|/$||')
        url=$(find "./tmp/${release_id}" -type d -path "*${find_chart_path}" | head -n 1)

    else
        echo "Unable to determine repo type, skipping"
        echo "Unable to determine repo type, skipping" >&2
        return 2
    fi

    # Extracting chart properties
    release_name=$(yq '. | select(.kind == "HelmRelease").metadata.name' "${helm_file}")
    release_namespace=$(yq '. | select(.kind == "HelmRelease").metadata.namespace' "${helm_file}")
    chart_values=$(yq '. | select(.kind == "HelmRelease").spec.values' "${helm_file}")
    chart_version="${chart_version:-N/A}" # not relevant for local charts, e.g. downloaded via GitRepository

    # Use Capabilities.APIVersions
    mapfile -t api_versions < <(yq '. | foot_comment' "${helm_file}" | yq '.helm-api-versions[]')

    # Let's see what information we got out about the chart...
    echo "${ref} repo type:         ${repo_type}" >&2
    echo "${ref} repo name:         ${repo_name}" >&2
    echo "${ref} repo/chart URL:    ${url}" >&2
    echo "${ref} chart name:        ${chart_name}" >&2
    echo "${ref} chart version:     ${chart_version}" >&2
    echo "${ref} release name:      ${release_name}" >&2
    echo "${ref} release namespace: ${release_namespace}" >&2
    echo "${ref} API versions:      $(IFS=,; echo "${api_versions[*]}")" >&2

    # Syntax for chart repos is different from OCI repos (as HelmRepo kind)
    if [[ "${url}" = "https://"* ]]; then
        chart_args=("${chart_name}" --repo "${url}" --version "${chart_version}")  # treat as array, to avoid adding single-quotes
    elif [[ "${url}" = "oci://"* ]]; then
        chart_args=("${url}" --version "${chart_version}") # treat as array, to avoid adding single-quotes
    else
        # Assume local path (i.e. GitRepository)
        chart_args=("${url}") # treat as array, to avoid adding single-quotes
    fi

    # Render template
    template_out=$(helm template "${release_name}" ${chart_args[@]} -n "${release_namespace}" -f <(echo "${chart_values}") --api-versions "$(IFS=,; echo "${api_versions[*]}")" 2>&1) || {
        echo "$template_out"
        echo "$template_out" >&2
        return 2
    }

    # Cleanup template, removing comments, output
    template_clean=$(yq -P 'sort_keys(..) comments=""' <(echo "${template_out}"))
    echo "$template_clean"
}

EOF=$(dd if=/dev/urandom bs=15 count=1 status=none | base64)
echo "markdown<<$EOF" > "$GITHUB_OUTPUT"
echo "## Flux Helm diffs" >> "$GITHUB_OUTPUT"

any_failed=0
for helm_file in "${helm_files[@]}"; do
    # Begin output
    echo -e "\nProcessing file \"$helm_file\""
    echo >> "$GITHUB_OUTPUT"
    echo "### ${helm_file}" >> "$GITHUB_OUTPUT"

    # Template before
    return_code=0
    base_out=$(helm_template "base/${helm_file}") || return_code=$?
    if [ $return_code -eq 2 ]; then # Ignore files skipped
        # TODO: Output warnings directly to GITHUB_OUTPUT in helm_template function?
        {
            echo '> [!WARNING]'
            echo "> Error rendering base ref: \`${base_out}\`"
        } >> "$GITHUB_OUTPUT"
        any_failed=1
        continue
    fi

    # Template after
    return_code=0
    head_out=$(helm_template "head/${helm_file}") || return_code=$?
    if [ $return_code -ne 0 ]; then
        # TODO: Output warnings directly to GITHUB_OUTPUT in helm_template function?
        {
            echo '> [!WARNING]'
            echo "> Error rendering head ref: \`${head_out}\`"
        } >> "$GITHUB_OUTPUT"
        any_failed=1
        continue
    fi

    # Template diff
    diff_out=$(diff --unified=5 <(echo "${base_out}") <(echo "${head_out}")) || true
    echo "Diff has $(echo "$diff_out" | wc -l) line(s)"
    [ -z "${diff_out}" ] && diff_out="No changes"
    {
        echo '```diff'
        echo "${diff_out}"
        echo '```'
    } >> "$GITHUB_OUTPUT"
done

{
    echo "$EOF"
    echo "any_failed=$any_failed"
} >> "$GITHUB_OUTPUT"

if [ -d "./tmp" ]; then rm -rf "./tmp"; fi
echo -e "\nAll done"