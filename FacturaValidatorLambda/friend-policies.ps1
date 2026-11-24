# Genera los statements que el dueño de la cola SQS y del bucket S3 debe
# AGREGAR (no reemplazar) a sus políticas para autorizar al LabRole de la
# cuenta AWS activa. Úsalo cada vez que cambies de Learner Lab.
param(
  [string] $Region = "us-east-1",
  [string] $QueueArn = "arn:aws:sqs:us-east-1:563105261074:facturas-pendientes",
  [string] $BucketName = "invoices-inovacar"
)

$ErrorActionPreference = "Stop"

$Account = aws sts get-caller-identity --query Account --output text --region $Region
if ($LASTEXITCODE -ne 0 -or -not $Account) { throw "No se pudo verificar la cuenta AWS activa. Actualiza ~/.aws/credentials." }
$RoleArn = "arn:aws:iam::${Account}:role/LabRole"

$sqs = [ordered]@{
  Sid       = "AllowInovaLambdaToConsumeInvoices"
  Effect    = "Allow"
  Principal = @{ AWS = $RoleArn }
  Action    = @("sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility")
  Resource  = $QueueArn
}

$s3 = @(
  [ordered]@{
    Sid = "AllowInovaLambdaReadPendingInvoices"; Effect = "Allow"; Principal = @{ AWS = $RoleArn }
    Action = "s3:GetObject"; Resource = "arn:aws:s3:::$BucketName/pendientes/*"
  },
  [ordered]@{
    Sid = "AllowInovaLambdaCheckInvoiceArchiveKeys"; Effect = "Allow"; Principal = @{ AWS = $RoleArn }
    Action = "s3:ListBucket"; Resource = "arn:aws:s3:::$BucketName"
    Condition = @{ StringLike = @{ "s3:prefix" = @("pendientes/*", "aprobadas/*", "rechazadas/*") } }
  },
  [ordered]@{
    Sid = "AllowInovaLambdaArchiveInvoicePdfs"; Effect = "Allow"; Principal = @{ AWS = $RoleArn }
    Action = "s3:PutObject"; Resource = @("arn:aws:s3:::$BucketName/aprobadas/*", "arn:aws:s3:::$BucketName/rechazadas/*")
  },
  [ordered]@{
    Sid = "AllowInovaLambdaRemovePendingInvoicePdfs"; Effect = "Allow"; Principal = @{ AWS = $RoleArn }
    Action = "s3:DeleteObject"; Resource = "arn:aws:s3:::$BucketName/pendientes/*"
  }
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
$sqsFile = Join-Path $PSScriptRoot "cross-account-sqs-policy-statement.json"
$s3File = Join-Path $PSScriptRoot "cross-account-s3-policy-statements.json"
[System.IO.File]::WriteAllText($sqsFile, ($sqs | ConvertTo-Json -Depth 6), $utf8)
[System.IO.File]::WriteAllText($s3File, (ConvertTo-Json -InputObject $s3 -Depth 6), $utf8)

Write-Host "Permisos generados para el rol $RoleArn"
Write-Host "  Cola SQS : $sqsFile"
Write-Host "  Bucket S3: $s3File"
Write-Host ""
Write-Host "Mándale ambos archivos al dueño de la cola/bucket. Debe AGREGAR los statements"
Write-Host "al arreglo 'Statement' de sus políticas actuales (sin borrar los que ya tiene),"
Write-Host "o mejor aún, meterlos en su Terraform para que no se pierdan al reiniciar su lab."
