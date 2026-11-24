
import json
import os
import io
import hmac
import base64
import urllib.request
import urllib.parse
import boto3

from botocore.exceptions import ClientError
from pypdf import PdfReader

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
SECRET = os.environ["TELEGRAM_WEBHOOK_SECRET"]

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SUPABASE_KEY = os.environ["SUPABASE_SECRET_KEY"]

MAX_SIZE = 10 * 1024 * 1024  # 10 MB

s3=boto3.client("s3")
BUCKET = os.environ["FACTURAS_BUCKET"]


sqs = boto3.client("sqs")
QUEUE_URL = os.environ["FACTURAS_QUEUE_URL"]

# Enviar mensajes al usuario
def enviar_mensaje(chat_id, texto):
    url = f"https://api.telegram.org/bot{TOKEN}/sendMessage"

    datos = urllib.parse.urlencode({
        "chat_id": chat_id,
        "text": texto
    }).encode("utf-8")

    request = urllib.request.Request(url, data=datos)

    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()


# Descargar archivo desde Telegram
def descargar_archivo(file_id):

    url = f"https://api.telegram.org/bot{TOKEN}/getFile"

    params = urllib.parse.urlencode({
        "file_id": file_id
    })

    with urllib.request.urlopen(
        f"{url}?{params}", timeout=10
    ) as response:
        resultado = json.load(response)

    if not resultado.get("ok"):
        raise RuntimeError("No se pudo obtener el archivo")

    file_path = resultado["result"]["file_path"]

    ruta = urllib.parse.quote(file_path, safe="/")

    download_url = (
        f"https://api.telegram.org/file/bot{TOKEN}/{ruta}"
    )

    with urllib.request.urlopen(
        download_url, timeout=20
    ) as response:
        contenido = response.read(MAX_SIZE + 1)

    return contenido


# Validar contenido real del PDF

# Validar contenido real del PDF
def validar_pdf(contenido):

    if not contenido:
        return False

    if len(contenido) > MAX_SIZE:
        return False

    # Verificar firma del archivo
    if not contenido.startswith(b"%PDF-"):
        return False

    try:
        # Intentar leer la estructura del PDF
        lector = PdfReader(
            io.BytesIO(contenido),
            strict=False
        )

        # No aceptar PDF protegido con contraseña
        if lector.is_encrypted:
            return False

        # Verificar que tenga al menos una página
        if len(lector.pages) == 0:
            return False

        # Comprobar que sus páginas se puedan leer
        for pagina in lector.pages:
            _ = pagina.mediabox

        return True

    except Exception:
        return False


def registrar_en_supabase(chat_id, message_id, nombre, s3_key):

    url = (
        f"{SUPABASE_URL}/rest/v1/facturas"
        "?on_conflict=telegram_chat_id,telegram_message_id"
        "&select=id,estatus"
    )

    # Datos que guardaremos en la tabla
    datos = {
        "estatus": "CREADA",
        "nombre_archivo": nombre,
        "s3_key": s3_key,
        "telegram_chat_id": str(chat_id),
        "telegram_message_id": message_id
    }

    headers = {
        "apikey": SUPABASE_KEY,
        "Content-Type": "application/json",
        "Prefer": "resolution=ignore-duplicates,return=representation"
    }

    request = urllib.request.Request(
        url,
        data=json.dumps(datos).encode("utf-8"),
        headers=headers,
        method="POST"
    )

    with urllib.request.urlopen(request, timeout=10) as response:
        registros = json.load(response)

    # Si se creó la factura, devolver su registro
    if registros:
        return registros[0]

    # Si Telegram reenvía el mismo mensaje,
    # recuperar la factura que ya existe
    filtros = urllib.parse.urlencode({
        "telegram_chat_id": f"eq.{chat_id}",
        "telegram_message_id": f"eq.{message_id}",
        "select": "id,estatus"
    })

    consulta = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/facturas?{filtros}",
        headers={"apikey": SUPABASE_KEY}
    )

    with urllib.request.urlopen(consulta, timeout=10) as response:
        registros = json.load(response)

    if not registros:
        raise RuntimeError("No se pudo registrar la factura")

    return registros[0]


# Buscar si la factura ya existe en Supabase
def buscar_factura(chat_id, message_id):

    filtros = urllib.parse.urlencode({
        "telegram_chat_id": f"eq.{chat_id}",
        "telegram_message_id": f"eq.{message_id}",
        "select": "id,estatus,s3_key",
        "limit": 1
    })

    url = f"{SUPABASE_URL}/rest/v1/facturas?{filtros}"

    headers = {
        "apikey": SUPABASE_KEY
    }

    request = urllib.request.Request(
        url,
        headers=headers,
        method="GET"
    )

    with urllib.request.urlopen(request, timeout=10) as response:
        registros = json.load(response)

    if registros:
        return registros[0]

    return None



# Enviar factura a SQS y actualizar su estatus
def encolar_factura(factura_id, s3_key):

    # 1. Preparar el mensaje para Lambda 2
    mensaje_sqs = {
        "factura_id": str(factura_id),
        "s3_bucket": BUCKET,
        "s3_key": s3_key
    }

    # 2. Enviar mensaje a SQS
    respuesta = sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(mensaje_sqs)
    )

    print("Mensaje enviado a SQS:", respuesta["MessageId"])

    # 3. Cambiar estatus únicamente si sigue CREADA
    filtros = urllib.parse.urlencode({
        "id": f"eq.{factura_id}",
        "estatus": "eq.CREADA",
        "select": "id,estatus"
    })

    url = f"{SUPABASE_URL}/rest/v1/facturas?{filtros}"

    headers = {
        "apikey": SUPABASE_KEY,
        "Content-Type": "application/json",
        "Prefer": "return=representation"
    }

    request = urllib.request.Request(
        url,
        data=json.dumps({
            "estatus": "EN_PROCESO"
        }).encode("utf-8"),
        headers=headers,
        method="PATCH"
    )

    with urllib.request.urlopen(request, timeout=10) as response:
        registros = json.load(response)

    if registros:
        print("Estatus actualizado: EN_PROCESO")
        return "EN_PROCESO"

    # Evitar sobrescribir un estatus que ya cambió
    consulta = urllib.parse.urlencode({
        "id": f"eq.{factura_id}",
        "select": "estatus"
    })

    request = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/facturas?{consulta}",
        headers={"apikey": SUPABASE_KEY},
        method="GET"
    )

    with urllib.request.urlopen(request, timeout=10) as response:
        registros = json.load(response)

    if not registros:
        raise RuntimeError("No se encontró la factura")

    return registros[0]["estatus"]



# Función principal de AWS Lambda
def lambda_handler(event, context):

    headers = {
        k.lower(): v
        for k, v in (event.get("headers") or {}).items()
    }

    recibido = headers.get(
        "x-telegram-bot-api-secret-token", ""
    )

    # Verificar autenticidad del webhook
    if not hmac.compare_digest(recibido, SECRET):
        return {
            "statusCode": 401,
            "body": "Unauthorized"
        }

    try:
        body = event.get("body") or "{}"

        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode("utf-8")

        datos = json.loads(body)
        mensaje = datos.get("message", {})

        if not mensaje:
            return {
                "statusCode": 200,
                "body": "OK"
            }

        chat_id = mensaje["chat"]["id"]
        message_id = mensaje["message_id"]

        # ========================================
        # 1. VERIFICAR QUE ENVIARON UN DOCUMENTO
        # ========================================

        if "document" not in mensaje:

            if "photo" in mensaje:
                enviar_mensaje(
                    chat_id,
                    "Por favor, envía un archivo PDF (.pdf) "
                    "como documento, no una fotografía."
                )
            else:
                enviar_mensaje(
                    chat_id,
                    "Hola, por favor envíame una "
                    "factura en formato PDF."
                )

            return {
                "statusCode": 200,
                "body": "OK"
            }

        documento = mensaje["document"]

        nombre = documento.get("file_name", "")
        mime_type = documento.get("mime_type", "")
        file_id = documento["file_id"]
        file_size = documento.get("file_size", 0)

        extension = os.path.splitext(nombre)[1].lower()

        # ========================================
        # 2. VALIDAR EXTENSIÓN DEL DOCUMENTO
        # ========================================

        if extension != ".pdf":

            tipo_recibido = (
                extension if extension else "sin extensión"
            )

            enviar_mensaje(
                chat_id,
                f"Archivo no permitido.\n"
                f"Recibimos un archivo {tipo_recibido}.\n"
                f"Por favor, envía un archivo PDF (.pdf)."
            )

            print("Archivo rechazado:", nombre)

            return {
                "statusCode": 200,
                "body": "OK"
            }

        # Validar MIME type
        if mime_type != "application/pdf":

            enviar_mensaje(
                chat_id,
                "El documento no fue identificado "
                "como un PDF.\n"
                "Por favor, envía un archivo PDF válido."
            )

            return {
                "statusCode": 200,
                "body": "OK"
            }

        # Validar tamaño máximo
        if file_size > MAX_SIZE:

            enviar_mensaje(
                chat_id,
                "Archivo rechazado.\n"
                "El tamaño máximo permitido es 10 MB."
            )

            return {
                "statusCode": 200,
                "body": "OK"
            }

        # ========================================
        # 3. PROTECCIÓN CONTRA DUPLICADOS
        # ========================================

        factura_existente = buscar_factura(
            chat_id=chat_id,
            message_id=message_id
        )

        if factura_existente:

            factura_id = factura_existente["id"]
            estatus = factura_existente["estatus"]

            print("Factura existente:", factura_id)
            print("Estatus actual:", estatus)

            # Si quedó CREADA por un fallo anterior,
            # recuperar el envío a SQS
            if estatus == "CREADA":

                estado = encolar_factura(
                    factura_id=factura_id,
                    s3_key=factura_existente["s3_key"]
                )

                print("Estado después de SQS:", estado)

                enviar_mensaje(
                    chat_id,
                    f"Factura enviada a validación.\n"
                    f"ID: {factura_id}\n"
                    f"Estatus: {estado}"
                )

            else:
                # No volver a descargar ni encolar
                print(
                    "Factura ya enviada o procesada:",
                    estatus
                )

            return {
                "statusCode": 200,
                "body": "OK"
            }

        # ========================================
        # 4. DESCARGAR Y VALIDAR EL PDF
        # ========================================

        contenido = descargar_archivo(file_id)

        if not validar_pdf(contenido):

            enviar_mensaje(
                chat_id,
                "El archivo PDF está dañado "
                "o no tiene una estructura válida.\n"
                "Por favor, envía otro archivo PDF."
            )

            print("PDF inválido:", nombre)

            return {
                "statusCode": 200,
                "body": "OK"
            }

        print("PDF válido:", nombre)

        # ========================================
        # 5. GUARDAR EL PDF EN AMAZON S3
        # ========================================

        s3_key = (
            f"pendientes/{chat_id}/{message_id}.pdf"
        )

        try:
            s3.put_object(
                Bucket=BUCKET,
                Key=s3_key,
                Body=contenido,
                ContentType="application/pdf",
                IfNoneMatch="*"
            )

            print("PDF guardado en S3:", s3_key)

        except ClientError as error:

            codigo = error.response["Error"]["Code"]

            if codigo in ("PreconditionFailed", "412"):
                print(
                    "El PDF ya existe en S3:",
                    s3_key
                )
            else:
                raise

        # ========================================
        # 6. REGISTRAR FACTURA EN SUPABASE
        # ========================================

        factura = registrar_en_supabase(
            chat_id=chat_id,
            message_id=message_id,
            nombre=nombre,
            s3_key=s3_key
        )

        factura_id = factura["id"]
        estatus = factura["estatus"]

        print(
            "Factura registrada en Supabase:",
            factura_id
        )

        print("Estatus inicial:", estatus)

        # ========================================
        # 7. ENVIAR FACTURA A AMAZON SQS
        # ========================================

        if estatus == "CREADA":

            estado = encolar_factura(
                factura_id=factura_id,
                s3_key=s3_key
            )

            print("Factura enviada a SQS:", factura_id)

        else:
            # Evitar sobrescribir un estado existente
            estado = estatus

            print(
                "Factura ya enviada o procesada:",
                estado
            )

        # ========================================
        # 8. NOTIFICAR AL USUARIO EN TELEGRAM
        # ========================================

        enviar_mensaje(
            chat_id,
            f"Factura registrada correctamente.\n"
            f"ID: {factura_id}\n"
            f"Estatus: {estado}\n"
            f"Documento enviado a validación."
        )

        return {
            "statusCode": 200,
            "body": "OK"
        }

    except Exception as error:

        print(
            "Error de procesamiento:",
            type(error).__name__,
            str(error)
        )

        return {
            "statusCode": 500,
            "body": "Error interno"
        }
