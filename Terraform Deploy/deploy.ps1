# Sube la web y la API a S3. La EC2 las sincroniza aproximadamente cada minuto.
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

$Bucket = terraform -chdir="$TerraformDir" output -raw s3_artifact_bucket
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Bucket)) {
  throw "No se obtuvo el bucket. Ejecuta terraform apply primero."
}

$ApiUrl = terraform -chdir="$TerraformDir" output -raw api_url
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ApiUrl)) {
  throw "No se obtuvo la URL del API Gateway. Ejecuta terraform apply primero."
}

$ApiConfigFile = Join-Path $JsDir "api-config.js"
$ApiConfigContent = "// Generado por Terraform Deploy/deploy.ps1.`nexport const API_BASE_URL = `"$ApiUrl`";`n"
[System.IO.File]::WriteAllText($ApiConfigFile, $ApiConfigContent, [System.Text.UTF8Encoding]::new($false))

$Prefix = "s3://$Bucket/site"
Write-Host "Subiendo archivos HTML, CSS y JavaScript a $Prefix ..."
aws s3 cp "$IndexFile" "$Prefix/index.html"
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir index.html." }

Get-ChildItem -LiteralPath $ProjectRoot -Filter "*.html" -File | Where-Object { $_.Name -ne "index.html" } | ForEach-Object {
  aws s3 cp $_.FullName "$Prefix/$($_.Name)"
  if ($LASTEXITCODE -ne 0) { throw "No se pudo subir $($_.Name)." }
}

aws s3 sync "$CssDir" "$Prefix/CSS" --delete
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir CSS." }
aws s3 sync "$JsDir" "$Prefix/JS" --delete
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir JS." }

$ApiPrefix = "$Prefix/api"
Write-Host "Subiendo la API privada a $ApiPrefix ..."
aws s3 sync "$ApiDir" "$ApiPrefix" --delete --exclude ".env" --exclude ".env.example" --exclude "node_modules/*" --exclude "package-lock.json"
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir el backend." }

aws s3 cp "$ApiEnvFile" "$ApiPrefix/.env"
if ($LASTEXITCODE -ne 0) { throw "No se pudo subir la configuración privada de la API." }

$WebsiteUrl = terraform -chdir="$TerraformDir" output -raw website_url
Write-Host ""
Write-Host "Carga completada. URL del sitio: $WebsiteUrl"
Write-Host "URL del API Gateway: $ApiUrl"
Write-Host "La EC2 sincroniza la web y la API aproximadamente cada minuto."
