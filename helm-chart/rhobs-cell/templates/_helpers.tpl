{{/*
Expand the name of the chart.
*/}}
{{- define "rhobs-cell.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rhobs-cell.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "rhobs-cell.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rhobs-cell.labels" -}}
helm.sh/chart: {{ include "rhobs-cell.chart" . }}
{{ include "rhobs-cell.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rhobs
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rhobs-cell.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rhobs-cell.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Gateway labels
*/}}
{{- define "rhobs-cell.gateway.labels" -}}
{{ include "rhobs-cell.labels" . }}
app.kubernetes.io/component: gateway
{{- end }}

{{/*
Gateway selector labels
*/}}
{{- define "rhobs-cell.gateway.selectorLabels" -}}
{{ include "rhobs-cell.selectorLabels" . }}
app.kubernetes.io/component: gateway
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "rhobs-cell.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "rhobs-cell.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the namespace name
*/}}
{{- define "rhobs-cell.namespace" -}}
{{- if .Values.namespace.create }}
{{- default .Release.Namespace .Values.namespace.name }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

{{/*
Create the gateway domain
*/}}
{{- define "rhobs-cell.gateway.domain" -}}
{{- if .Values.gateway.ingress.hosts }}
{{- (index .Values.gateway.ingress.hosts 0).host | default .Values.global.domain }}
{{- else }}
{{- .Values.global.domain }}
{{- end }}
{{- end }}

{{/*
Thanos endpoints
*/}}
{{- define "rhobs-cell.thanos.queryEndpoint" -}}
{{- if .Values.thanos.enabled }}
http://{{ .Release.Name }}-thanos-query-frontend:9090
{{- else }}
{{- .Values.gateway.endpoints.metrics.read }}
{{- end }}
{{- end }}

{{- define "rhobs-cell.thanos.receiveEndpoint" -}}
{{- if .Values.thanos.enabled }}
http://{{ .Release.Name }}-thanos-receive:19291
{{- else }}
{{- .Values.gateway.endpoints.metrics.write }}
{{- end }}
{{- end }}

{{/*
Loki endpoints
*/}}
{{- define "rhobs-cell.loki.readEndpoint" -}}
{{- if .Values.loki.enabled }}
http://{{ .Release.Name }}-loki-gateway:80
{{- else }}
{{- .Values.gateway.endpoints.logs.read }}
{{- end }}
{{- end }}

{{- define "rhobs-cell.loki.writeEndpoint" -}}
{{- if .Values.loki.enabled }}
http://{{ .Release.Name }}-loki-gateway:80
{{- else }}
{{- .Values.gateway.endpoints.logs.write }}
{{- end }}
{{- end }}

{{/*
Alertmanager endpoint
*/}}
{{- define "rhobs-cell.alertmanager.endpoint" -}}
{{- if .Values.alertmanager.enabled }}
http://{{ .Release.Name }}-alertmanager:9093
{{- else }}
http://alertmanager:9093
{{- end }}
{{- end }}

{{/*
AWS Account ID
*/}}
{{- define "rhobs-cell.aws.accountId" -}}
{{- required "global.aws.accountId is required" .Values.global.aws.accountId }}
{{- end }}

{{/*
IRSA Role ARN for Thanos
*/}}
{{- define "rhobs-cell.thanos.irsaRoleArn" -}}
arn:aws:iam::{{ include "rhobs-cell.aws.accountId" . }}:role/rhobs-thanos-{{ .Values.global.region }}
{{- end }}

{{/*
IRSA Role ARN for Loki
*/}}
{{- define "rhobs-cell.loki.irsaRoleArn" -}}
arn:aws:iam::{{ include "rhobs-cell.aws.accountId" . }}:role/rhobs-loki-{{ .Values.global.region }}
{{- end }}

{{/*
S3 bucket names
*/}}
{{- define "rhobs-cell.s3.metricsBucket" -}}
rhobs-metrics-{{ .Values.global.region }}
{{- end }}

{{- define "rhobs-cell.s3.logsBucket" -}}
rhobs-logs-{{ .Values.global.region }}
{{- end }}
