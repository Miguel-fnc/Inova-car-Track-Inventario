# Sube la web a S3. La EC2 copia los cambios aproximadamente cada minuto.
$ErrorActionPreference = "Stop"

$TerraformDir = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $TerraformDir
$IndexFile = Join-Path $ProjectRoot "index.html"
$CssDir = Join-Path $ProjectRoot "CSS"
$JsDir = Join-Path $ProjectRoot "JS"

$Bucket = terraform -chdir="$TerraformDir" output -raw s3_artifact_bucket
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Bucket)) {
  throw "No se obtuvo el bucket. Ejecuta terraform apply primero."
}

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

$WebsiteUrl = terraform -chdir="$TerraformDir" output -raw website_url
Write-Host ""
Write-Host "Carga completada. URL del sitio: $WebsiteUrl"
Write-Host "La EC2 sincroniza los archivos de S3 aproximadamente cada minuto."

