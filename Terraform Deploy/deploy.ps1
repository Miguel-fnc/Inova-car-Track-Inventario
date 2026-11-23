# Publica el sitio y la API en el bucket privado; las EC2 los sincronizan desde S3.
$ErrorActionPreference = "Stop"

$TerraformDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $TerraformDir
$IndexFile = Join-Path $ProjectRoot "index.html"
$CssDir = Join-Path $ProjectRoot "CSS"
$JsDir = Join-Path $ProjectRoot "JS"
$ApiDir = Join-Path $ProjectRoot "api"
$ApiEnvFile = Join-Path $ApiDir ".env"

if (-not (Test-Path -LiteralPath $ApiEnvFile)) {
  throw "Falta api\.env. Debe contener SUPABASE_URL, SUPABASE_ANON_KEY, PORT y REDIS_URL."
}

$ArtifactBucket = terraform -chdir="$TerraformDir" output -raw s3_artifact_bucket
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ArtifactBucket)) {
  throw "No se obtuvo el bucket de artefactos. Ejecuta terraform apply primero."
}

$ApiUrl = terraform -chdir="$TerraformDir" output -raw api_url
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ApiUrl)) {
  throw "No se obtuvo la URL del API Gateway. Ejecuta terraform apply primero."
}

$ApiConfigFile = Join-Path $JsDir "api-config.js"
$ApiConfigContent = "// Generado por Terraform Deploy/deploy.ps1.`nexport const API_BASE_URL = `"$ApiUrl`";`n"
[System.IO.File]::WriteAllText($ApiConfigFile, $ApiConfigContent, [System.Text.UTF8Encoding]::new($false))

$SitePrefix = "s3://$ArtifactBucket/site"
Write-Host "Subiendo el frontend a $SitePrefix ..."
aws s3 cp "$IndexFile" "$SitePrefix/index.html"
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir index.html." }

Get-ChildItem -LiteralPath $ProjectRoot -Filter "*.html" -File | Where-Object { $_.Name -ne "index.html" } | ForEach-Object {
  aws s3 cp $_.FullName "$SitePrefix/$($_.Name)"
  if ($LASTEXITCODE -ne 0) { throw "No se pudo subir $($_.Name)." }
}

aws s3 sync "$CssDir" "$SitePrefix/CSS" --delete
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir CSS." }
aws s3 sync "$JsDir" "$SitePrefix/JS" --delete
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir JS." }

$ApiPrefix = "s3://$ArtifactBucket/site/api"
Write-Host "Subiendo la API al bucket privado $ApiPrefix ..."
aws s3 sync "$ApiDir" "$ApiPrefix" --delete --exclude ".env" --exclude ".env.example" --exclude "node_modules/*" --exclude "package-lock.json"
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir el backend." }

aws s3 cp "$ApiEnvFile" "$ApiPrefix/.env"
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir la configuración privada de la API." }

$WebsiteUrl = terraform -chdir="$TerraformDir" output -raw website_url
$AsgName = terraform -chdir="$TerraformDir" output -raw autoscaling_group_name
Write-Host ""
Write-Host "Carga completada. Sitio: $WebsiteUrl"
Write-Host "API Gateway: $ApiUrl"
Write-Host "Auto Scaling Group: $AsgName"
Write-Host "Las EC2 sincronizan el sitio y la API desde S3 aproximadamente cada minuto."
