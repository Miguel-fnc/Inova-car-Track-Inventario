# Prepara un Learner Lab NUEVO para Inova Car. Crea lo que Terraform y la
# Lambda esperan que ya exista y que no se recrea solo:
#   1. Bucket de artefactos del sitio (Terraform lo lee como existente).
#   2. Aparta el terraform.tfstate de la cuenta anterior.
#   3. Secretos de Supabase y Telegram en Secrets Manager.
#   4. Topic SNS y suscripción de correo.
# Es seguro correrlo más de una vez: lo que ya existe se deja igual.
param(
  [string] $Region = "us-east-1",
  [string] $ProjectName = "inova-car",
  [string] $NotificationEmail = "",
  [string] $SupabaseSecretName = "SUPABASE_SECRET_KEY",
  [string] $TelegramSecretName = "TELEGRAM_TOKEN",
  [string] $SnsTopicName = "inova-invoice-notifications"
)

$ErrorActionPreference = "Stop"

function Read-SecretValue([string] $prompt) {
  $secure = Read-Host -Prompt $prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-SecretIfMissing([string] $name, [string] $jsonKey, [string] $prompt, [bool] $optional) {
  aws secretsmanager describe-secret --secret-id $name --region $Region 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { Write-Host "  Secreto '$name' ya existe."; return }

  $value = Read-SecretValue $prompt
  if (-not $value) {
    if ($optional) { Write-Warning "  Sin valor: se omite '$name'."; return }
    throw "El secreto '$name' es obligatorio."
  }

  # Write the value to a temp file so it never appears in the process arguments.
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($tmp, (@{ $jsonKey = $value } | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
    aws secretsmanager create-secret --name $name --secret-string "file://$tmp" --region $Region --query ARN --output text
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el secreto '$name'." }
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

$Account = aws sts get-caller-identity --query Account --output text --region $Region
if ($LASTEXITCODE -ne 0 -or -not $Account) { throw "No se pudo verificar la cuenta AWS activa. Actualiza ~/.aws/credentials." }
Write-Host "Cuenta activa: $Account"

# 1. Bucket de artefactos que espera Terraform (data "aws_s3_bucket" "artifacts").
$Bucket = "$ProjectName-$Account-$Region"
Write-Host "`n[1/4] Bucket de artefactos: $Bucket"
aws s3api head-bucket --bucket $Bucket --region $Region 2>$null
if ($LASTEXITCODE -eq 0) {
  Write-Host "  Ya existe."
} else {
  aws s3api create-bucket --bucket $Bucket --region $Region | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el bucket $Bucket." }
  Write-Host "  Creado."
}

# 2. El estado de Terraform de otra cuenta apunta a recursos que ya no existen.
Write-Host "`n[2/4] Estado de Terraform"
$TerraformDir = Join-Path (Split-Path -Parent $PSScriptRoot) "Terraform Deploy"
$StateFile = Join-Path $TerraformDir "terraform.tfstate"
if ((Test-Path -LiteralPath $StateFile) -and -not (Select-String -LiteralPath $StateFile -Pattern $Account -Quiet)) {
  $Archive = Join-Path $TerraformDir ("estado-anterior-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
  New-Item -ItemType Directory -Path $Archive | Out-Null
  Get-ChildItem -LiteralPath $TerraformDir -Filter "terraform.tfstate*" | Move-Item -Destination $Archive
  Write-Host "  El estado era de otra cuenta; se movió a $Archive"
} else {
  Write-Host "  Sin cambios."
}

# 3. Secretos.
Write-Host "`n[3/4] Secretos (lo que escribas no se muestra)"
New-SecretIfMissing $SupabaseSecretName "SUPABASE_SECRET_KEY" "  Secret API key de Supabase (sb_secret_...)" $false
New-SecretIfMissing $TelegramSecretName "TELEGRAM_TOKEN" "  Token del bot de Telegram (Enter para omitir)" $true

# 4. Topic SNS y suscripción de correo.
Write-Host "`n[4/4] Correo de avisos (SNS)"
$TopicArn = aws sns create-topic --name $SnsTopicName --query TopicArn --output text --region $Region
if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el topic SNS." }
if (-not $NotificationEmail) { $NotificationEmail = Read-Host "  Correo que recibe los avisos" }
$existing = aws sns list-subscriptions-by-topic --topic-arn $TopicArn --region $Region --query "Subscriptions[?Endpoint=='$NotificationEmail'].SubscriptionArn" --output text
if ($existing) {
  Write-Host "  $NotificationEmail ya está suscrito ($existing)."
} else {
  aws sns subscribe --topic-arn $TopicArn --protocol email --notification-endpoint $NotificationEmail --region $Region | Out-Null
  Write-Host "  Suscripción creada. ABRE TU CORREO y confirma el enlace de AWS Notifications."
}

Write-Host "`nListo. Siguientes pasos:"
Write-Host "  1. cd '..\Terraform Deploy'; terraform init; terraform apply; .\deploy.ps1"
Write-Host "  2. cd '..\FacturaValidatorLambda'; .\friend-policies.ps1  -> manda los JSON a tu amigo"
Write-Host "  3. Cuando tu amigo los agregue: .\build.ps1; .\deploy.ps1 -ProcessingDelaySeconds 30"
