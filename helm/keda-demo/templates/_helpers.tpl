{{/*
helm/keda-demo/templates/_helpers.tpl
Reusable template helpers for the keda-demo chart.
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "keda-demo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "keda-demo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart label value (name-version).
*/}}
{{- define "keda-demo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "keda-demo.labels" -}}
helm.sh/chart: {{ include "keda-demo.chart" . }}
{{ include "keda-demo.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels (used in Deployment selector and Service selector).
Must be stable across upgrades — don't include version here.
*/}}
{{- define "keda-demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keda-demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: consumer
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "keda-demo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "keda-demo.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Namespace name.
*/}}
{{- define "keda-demo.namespace" -}}
{{- .Values.namespace.name | default .Release.Namespace }}
{{- end }}

{{/*
SQS queue name extracted from queue URL (last segment after /).
Used as the prometheus metric label.
*/}}
{{- define "keda-demo.queueName" -}}
{{- .Values.aws.sqsQueueUrl | splitList "/" | last }}
{{- end }}
