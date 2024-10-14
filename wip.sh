chart_name=dcgm-exporter
url=https://nvidia.github.io/dcgm-exporter/helm-charts
chart_version=3.5.0

chart_name=argo-workflows
url=https://argoproj.github.io/argo-helm
chart_version=0.42.5



release_name="${chart_name}"
release_id="${chart_name}-${chart_version}"
chart_temp_path="./tmp/${release_id}"
mkdir -p "${chart_temp_path}"
helm pull --repo "${url}" "${chart_name}" --version "${chart_version}" -d "${chart_temp_path}"
tar -xzf "${chart_temp_path}/${release_id}.tgz" --directory "${chart_temp_path}"
rm "${chart_temp_path}/${release_id}.tgz" || true
url="./tmp/${release_id}/${chart_name}"
helm template "${release_name}" "${url}" | grep "kind:"
grep -R --include='*.yaml' --include='*.yml' --include='*.tpl' ".Capabilities.APIVersions" "${chart_temp_path}" > /dev/null && echo "Warning"


# To do:
# Differentiate downloading chart, streamline extracting
# Warn on grep
# Info on file not found in base
# Move render CAUTION to helm_template function