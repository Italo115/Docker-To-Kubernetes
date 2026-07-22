{{/*
platform app-template helpers.

This chart renders ONE application per HelmRelease. All shape is driven by
values.yaml. The consuming HelmRelease lives in apps/base/<app>/ in the
infrastructure repo.
*/}}

{{/* The app's component name. Required. */}}
{{- define "platform.component" -}}
{{- required "values.component is required" .Values.component -}}
{{- end -}}

{{/* The functional domain (core, commercial, finance, operations, it, supplychain). Required. */}}
{{- define "platform.domain" -}}
{{- required "values.domain is required" .Values.domain -}}
{{- end -}}

{{/* Fully qualified resource name. Uses .Release.Name as prefix when it differs from the component. */}}
{{- define "platform.fullname" -}}
{{- $component := include "platform.component" . -}}
{{- if contains $component .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $component | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Chart label (chart name + version). */}}
{{- define "platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels stamped on every object. */}}
{{- define "platform.labels" -}}
helm.sh/chart: {{ include "platform.chart" . }}
{{ include "platform.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: {{ include "platform.component" . }}
example.com/domain: {{ include "platform.domain" . }}
{{- with .Values.environment }}
example.com/environment: {{ . }}
{{- end }}
{{- end -}}

{{/* Selector labels — stable subset, do NOT include chart/version. */}}
{{- define "platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform.component" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Image path: <registry>/<project>/<repo>:<tag> */}}
{{- define "platform.image" -}}
{{- $g := .Values.global -}}
{{- printf "%s/%s/%s:%s" $g.registry $g.imageProject .Values.image.repository (.Values.image.tag | toString) -}}
{{- end -}}

{{/*
CNPG-managed secret for the app's owner role.
Owner role name: database.owns.role if set, else the "<component>-app" convention.
Override it when the app image expects a fixed DB username (e.g. legacy apps).
CNPG generates a Secret of type kubernetes.io/basic-auth named "<cluster>-<role>"
containing username, password, host, port, dbname, uri, jdbc-uri keys.
*/}}
{{- define "platform.dbOwnerRole" -}}
{{- if and .Values.database .Values.database.owns .Values.database.owns.role -}}
{{- .Values.database.owns.role -}}
{{- else -}}
{{- printf "%s-app" (include "platform.component" .) -}}
{{- end -}}
{{- end -}}

{{/* Creds Secret name. Based on the component (always a valid RFC 1123 name), NOT the
role, since role names may legally contain chars invalid for k8s object names (e.g. '_').
Equals "<cluster>-<component>-app" — identical to the old default when role is not overridden. */}}
{{- define "platform.dbOwnerSecret" -}}
{{- printf "%s-%s-app" .Values.global.pgCluster (include "platform.component" .) -}}
{{- end -}}

{{/* envFrom block to load DB creds when database is enabled. */}}
{{- define "platform.dbEnvFrom" -}}
{{- if and .Values.database .Values.database.enabled -}}
- secretRef:
    name: {{ include "platform.dbOwnerSecret" . }}
{{- end -}}
{{- end -}}
