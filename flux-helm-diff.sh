#!/bin/bash

if [ "${#}" == "0" ]; then
    echo "No Helm files specified, nothing to do"
    exit
fi
helm_files=( "${@}" )
echo "Helm files to render: ${helm_files[*]}"

helm_template() {
    if [ -z "${2}" ]; then
        echo "Error: Need file name to template" >&2
        return 1
    fi

    # Set test = <something> to run against Helm teplates under test/
    if [ -z "${test}" ]; then
        helm_file="${2}"
    else
        helm_file="test/${2}"
    fi

    if [ ! -f "${helm_file}" ]; then
        echo "Error: File \"${helm_file}\" not found, skipping diff"
        echo "Error: File \"${helm_file}\" not found, skipping diff" >&2
        return 1
    fi

    # Extracting chart properties
    name=$(yq '. | select(.kind == "HelmRelease").metadata.name' "${helm_file}")
    namespace=$(yq '. | select(.kind == "HelmRelease").metadata.namespace' "${helm_file}")
    version=$(yq '. | select(.kind == "HelmRelease") | .spec.chart.spec.version' "${helm_file}")
    url=$(yq '. | select(.kind == "HelmRepository") | .spec.url' "${helm_file}")
    chart=$(yq '. | select(.kind == "HelmRelease") | .spec.chart.spec.chart' "${helm_file}")
    values=$(yq '. | select(.kind == "HelmRelease").spec.values' "${helm_file}")
    echo "Chart version ${1}: $version ($chart from $url)" >&2

    # Syntax for chart repos is different from OCI repos
    if [[ "${url}" = "oci://"* ]]; then
        chart_args=("${url}/${chart}") # treat as array, to avoid adding single-quotes
    else
        chart_args=("${chart}" --repo "${url}")
    fi

    # Render template
    template_out=$(helm template "${name}" ${chart_args[@]} --version "${version}" -n "${namespace}" -f <(echo "${values}")  2>&1) || {
        echo "$template_out"
        echo "$template_out" >&2
        return 1
    }

    # Cleanup template, removing comments, output
    template_clean=$(yq -P 'sort_keys(..) comments=""' <(echo "${template_out}"))
    echo "$template_clean"

    # Debug info
    echo "Line count ${1}: values ($(echo "${values}" | wc -l)), template ($(echo "${template_out}" | wc -l)), template_clean ($(echo "${template_clean}" | wc -l))" >&2
}

EOF=$(dd if=/dev/urandom bs=15 count=1 status=none | base64)
echo "markdown<<$EOF" >> "$GITHUB_OUTPUT"
echo "## Flux Helm diffs" >> "$GITHUB_OUTPUT"

any_failed=0
for helm_file in "${helm_files[@]}"; do
    # Begin output
    echo -e "\nProcessing file \"$helm_file\""
    echo >> "$GITHUB_OUTPUT"
    echo "### ${helm_file}" >> "$GITHUB_OUTPUT"

    # Template before
    return_code=0
    before_out=$(helm_template before "base/${helm_file}") || return_code=1
    if [ $return_code -ne 0 ]; then
        {
            echo '```'
            echo "${before_out}"
            echo '```'
        } >> "$GITHUB_OUTPUT"
        any_failed=1
        continue
    fi

    # Template after
    after_out=$(helm_template after "head/${helm_file}") || true

    # Template diff
    diff_out=$(diff --unified=5 <(echo "${before_out}") <(echo "${after_out}")) || true
    echo "Diff has $(echo "$diff_out" | wc -l) line(s)"
    [ -z "${diff_out}" ] && diff_out="No changes"
    {
        echo '```'
        echo "${diff_out}"
        echo '```'
    } >> "$GITHUB_OUTPUT"
done

{
    echo "$EOF"
    echo "any_failed=$any_failed"
} >> "$GITHUB_OUTPUT"
