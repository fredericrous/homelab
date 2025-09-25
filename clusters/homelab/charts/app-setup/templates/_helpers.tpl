{{/*
Expand the name of the chart.
*/}}
{{- define "app-setup.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "app-setup.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-setup" .Values.appName | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "app-setup.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "app-setup.labels" -}}
helm.sh/chart: {{ include "app-setup.chart" . }}
{{ include "app-setup.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "app-setup.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.appName }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Database name
*/}}
{{- define "app-setup.databaseName" -}}
{{- .Values.postgres.database | default .Values.appName }}
{{- end }}

{{/*
Database username
*/}}
{{- define "app-setup.databaseUsername" -}}
{{- .Values.postgres.username | default .Values.appName }}
{{- end }}