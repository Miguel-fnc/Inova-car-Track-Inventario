import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

import boto3
import pymupdf
import zxingcpp
from PIL import Image
from botocore.exceptions import ClientError


S3_BUCKET_ALLOWED = os.environ.get("S3_BUCKET_ALLOWED", "invoices-inovacar")
S3_KEY_PREFIX = os.environ.get("S3_KEY_PREFIX", "pendientes/")
MAX_PDF_BYTES = int(os.environ.get("MAX_PDF_BYTES", str(10 * 1024 * 1024)))
MAX_PDF_PAGES = int(os.environ.get("MAX_PDF_PAGES", "12"))
SAT_TIMEOUT_SECONDS = int(os.environ.get("SAT_TIMEOUT_SECONDS", "15"))
SAT_ENDPOINT = "https://consultaqr.facturaelectronica.sat.gob.mx/ConsultaCFDIService.svc"
SAT_QR_HOST = "verificacfdi.facturaelectronica.sat.gob.mx"
SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SUPABASE_SECRET_ARN = os.environ["SUPABASE_SECRET_ARN"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
TELEGRAM_BOT_TOKEN_SECRET_ARN = os.environ.get("TELEGRAM_BOT_TOKEN_SECRET_ARN", "")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
EXPECTED_RFC_RECEPTOR = re.sub(
    r"[^A-Z0-9&Ñ]", "", os.environ.get("EXPECTED_RFC_RECEPTOR", "").upper()
)
INVOICE_TABLE = os.environ.get("INVOICE_TABLE", "facturas")
# Status shown while the invoice is being validated. Matches what the bot uses.
IN_PROGRESS_STATUS = os.environ.get("IN_PROGRESS_STATUS", "EN_PROCESO")
# Optional pause after marking the invoice in progress, so dashboards that poll
# Supabase every N seconds can observe it. Capped to stay under the 60s timeout.
PROCESSING_DELAY_SECONDS = min(
    max(int(os.environ.get("PROCESSING_DELAY_SECONDS", "0")), 0), 40
)
ARCHIVE_PREFIX_BY_STATUS = {
    "aprobada": "aprobadas/",
    "rechazada": "rechazadas/",
}

s3 = boto3.client("s3")
sns = boto3.client("sns", region_name=AWS_REGION)
secrets = boto3.client("secretsmanager", region_name=AWS_REGION)

_supabase_key = None
_telegram_bot_token = None


class InvalidInvoice(Exception):
    """A permanent document/content rejection; update Supabase and acknowledge."""


class RetryableProcessingError(Exception):
    """A temporary dependency or service failure; let SQS retry the message."""


def _get_supabase_key():
    global _supabase_key
    if _supabase_key:
        return _supabase_key

    result = secrets.get_secret_value(SecretId=SUPABASE_SECRET_ARN)
    secret_string = result.get("SecretString", "")
    try:
        secret_data = json.loads(secret_string)
    except json.JSONDecodeError:
        secret_data = {"SUPABASE_SERVICE_ROLE_KEY": secret_string}

    _supabase_key = (
        secret_data.get("SUPABASE_SECRET_KEY")
        or secret_data.get("SUPABASE_SERVICE_ROLE_KEY")
        or secret_data.get("secret_key")
        or secret_data.get("service_role")
        or secret_data.get("service_role_key")
    )
    if not _supabase_key:
        raise RetryableProcessingError(
            "El secreto de Supabase no contiene SUPABASE_SECRET_KEY."
        )
    return _supabase_key


def _get_telegram_bot_token():
    global _telegram_bot_token
    if _telegram_bot_token:
        return _telegram_bot_token
    if not TELEGRAM_BOT_TOKEN_SECRET_ARN:
        raise RetryableProcessingError(
            "Falta configurar el ARN del secreto del bot de Telegram."
        )

    try:
        result = secrets.get_secret_value(SecretId=TELEGRAM_BOT_TOKEN_SECRET_ARN)
        secret_string = result.get("SecretString", "").strip()
        try:
            secret_data = json.loads(secret_string)
        except json.JSONDecodeError:
            secret_data = {"TELEGRAM_BOT_TOKEN": secret_string}

        _telegram_bot_token = (
            secret_data.get("TELEGRAM_BOT_TOKEN")
            or secret_data.get("TELEGRAM_TOKEN")
            or secret_data.get("telegram_bot_token")
            or secret_data.get("token")
        )
        if not _telegram_bot_token:
            raise RetryableProcessingError(
                "El secreto de Telegram no contiene TELEGRAM_BOT_TOKEN."
            )
        return _telegram_bot_token
    except RetryableProcessingError:
        raise
    except Exception as error:
        # Do not include the secret value or Telegram URL in logs/errors.
        raise RetryableProcessingError(
            f"No se pudo leer el secreto del bot de Telegram ({type(error).__name__})."
        ) from error


def _supabase_request(method, path, payload=None, prefer=None):
    key = _get_supabase_key()
    headers = {"apikey": key, "Content-Type": "application/json"}
    # New sb_secret_* keys are not JWTs and must not be sent as Bearer tokens.
    # Keep Bearer support for the legacy service_role JWT key.
    if key.startswith("eyJ"):
        headers["Authorization"] = f"Bearer {key}"
    if prefer:
        headers["Prefer"] = prefer

    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}", data=body, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            response_body = response.read().decode("utf-8")
            return json.loads(response_body) if response_body else []
    except urllib.error.HTTPError as error:
        message = error.read().decode("utf-8", errors="replace")[:500]
        if error.code >= 500 or error.code in (408, 429):
            raise RetryableProcessingError(
                f"Supabase temporalmente no disponible ({error.code})."
            ) from error
        raise RetryableProcessingError(
            f"Supabase rechazó la operación ({error.code}): {message}"
        ) from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise RetryableProcessingError("No se pudo conectar con Supabase.") from error


def _invoice_path(
    invoice_id,
    select=(
        "id,estatus,email_notified_at,cfdi_uuid,validation_reason,s3_key,"
        "telegram_notified_at"
    ),
):
    query = urllib.parse.urlencode(
        {"id": f"eq.{invoice_id}", "select": select, "limit": "1"}
    )
    return f"{INVOICE_TABLE}?{query}"


def _get_invoice(invoice_id):
    rows = _supabase_request("GET", _invoice_path(invoice_id))
    return rows[0] if rows else None


def _save_invoice_result(invoice_id, status, cfdi_uuid, reason):
    payload = {
        "estatus": status,
        "cfdi_uuid": cfdi_uuid,
        "validation_reason": reason[:1000],
    }
    filter_query = urllib.parse.urlencode({"id": f"eq.{invoice_id}"})
    rows = _supabase_request(
        "PATCH",
        f"{INVOICE_TABLE}?{filter_query}",
        payload,
        prefer="return=representation",
    )
    if rows:
        return

    payload["id"] = invoice_id
    payload["created_at"] = datetime.now(timezone.utc).isoformat()
    _supabase_request(
        "POST",
        INVOICE_TABLE,
        payload,
        prefer="return=minimal",
    )


def _mark_in_progress(invoice_id):
    """Set the in-progress status if the row exists; a missing row is inserted later."""
    filter_query = urllib.parse.urlencode({"id": f"eq.{invoice_id}"})
    _supabase_request(
        "PATCH",
        f"{INVOICE_TABLE}?{filter_query}",
        {"estatus": IN_PROGRESS_STATUS},
        prefer="return=minimal",
    )


def _save_invoice_s3_key(invoice_id, s3_key):
    filter_query = urllib.parse.urlencode({"id": f"eq.{invoice_id}"})
    rows = _supabase_request(
        "PATCH",
        f"{INVOICE_TABLE}?{filter_query}",
        {"s3_key": s3_key},
        prefer="return=representation",
    )
    if not rows:
        raise RetryableProcessingError(
            "No se pudo guardar en Supabase la ruta final del PDF."
        )


def _mark_email_notified(invoice_id):
    filter_query = urllib.parse.urlencode({"id": f"eq.{invoice_id}"})
    _supabase_request(
        "PATCH",
        f"{INVOICE_TABLE}?{filter_query}",
        {"email_notified_at": datetime.now(timezone.utc).isoformat()},
        prefer="return=minimal",
    )


def _mark_telegram_notified(invoice_id):
    filter_query = urllib.parse.urlencode({"id": f"eq.{invoice_id}"})
    _supabase_request(
        "PATCH",
        f"{INVOICE_TABLE}?{filter_query}",
        {"telegram_notified_at": datetime.now(timezone.utc).isoformat()},
        prefer="return=minimal",
    )


def _notify(invoice_id, status, reason, cfdi_uuid):
    label = "aprobada" if status == "aprobada" else "rechazada"
    subject = f"Factura {label}: {invoice_id}"
    body = "\n".join(
        [
            "Se procesó una factura de Inova Car.",
            f"ID interno: {invoice_id}",
            f"Resultado: {label}",
            f"Folio fiscal SAT: {cfdi_uuid or 'No disponible'}",
            f"Motivo: {reason}",
            f"Fecha UTC: {datetime.now(timezone.utc).isoformat()}",
        ]
    )
    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject[:100],
            Message=body,
        )
    except Exception as error:
        raise RetryableProcessingError(
            f"SNS no pudo publicar el aviso ({type(error).__name__})."
        ) from error

    _mark_email_notified(invoice_id)


def _notify_telegram(invoice_id, status, reason, cfdi_uuid):
    if not TELEGRAM_CHAT_ID:
        raise RetryableProcessingError(
            "Falta configurar TELEGRAM_CHAT_ID en la Lambda."
        )
    token = _get_telegram_bot_token()
    label = "APROBADA" if status == "aprobada" else "RECHAZADA"
    symbol = "✅" if status == "aprobada" else "❌"
    text = "\n".join(
        [
            f"{symbol} Factura {label}",
            f"ID: {invoice_id}",
            f"Folio fiscal: {cfdi_uuid or 'No disponible'}",
            f"Motivo: {reason or 'Sin observaciones'}",
        ]
    )[:4096]

    payload = {"chat_id": TELEGRAM_CHAT_ID, "text": text}

    request = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.loads(response.read().decode("utf-8"))
        if not result.get("ok"):
            raise RetryableProcessingError(
                "Telegram rechazó el mensaje de estado de la factura."
            )
    except RetryableProcessingError:
        raise
    except urllib.error.HTTPError as error:
        # HTTPError.url contains the bot token; never log or propagate it.
        raise RetryableProcessingError(
            f"Telegram rechazó el mensaje (HTTP {error.code})."
        ) from None
    except Exception as error:
        # Network exception text can contain the request URL and token.
        raise RetryableProcessingError(
            f"No se pudo enviar el mensaje a Telegram ({type(error).__name__})."
        ) from None

    _mark_telegram_notified(invoice_id)


def _normalize_text(value):
    return re.sub(r"[^A-Z0-9Ñ&]", "", value.upper())


def _parse_qr_payload(qr_text):
    parsed = urllib.parse.urlparse(qr_text)
    if parsed.scheme != "https" or parsed.netloc.lower() != SAT_QR_HOST:
        raise InvalidInvoice("El QR no apunta al verificador oficial de CFDI del SAT.")
    if not parsed.path.lower().endswith("default.aspx"):
        raise InvalidInvoice("El QR no tiene la ruta de verificación de CFDI esperada.")

    values = urllib.parse.parse_qs(parsed.query)
    required = ("id", "re", "rr", "tt", "fe")
    if any(not values.get(name) for name in required):
        raise InvalidInvoice("El QR no contiene todos los datos necesarios para verificar el CFDI.")

    invoice = {name: values[name][0].strip() for name in required}
    if not re.fullmatch(
        r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        invoice["id"],
    ):
        raise InvalidInvoice("El folio fiscal del QR no tiene formato UUID.")
    invoice["id"] = invoice["id"].upper()
    invoice["re"] = invoice["re"].upper()
    invoice["rr"] = invoice["rr"].upper()
    return invoice


def _render_and_read_qr(pdf_bytes):
    try:
        document = pymupdf.open(stream=pdf_bytes, filetype="pdf")
    except Exception as error:
        raise InvalidInvoice("El archivo no se puede abrir como PDF.") from error

    if document.is_encrypted:
        raise InvalidInvoice("El PDF está protegido con contraseña.")
    if document.page_count < 1 or document.page_count > MAX_PDF_PAGES:
        raise InvalidInvoice(f"El PDF debe tener entre 1 y {MAX_PDF_PAGES} páginas.")

    text = "\n".join(page.get_text("text") for page in document)
    barcodes = []
    for page in document:
        pixmap = page.get_pixmap(
            matrix=pymupdf.Matrix(2.5, 2.5),
            colorspace=pymupdf.csRGB,
            alpha=False,
        )
        image = Image.frombytes("RGB", (pixmap.width, pixmap.height), pixmap.samples)
        try:
            barcodes.extend(zxingcpp.read_barcodes(image))
        except Exception as error:
            raise RetryableProcessingError("No se pudo ejecutar el lector QR.") from error

    document.close()
    for barcode in barcodes:
        if barcode.format == zxingcpp.BarcodeFormat.QRCode and barcode.text:
            try:
                return text, _parse_qr_payload(barcode.text)
            except InvalidInvoice:
                continue
    raise InvalidInvoice("No se encontró un QR de CFDI legible en el PDF.")


def _validate_pdf_text(text, qr_fields):
    normalized = _normalize_text(text)
    for label, value in (
        ("UUID", qr_fields["id"]),
        ("RFC emisor", qr_fields["re"]),
        ("RFC receptor", qr_fields["rr"]),
    ):
        if _normalize_text(value) not in normalized:
            raise InvalidInvoice(f"El dato {label} del QR no coincide con el contenido impreso del PDF.")

    if EXPECTED_RFC_RECEPTOR and _normalize_text(qr_fields["rr"]) != EXPECTED_RFC_RECEPTOR:
        raise InvalidInvoice("El CFDI no está emitido para el RFC receptor configurado.")

    try:
        qr_total = Decimal(qr_fields["tt"]).quantize(Decimal("0.01"))
    except InvalidOperation as error:
        raise InvalidInvoice("El total del QR no es válido.") from error

    amounts = re.findall(r"(?<!\d)\$?\s*([\d,]+\.\d{2,6})(?!\d)", text)
    normalized_amounts = set()
    for amount in amounts:
        try:
            normalized_amounts.add(Decimal(amount.replace(",", "")).quantize(Decimal("0.01")))
        except InvalidOperation:
            continue
    if qr_total not in normalized_amounts:
        raise InvalidInvoice("El total del QR no coincide con los importes impresos del PDF.")


def _sat_query(qr_fields):
    expression = (
        f"https://{SAT_QR_HOST}/default.aspx?"
        + urllib.parse.urlencode(
            {
                "id": qr_fields["id"],
                "re": qr_fields["re"],
                "rr": qr_fields["rr"],
                "tt": qr_fields["tt"],
                "fe": qr_fields["fe"],
            }
        )
    )
    soap = f'''<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:tem="http://tempuri.org/">
  <soap:Body>
    <tem:Consulta>
      <tem:expresionImpresa>{_xml_escape(expression)}</tem:expresionImpresa>
    </tem:Consulta>
  </soap:Body>
</soap:Envelope>'''.encode("utf-8")
    request = urllib.request.Request(
        SAT_ENDPOINT,
        data=soap,
        headers={
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPAction": "http://tempuri.org/IConsultaCFDIService/Consulta",
            "User-Agent": "InovaCar-InvoiceValidator/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=SAT_TIMEOUT_SECONDS) as response:
            payload = response.read(1024 * 1024)
    except (urllib.error.URLError, TimeoutError, urllib.error.HTTPError) as error:
        raise RetryableProcessingError("El servicio del SAT no respondió correctamente.") from error

    try:
        root = ET.fromstring(payload)
    except ET.ParseError as error:
        raise RetryableProcessingError("El SAT devolvió una respuesta ilegible.") from error

    fields = {}
    for element in root.iter():
        name = element.tag.rsplit("}", 1)[-1].lower()
        if element.text and name in {"estado", "codigoestatus"}:
            fields[name] = element.text.strip()
    state = fields.get("estado", "").lower()
    code = fields.get("codigoestatus", "").lower()

    if state == "vigente":
        return True, fields.get("codigoestatus") or "El SAT reporta el CFDI vigente."
    if state in {"cancelado", "no encontrado", "no encontrado."} or "no encontrado" in code:
        return False, fields.get("codigoestatus") or f"El SAT reporta el CFDI como {state}."
    raise RetryableProcessingError(
        "El SAT no devolvió un estado final reconocible; el mensaje se reintentará."
    )


def _xml_escape(value):
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def _download_pdf(bucket, key):
    if bucket != S3_BUCKET_ALLOWED:
        raise InvalidInvoice("El bucket S3 del mensaje no está permitido.")
    if not key.startswith(S3_KEY_PREFIX) or ".." in key.split("/"):
        raise InvalidInvoice("La ruta S3 de la factura no está permitida.")
    try:
        metadata = s3.head_object(Bucket=bucket, Key=key)
        if metadata.get("ContentLength", 0) > MAX_PDF_BYTES:
            raise InvalidInvoice("El PDF excede el tamaño máximo configurado.")
        result = s3.get_object(Bucket=bucket, Key=key)
        content = result["Body"].read(MAX_PDF_BYTES + 1)
    except InvalidInvoice:
        raise
    except Exception as error:
        raise RetryableProcessingError("No se pudo descargar el PDF desde S3.") from error

    if len(content) > MAX_PDF_BYTES:
        raise InvalidInvoice("El PDF excede el tamaño máximo configurado.")
    if not content.startswith(b"%PDF-"):
        raise InvalidInvoice("El archivo descargado no es un PDF válido.")
    return content


def _s3_key_exists(bucket, key):
    """List one exact key so missing objects return false instead of ambiguous 403."""
    try:
        result = s3.list_objects_v2(Bucket=bucket, Prefix=key, MaxKeys=1)
    except Exception as error:
        raise RetryableProcessingError(
            "No se pudo verificar el PDF o su ruta de archivo en S3."
        ) from error
    return any(item.get("Key") == key for item in result.get("Contents", []))


def _archive_invoice_pdf(bucket, source_key, invoice_id, status):
    if bucket != S3_BUCKET_ALLOWED:
        raise RetryableProcessingError("El bucket del PDF no coincide con el permitido.")
    if not source_key.startswith(S3_KEY_PREFIX) or ".." in source_key.split("/"):
        raise RetryableProcessingError("La ruta original del PDF no es válida para archivarse.")

    destination_prefix = ARCHIVE_PREFIX_BY_STATUS.get(status)
    if not destination_prefix:
        raise RetryableProcessingError("No se puede archivar una factura sin estado final.")

    relative_key = source_key[len(S3_KEY_PREFIX):]
    destination_key = f"{destination_prefix}{invoice_id}/{relative_key}"

    source_exists = _s3_key_exists(bucket, source_key)
    destination_exists = _s3_key_exists(bucket, destination_key)
    if not source_exists and not destination_exists:
        raise RetryableProcessingError(
            "El PDF no está ni en pendientes ni en su carpeta final de S3."
        )

    try:
        if source_exists and not destination_exists:
            s3.copy_object(
                Bucket=bucket,
                Key=destination_key,
                CopySource={"Bucket": bucket, "Key": source_key},
                MetadataDirective="COPY",
            )
        if source_exists:
            s3.delete_object(Bucket=bucket, Key=source_key)
    except Exception as error:
        raise RetryableProcessingError(
            "No se pudo mover el PDF a su carpeta final en S3."
        ) from error

    return destination_key


def _process_record(record):
    try:
        message = json.loads(record["body"])
        invoice_id = str(message["factura_id"])
        bucket = str(message["s3_bucket"])
        key = str(message["s3_key"])
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise InvalidInvoice("El mensaje SQS no tiene factura_id, s3_bucket y s3_key válidos.") from error

    if not re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        invoice_id,
    ):
        raise InvalidInvoice("factura_id debe ser un UUID de la tabla facturas.")

    current = _get_invoice(invoice_id)
    current_status = current.get("estatus") if current else None

    # Reuse a prior final result on an SQS redelivery. This makes the S3 move
    # idempotent if a retry occurs after the database update or object copy.
    if current_status in ARCHIVE_PREFIX_BY_STATUS:
        status = current_status
        cfdi_uuid = current.get("cfdi_uuid")
        reason = current.get("validation_reason") or "Resultado de validación guardado previamente."
    else:
        if current:
            _mark_in_progress(invoice_id)
        if PROCESSING_DELAY_SECONDS:
            time.sleep(PROCESSING_DELAY_SECONDS)

        cfdi_uuid = None
        try:
            pdf_bytes = _download_pdf(bucket, key)
            text, qr_fields = _render_and_read_qr(pdf_bytes)
            cfdi_uuid = qr_fields["id"]
            _validate_pdf_text(text, qr_fields)
            is_valid, sat_reason = _sat_query(qr_fields)
            status = "aprobada" if is_valid else "rechazada"
            reason = sat_reason
        except InvalidInvoice as error:
            status = "rechazada"
            reason = str(error)

        _save_invoice_result(invoice_id, status, cfdi_uuid, reason)

    if not current or not current.get("email_notified_at"):
        _notify(invoice_id, status, reason, cfdi_uuid)

    telegram_sent = bool(current and current.get("telegram_notified_at"))
    if not telegram_sent:
        # Telegram is best-effort: a failure here must not block the S3 move
        # or keep the SQS message retrying. Email (SNS) remains mandatory.
        try:
            _notify_telegram(invoice_id, status, reason, cfdi_uuid)
            telegram_sent = True
        except Exception as error:
            print(
                json.dumps(
                    {
                        "factura_id": invoice_id,
                        "warning": "telegram_failed",
                        "error": str(error)[:300],
                    }
                )
            )

    archived_key = _archive_invoice_pdf(bucket, key, invoice_id, status)
    _save_invoice_s3_key(invoice_id, archived_key)

    print(
        json.dumps(
            {
                "factura_id": invoice_id,
                "cfdi_uuid": cfdi_uuid,
                "status": status,
                "s3_key": archived_key,
                "email_sent": not bool(current and current.get("email_notified_at")),
                "telegram_sent": telegram_sent,
            }
        )
    )


def lambda_handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        try:
            _process_record(record)
        except Exception as error:
            print(
                json.dumps(
                    {
                        "message_id": record.get("messageId"),
                        "error_type": type(error).__name__,
                        "error": str(error)[:500],
                    }
                )
            )
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}
