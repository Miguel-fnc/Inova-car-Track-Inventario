# Inova Car: EC2 pública, API y caché Redis-compatible

## Arquitectura

Navegador -> API Gateway HTTP API -> Nginx/Node.js en EC2 -> Valkey local y Supabase.

La página estática se sirve desde Nginx en la EC2. Las lecturas y actualizaciones del inventario pasan por API Gateway hacia la API Node.js. API Gateway reenvía las rutas completas `/api/...` a la EC2. El bucket S3 privado distribuye los archivos a la EC2; no participa en las peticiones del navegador.

Valkey implementa el protocolo compatible con Redis y se ejecuta únicamente en localhost dentro de la EC2. El puerto 6379 no se publica a internet. Las lecturas de productos usan una caché por usuario y tabla con TTL de 60 segundos. La primera lectura devuelve MISS y consulta Supabase; las lecturas siguientes devuelven HIT hasta que expire o cambie el inventario. Después de guardar un precio o stock, la aplicación invalida la versión de caché de esa tabla.

La API valida la sesión con Supabase Auth y lee o actualiza las tablas con el token del usuario, de modo que Supabase RLS continúa aplicándose. No se utiliza la clave service_role. El inicio de sesión sigue usando Supabase Auth desde el navegador.

## Rutas implementadas

- `GET /api/products?table=<tabla>`: lee inventario desde la caché Valkey o Supabase.
- `POST /api/products/update?table=<tabla>`: recibe `{ "id": "...", "field": "stock" | "precio", "value": 0 }`, actualiza Supabase y luego invalida la caché de esa tabla y usuario.
- `GET /api/health`: estado de la API y Valkey.

La tabla debe estar en la lista permitida de la API y el usuario debe tener permisos RLS en Supabase. Las rutas de facturas todavía no están implementadas.

## Requisitos del Learner Lab

- Debe existir el bucket inova-car-<ID-de-cuenta>-us-east-1.
- El perfil LabInstanceProfile debe poder leer el prefijo site/* del bucket.
- Para publicar desde tu computadora, AWS CLI necesita permiso para subir objetos al bucket.
- La VPC predeterminada debe tener una subred pública con asignación de IPv4 pública.
- api/.env debe existir en el proyecto. deploy.ps1 lo sube al prefijo privado site/api/.env. El bucket mantiene el bloqueo de acceso público.

## Conectarse a la EC2 para revisar logs

Terraform permite SSH por el puerto 22 únicamente desde el prefijo administrado por AWS para EC2 Instance Connect. Después de aplicar el cambio, abre EC2 > Instances, selecciona la instancia y elige Connect > EC2 Instance Connect > Connect using a Public IP. Usa el usuario ec2-user. La consola envía una llave temporal; no necesitas crear ni descargar una llave privada.
## Despliegue

Desde PowerShell, en esta carpeta:

    terraform plan
    terraform apply

Después sube el frontend y la API; el script configura el frontend con la URL del API Gateway:

    .\deploy.ps1

La EC2 descarga los archivos desde S3 aproximadamente cada minuto. En el primer despliegue, espera un minuto y comprueba el API pasando por API Gateway:

    Invoke-WebRequest "$(terraform output -raw api_url)/api/health"

La respuesta esperada es JSON con status igual a ok y cache igual a ready. Después abre la URL del sitio:

    terraform output -raw website_url

La URL pública del API Gateway se consulta con:

    terraform output -raw api_url

## Verificar HIT y MISS

1. Inicia sesión y abre un panel de productos.
2. En las herramientas del navegador, pestaña Network, abre la solicitud GET de API Gateway a `/api/products?table=...`.
3. La primera lectura debe responder con la cabecera X-Cache: MISS.
4. Recarga el mismo panel dentro de los siguientes 60 segundos: debe responder X-Cache: HIT.
5. Al guardar un cambio de stock o precio, la aplicación invalida la caché de esa tabla; la siguiente lectura debe volver a ser MISS.

El TTL es de 60 segundos. Si Redis-compatible cache no está disponible, la API consulta Supabase y responde con X-Cache: BYPASS.

## Límites de esta configuración

Valkey corre en la misma EC2 que la API, así que la caché es privada y sencilla para el Learner Lab. Al reiniciar la instancia, se puede vaciar. Si en el futuro agregas más EC2, cada una tendría su propia caché; para compartirla habría que migrar a un servicio compartido como ElastiCache y habilitar la conectividad entre instancias.

El sitio usa HTTP. Para producción, configura HTTPS y un dominio.

## Eliminar los recursos de este Terraform

    .\destroy.ps1

Esto destruye la EC2, API Gateway y el security group. El bucket preexistente y los archivos publicados permanecen.
