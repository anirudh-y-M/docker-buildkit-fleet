{{/*
Resource name prefix: "<namePrefix>-<arch>" names every per-architecture object.
*/}}
{{- define "buildkit-fleet.prefix" -}}
{{- .Values.namePrefix | default "buildkit" -}}
{{- end }}

{{- define "buildkit-fleet.archName" -}}
{{- printf "%s-%s" (include "buildkit-fleet.prefix" .root) .arch -}}
{{- end }}

{{/* Standard labels for metadata. Selector labels are kept separate and stable. */}}
{{- define "buildkit-fleet.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* Selector labels: short and stable so they survive chart upgrades. */}}
{{- define "buildkit-fleet.selectorLabels" -}}
app: {{ include "buildkit-fleet.prefix" .root }}
arch: {{ .arch }}
{{- end }}

{{- define "buildkit-fleet.image" -}}
{{- $i := .Values.image -}}
{{- printf "%s:%s" $i.repository $i.tag -}}{{- with $i.digest }}@{{ . }}{{- end -}}
{{- end }}

{{/* Issuer used for every leaf certificate. */}}
{{- define "buildkit-fleet.issuerName" -}}
{{- if .Values.trust.issuerRef.name -}}
{{- .Values.trust.issuerRef.name -}}
{{- else -}}
{{- printf "%s-ca-issuer" (include "buildkit-fleet.prefix" .) -}}
{{- end -}}
{{- end }}

{{/* StorageClass name for an architecture, or empty for the cluster default. */}}
{{- define "buildkit-fleet.storageClassName" -}}
{{- if .cfg.storageClass.create -}}
{{- .cfg.storageClass.name | default (include "buildkit-fleet.archName" .) -}}
{{- else -}}
{{- .cfg.storage.storageClassName -}}
{{- end -}}
{{- end }}

{{/*
Render a values string through tpl with per-architecture context:
.arch and .name are available alongside the usual .Values/.Release/.Chart.
*/}}
{{- define "buildkit-fleet.tplArch" -}}
{{- $ctx := dict "Values" .root.Values "Release" .root.Release "Chart" .root.Chart "Template" .root.Template "Capabilities" .root.Capabilities "arch" .arch "name" .name -}}
{{- tpl .tmpl $ctx -}}
{{- end }}
