{{- define "app.connector.orders" -}}
table.include.list: {{ index .file "table.include.list" | replace "public\\." (printf "%s\\." .context.Values.global.database.schema.value) }}
{{- end -}}
