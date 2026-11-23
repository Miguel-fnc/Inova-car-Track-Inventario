# Validador de facturas

La Lambda consume mensajes desde la cola del otro AWS account, obtiene el PDF del bucket, decodifica su QR, compara UUID/RFC/total impresos, consulta el estado del CFDI en el servicio del SAT, actualiza Supabase y publica una notificación en SNS para enviarla por email a suscriptores confirmados.

El mensaje SQS esperado es:

```json
{
  "factura_id": "UUID de la fila en Supabase",
  "s3_bucket": "invoices-inovacar",
  "s3_key": "pendientes/8026924629/53.pdf"
}
```

`factura_id` es el identificador de la fila `facturas.id`; puede ser distinto del UUID fiscal que se lee del QR. El código guarda el UUID fiscal en `cfdi_uuid`.

## Preparar Supabase

Ejecuta `supabase_migration.sql` en SQL Editor. La tabla debe tener `id` como clave única, `estatus` que acepte `creada`, `en_progreso`, `aprobada` y `rechazada`, y `s3_key`. La migración agrega `cfdi_uuid`, `validation_reason`, `email_notified_at` y `telegram_notified_at` para reducir notificaciones duplicadas al reintentar SQS. El chat de Telegram se configura una sola vez en la Lambda; no hacen falta columnas de chat en `facturas`.

Crea un secreto en AWS Secrets Manager en la cuenta de la Lambda con este JSON y guarda la Secret API key de servidor de Supabase (`sb_secret_...`) allí:

```json
{
  "SUPABASE_SECRET_KEY": "<guardar directamente en Secrets Manager>"
}
```

La Secret API key evita RLS y es privilegiada: no la pongas en el código, en Git, ni en variables de texto plano de Lambda. Esta Lambda solo la recupera desde Secrets Manager para actualizar `facturas`. La Lambda también acepta la antigua llave `service_role` si el proyecto aún no tiene una Secret API key.

Guarda el token nuevo del bot en el secreto `TELEGRAM_TOKEN` de la cuenta `290597578821`, como JSON `{"TELEGRAM_BOT_TOKEN":"<token nuevo>"}` o como valor `SecretString` sin JSON. La Lambda recibe solo el ARN `arn:aws:secretsmanager:us-east-1:290597578821:secret:TELEGRAM_TOKEN-xZI1DB` y obtiene el token durante la ejecución. Configura `TELEGRAM_CHAT_ID` con el ID numérico de la conversación que recibe los avisos. Revoca en BotFather el token que se compartió en el chat y reemplázalo en Secrets Manager antes de desplegar.

## Permisos

El rol de ejecución debe permitir:

- `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:ChangeMessageVisibility` en `arn:aws:sqs:us-east-1:563105261074:facturas-pendientes`.
- `s3:GetObject` en `arn:aws:s3:::invoices-inovacar/pendientes/*`.
- `s3:ListBucket` limitado por prefijo a `pendientes/*`, `aprobadas/*` y `rechazadas/*` para hacer idempotente el archivo del PDF.
- `s3:PutObject` en `arn:aws:s3:::invoices-inovacar/aprobadas/*` y `arn:aws:s3:::invoices-inovacar/rechazadas/*`.
- `s3:DeleteObject` en `arn:aws:s3:::invoices-inovacar/pendientes/*`.
- `secretsmanager:GetSecretValue` en el ARN del secreto Supabase.
- `secretsmanager:GetSecretValue` en el ARN del secreto del bot de Telegram.
- `sns:Publish` sobre el topic de notificaciones de facturas.
- escritura de logs en CloudWatch.

El ejemplo de policy está en `execution-policy.example.json`. Para cross-account, el rol también debe tener los permisos de identidad y el propietario de la cola/bucket debe permitir ese ARN en sus políticas de recursos. SQS y Lambda están en `us-east-1`. La cola necesita una visibilidad de al menos 360 segundos para la función configurada con timeout 60s. Pide a tu amigo una DLQ con `maxReceiveCount` de al menos 5.

### Acceso cross-account para esta integración

La Lambda está en la cuenta `290597578821` y usa el rol de ejecución `arn:aws:iam::290597578821:role/LabRole`. La cola y el bucket pertenecen a la cuenta `563105261074`:

- Cola: `arn:aws:sqs:us-east-1:563105261074:facturas-pendientes`.
- Bucket: `arn:aws:s3:::invoices-inovacar`; los PDFs procesables deben estar bajo `pendientes/`.

El dueño de esos recursos debe **agregar** el objeto JSON de `cross-account-sqs-policy-statement.json` al arreglo `Statement` de la política actual de la cola y cada objeto de `cross-account-s3-policy-statements.json` al arreglo `Statement` de la política actual del bucket. No debe reemplazar las políticas completas si ya contienen permisos para la Lambda del bot que sube los PDFs y publica en SQS. Los statements de S3 autorizan a `LabRole` a leer pendientes, consultar las claves de archivo, copiar a las carpetas finales y borrar el original. Los permisos de identidad del rol se configuran aparte con `execution-policy.example.json`.

Después de aplicar las políticas en la cuenta `563105261074`, vuelve a ejecutar `deploy.ps1` desde la cuenta `290597578821` para crear el event-source mapping SQS → Lambda. Si Learner Lab deniega `lambda:CreateEventSourceMapping`, el administrador del laboratorio debe habilitarlo; no se puede corregir esa denegación desde la política del bucket o de la cola.

La cola debe ser Standard y estar en la misma región que Lambda (`us-east-1`). Configura `VisibilityTimeout` en al menos 360 segundos (6 × el timeout de 60 segundos de Lambda) y una redrive policy hacia una DLQ para errores técnicos agotados. Un PDF que se valida como inválido es un resultado de negocio: se actualiza a `rechazada`, se notifica y se confirma el mensaje; no se manda a DLQ.

## Archivo de PDFs procesados

Después de guardar el resultado y enviar las notificaciones por SNS y Telegram, la Lambda copia el objeto a `aprobadas/<factura_id>/<ruta-original>` o `rechazadas/<factura_id>/<ruta-original>`, borra el objeto de `pendientes/` y actualiza `facturas.s3_key` con la ruta final. Telegram siempre recibe el aviso en el chat configurado en `TELEGRAM_CHAT_ID`. Si el PDF es inválido, se archiva bajo `rechazadas/`. El movimiento es idempotente para tolerar reintentos de SQS; por eso se requieren los permisos S3 adicionales anteriores. Si se habilita cifrado KMS con una clave administrada por el cliente, su key policy también debe permitir el uso de la clave al rol.

## Correo con SNS

La cuenta Learner Lab deniega SES, por lo que la notificación usa SNS. Crea el topic `inova-invoice-notifications` en `us-east-1`, agrega una suscripción de protocolo `Email` con el correo destinatario y confirma el enlace recibido en ese correo. Lambda publicará el resultado en ese topic; solo los suscriptores confirmados reciben el aviso. Si el SAT, Supabase o SNS no responden, el mensaje se reporta como fallo parcial para que SQS lo reintente; no se rechaza por una falla temporal.

## Configurar RFC esperado

`EXPECTED_RFC_RECEPTOR` es opcional. Si se configura, la Lambda rechazará CFDI emitidos a otro RFC. Si lo dejas vacío, valida que el comprobante esté `Vigente` en el SAT y que UUID, RFCs y total impresos coincidan con el QR.

## Desplegar

Requisitos: Python 3.12 o posterior, AWS CLI con sesión de tu cuenta `290597578821`, permisos para desplegar/actualizar Lambda y un rol de ejecución ya existente. El empaquetado descarga wheels Linux compatibles desde PyPI y no requiere Docker. El Learner Lab había denegado `iam:CreateRole`; si sigue así, no crees el rol con Terraform: usa un rol que el laboratorio permita configurar.

Desde esta carpeta:

```powershell
.\build.ps1
```

Luego despliega o actualiza la Lambda y configura su trigger SQS:

```powershell
.\deploy.ps1 `
  -ExecutionRoleArn "arn:aws:iam::290597578821:role/<rol-de-ejecucion>" `
  -SupabaseUrl "https://<project-ref>.supabase.co" `
  -SupabaseSecretArn "arn:aws:secretsmanager:us-east-1:290597578821:secret:<secreto>" `
  -SnsTopicArn "arn:aws:sns:us-east-1:290597578821:inova-invoice-notifications" `
  -ExpectedReceiverRfc "<RFC-receptor>"
```

No pongas la llave `service_role` como parámetro del comando. Si no se requiere validar un RFC receptor concreto, omite `-ExpectedReceiverRfc`.

## Estados y entrega

- QR, datos impresos y consulta SAT con estado `Vigente`: `aprobada`.
- PDF/QR inválido, RFC/total discordantes, CFDI no encontrado o cancelado: `rechazada`.
- Falla temporal del SAT/Supabase/SNS: SQS reintenta y manda a DLQ si se agotan los intentos.

Lambda/SQS entrega al menos una vez. El estado de Supabase se actualiza idempotentemente por `factura_id`; `email_notified_at` reduce avisos repetidos. Si SNS acepta una publicación pero la conexión falla antes de guardar la marca, podría enviarse un correo duplicado en el reintento.

La validación compara campos clave del PDF con el QR y confirma el UUID/RFC/total con el servicio SAT. No sustituye una revisión contable ni verifica que los conceptos impresos sean correctos; para verificar el contenido íntegro del comprobante, conserva y procesa también el XML CFDI.
