
import json
import os
import io
import hmac
import base64
import urllib.request
import urllib.parse

from pypdf import PdfReader

TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
SECRET = os.environ["TELEGRAM_WEBHOOK_SECRET"]

MAX_SIZE = 10 * 1024 * 1024  # 10 MB


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


# Función principal de AWS Lambda
def lambda_handler(event, context):

    headers = {
        k.lower(): v
        for k, v in (event.get("headers") or {}).items()
    }

    recibido = headers.get(
        "x-telegram-bot-api-secret-token", ""
    )

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

        # Comprobar que enviaron un documento
        if "document" not in mensaje:
            enviar_mensaje(
                chat_id,
                "Hola, envíame una factura en PDF."
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

        # Validar extensión y tipo declarado
        if (
            not nombre.lower().endswith(".pdf")
            or mime_type != "application/pdf"
        ):
            enviar_mensaje(
                chat_id,
                "Archivo rechazado. Debes enviar un PDF."
            )

            return {
                "statusCode": 200,
                "body": "OK"
            }

        # Validar tamaño
        if file_size > MAX_SIZE:
            enviar_mensaje(
                chat_id,
                "Archivo rechazado. Máximo 10 MB."
            )

            return {
                "statusCode": 200,
                "body": "OK"
            }

        # Descargar archivo
        contenido = descargar_archivo(file_id)

        # Validar que realmente sea PDF
        if validar_pdf(contenido):

            enviar_mensaje(
                chat_id,
                "PDF válido. Archivo recibido correctamente."
            )

            print("PDF válido:", nombre)

        else:

            enviar_mensaje(
                chat_id,
                "Archivo rechazado. El PDF es inválido o está dañado."
            )

            print("PDF inválido:", nombre)

        return {
            "statusCode": 200,
            "body": "OK"
        }

    except Exception as error:
        print("Error de procesamiento:", type(error).__name__)

        return {
            "statusCode": 500,
            "body": "Error interno"
        }
