{{/*
applications/stack-chart/templates/_helpers.tpl

Named templates used across all chart resources.
Convention: prefix every template with the chart name to avoid collisions
when this chart is used as a subchart.
*/}}

{{/*
Expand the chart name.
*/}}
{{- define "stack-chart.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully-qualified name: <release-name>-<component>.
Truncated to 63 chars (Kubernetes label/name limit).
Usage: include "stack-chart.fullname" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.fullname" -}}
{{- $component := .component -}}
{{- printf "%s-%s" .Release.Name $component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every resource.
Includes recommended Kubernetes labels for observability and tooling.
Usage: include "stack-chart.labels" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — the minimal stable set used by Services and Deployments.
These must NOT change after initial deployment (they are immutable on Deployments).
Usage: include "stack-chart.selectorLabels" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
