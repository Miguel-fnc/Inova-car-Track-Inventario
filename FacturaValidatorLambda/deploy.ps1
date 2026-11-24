# Todo lo que depende de la cuenta (rol, secretos, topic) se detecta solo, así
# el mismo comando sirve en cualquier Learner Lab. Puedes pasar los ARN a mano
# si usas nombres distintos.
param(
  [string] $ExecutionRoleArn = "",
  [string] $SupabaseUrl = "https://kxvedkhwuivbefdgrrzt.supabase.co",
  [string] $SupabaseSecretArn = "",
  [string] $SnsTopicArn = "",
  [string] $TelegramTokenSecretArn = "",
  [string[]] $SupabaseSecretName = @("SUPABASE_SECRET_KEY", "Supabase_secret"),
  [string] $TelegramSecretName = "TELEGRAM_TOKEN",
  [string] $SnsTopicName = "inova-invoice-notifications",
  [string] $TelegramChatId = "8026924629",
  [string] $ExpectedReceiverRfc = "",
  [ValidateRange(0, 40)] [int] $ProcessingDelaySeconds = 0,
  [string] $FunctionName = "inova-validar-facturas",
  [string] $QueueArn = "arn:aws:sqs:us-east-1:563105261074:facturas-pendientes",
  [string] $Region = "us-east-1"
)

# "Continue": in Windows PowerShell 5.1, "Stop" turns any aws CLI stderr output
# (e.g. "function not found" on first deploy) into a terminating error even
# when redirected. Every aws call below checks $LASTEXITCODE explicitly.
$ErrorActionPreference = "Continue"
$Package = Join-Path $PSScriptRoot "lambda_function.zip"
$EnvironmentFile = Join-Path $PSScriptRoot "lambda-environment.tmp.json"

if (-not (Test-Path -LiteralPath $Package)) {
  throw "No existe lambda_function.zip. Ejecuta .\build.ps1 primero."
}

$Account = aws sts get-caller-identity --query Account --output text --region $Region
if ($LASTEXITCODE -ne 0 -or -not $Account) { throw "No se pudo verificar la cuenta AWS activa. Actualiza ~/.aws/credentials." }
Write-Host "Cuenta activa: $Account"

if (-not $ExecutionRoleArn) { $ExecutionRoleArn = "arn:aws:iam::${Account}:role/LabRole" }

if (-not $SupabaseSecretArn) {
  # Accept either name; earlier labs used both.
  foreach ($name in $SupabaseSecretName) {
    $SupabaseSecretArn = aws secretsmanager describe-secret --secret-id $name --query ARN --output text --region $Region 2>$null
    if ($LASTEXITCODE -eq 0 -and $SupabaseSecretArn) { break }
    $SupabaseSecretArn = ""
  }
  if (-not $SupabaseSecretArn) { throw "No existe ningún secreto de Supabase ($($SupabaseSecretName -join ' o ')). Créalo con .\setup-new-lab.ps1." }
}

if (-not $TelegramTokenSecretArn) {
  $TelegramTokenSecretArn = aws secretsmanager describe-secret --secret-id $TelegramSecretName --query ARN --output text --region $Region 2>$null
  if ($LASTEXITCODE -ne 0) {
    $TelegramTokenSecretArn = ""
    Write-Warning "No existe el secreto '$TelegramSecretName'; la Lambda funcionará sin avisos de Telegram."
  }
}

if (-not $SnsTopicArn) {
  # create-topic es idempotente: devuelve el ARN si el topic ya existe.
  $SnsTopicArn = aws sns create-topic --name $SnsTopicName --query TopicArn --output text --region $Region
  if ($LASTEXITCODE -ne 0 -or -not $SnsTopicArn) { throw "No se pudo obtener el topic SNS '$SnsTopicName'." }
}

Write-Host "Rol: $ExecutionRoleArn"
Write-Host "Secreto Supabase: $SupabaseSecretArn"
Write-Host "Topic SNS: $SnsTopicArn"

$variables = @{
  SUPABASE_URL = $SupabaseUrl.TrimEnd('/')
  SUPABASE_SECRET_ARN = $SupabaseSecretArn
  SNS_TOPIC_ARN = $SnsTopicArn
  TELEGRAM_BOT_TOKEN_SECRET_ARN = $TelegramTokenSecretArn
  TELEGRAM_CHAT_ID = $TelegramChatId.Trim()
  S3_BUCKET_ALLOWED = "invoices-inovacar"
  S3_KEY_PREFIX = "pendientes/"
  INVOICE_TABLE = "facturas"
  PROCESSING_DELAY_SECONDS = "$ProcessingDelaySeconds"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedReceiverRfc)) {
  $variables.EXPECTED_RFC_RECEPTOR = $ExpectedReceiverRfc
}
$environment = @{ Variables = $variables } | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($EnvironmentFile, $environment, [System.Text.UTF8Encoding]::new($false))

try {
  aws sts get-caller-identity --query Account --output text --region $Region | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "No se pudo verificar la cuenta AWS activa." }

  aws lambda get-function --function-name $FunctionName --region $Region 2>$null | Out-Null
  $functionExists = ($LASTEXITCODE -eq 0)

  if ($functionExists) {
    aws lambda update-function-code --function-name $FunctionName --zip-file "fileb://$Package" --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar el código de Lambda." }
    aws lambda wait function-updated-v2 --function-name $FunctionName --region $Region
    aws lambda update-function-configuration --function-name $FunctionName --runtime python3.12 --handler lambda_function.lambda_handler --timeout 60 --memory-size 1024 --environment "file://$EnvironmentFile" --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar la configuración de Lambda." }
  } else {
    aws lambda create-function --function-name $FunctionName --runtime python3.12 --handler lambda_function.lambda_handler --role $ExecutionRoleArn --timeout 60 --memory-size 1024 --architectures x86_64 --zip-file "fileb://$Package" --environment "file://$EnvironmentFile" --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear Lambda. Revisa que el rol exista y que tu Learner Lab permita lambda:CreateFunction." }
  }

  aws lambda wait function-active-v2 --function-name $FunctionName --region $Region

  $mappingUuid = aws lambda list-event-source-mappings --function-name $FunctionName --event-source-arn $QueueArn --query "EventSourceMappings[0].UUID" --output text --region $Region
  if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar el trigger SQS." }

  if ([string]::IsNullOrWhiteSpace($mappingUuid) -or $mappingUuid -eq "None") {
    aws lambda create-event-source-mapping --function-name $FunctionName --event-source-arn $QueueArn --batch-size 1 --function-response-types ReportBatchItemFailures --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo conectar la cola SQS con Lambda. Genera los permisos con .\friend-policies.ps1, pide al dueño de la cola que los agregue y vuelve a correr este script." }
  } else {
    aws lambda update-event-source-mapping --uuid $mappingUuid --batch-size 1 --function-response-types ReportBatchItemFailures --enabled --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo actualizar el trigger SQS." }
  }

  Write-Host "Lambda lista: $FunctionName"
  Write-Host "Cola conectada: $QueueArn"
  Write-Host "Cuenta activa: $(aws sts get-caller-identity --query Account --output text --region $Region)"
} finally {
  Remove-Item -LiteralPath $EnvironmentFile -ErrorAction SilentlyContinue
}
