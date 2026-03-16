{{- define "stack-chart.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
fullname: <release-name>-<component>, truncated to 63 chars.
Usage: include "stack-chart.fullname" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.fullname" -}}
{{- $component := .component -}}
{{- printf "%s-%s" .Release.Name $component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
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
Selector labels — immutable after initial deploy (used in Deployment.spec.selector).
Usage: include "stack-chart.selectorLabels" (dict "Release" .Release "Chart" .Chart "component" "frontend")
*/}}
{{- define "stack-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}
