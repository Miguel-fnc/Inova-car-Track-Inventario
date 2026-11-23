param(
  [Parameter(Mandatory = $true)] [string] $ExecutionRoleArn,
  [Parameter(Mandatory = $true)] [string] $SupabaseUrl,
  [Parameter(Mandatory = $true)] [string] $SupabaseSecretArn,
  [Parameter(Mandatory = $true)] [string] $SnsTopicArn,
  [string] $TelegramTokenSecretArn = "arn:aws:secretsmanager:us-east-1:290597578821:secret:TELEGRAM_TOKEN-xZI1DB",
  [string] $TelegramChatId = "8026924629",
  [string] $ExpectedReceiverRfc = "",
  [string] $FunctionName = "inova-validar-facturas",
  [string] $QueueArn = "arn:aws:sqs:us-east-1:563105261074:facturas-pendientes",
  [string] $Region = "us-east-1"
)

$ErrorActionPreference = "Stop"
$Package = Join-Path $PSScriptRoot "lambda_function.zip"
$EnvironmentFile = Join-Path $PSScriptRoot "lambda-environment.tmp.json"

if (-not (Test-Path -LiteralPath $Package)) {
  throw "No existe lambda_function.zip. Ejecuta .\build.ps1 primero."
}

$variables = @{
  SUPABASE_URL = $SupabaseUrl.TrimEnd('/')
  SUPABASE_SECRET_ARN = $SupabaseSecretArn
  SNS_TOPIC_ARN = $SnsTopicArn
  TELEGRAM_BOT_TOKEN_SECRET_ARN = $TelegramTokenSecretArn
  TELEGRAM_CHAT_ID = $TelegramChatId.Trim()
  S3_BUCKET_ALLOWED = "invoices-inovacar"
  S3_KEY_PREFIX = "pendientes/"
  INVOICE_TABLE = "facturas"
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
    if ($LASTEXITCODE -ne 0) { throw "No se pudo conectar la cola SQS con Lambda. Revisa la política cross-account de la cola y el rol." }
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
