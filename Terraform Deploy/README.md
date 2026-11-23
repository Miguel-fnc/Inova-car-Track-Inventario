# Inova Car: sitio y API con escalado horizontal

## Arquitectura

```text
Navegador -> ALB público -> EC2 del Auto Scaling Group -> Nginx (web) / Node.js (API)
Navegador -> API Gateway -> ALB público -> EC2 del Auto Scaling Group -> Valkey -> Supabase
                                      EC2 <- bucket S3 privado (archivos del sitio y API)
```

El bucket privado existente entrega el código a las EC2; Nginx sirve los archivos estáticos desde cada instancia. El ALB público distribuye el sitio y las llamadas directas hacia las EC2 saludables. El frontend usa API Gateway para sus llamadas a la API; el API Gateway también reenvía al mismo ALB. Las EC2 comparten Valkey para que la caché funcione entre instancias.

El ALB es público porque entrega la página directamente. En esta arquitectura sencilla las rutas `/api/...` también son alcanzables a través del DNS del ALB. La API debe seguir verificando la sesión de Supabase y aplicando RLS. Para producción convendría separar y restringir el origen del backend.

El ASG inicia con 2 instancias `t3.micro`, mínimo 2 y máximo 4, repartidas en `us-east-1c` y `us-east-1f`. La política target tracking procura mantener el CPU promedio cerca de 50%. El intervalo de un minuto sincroniza despliegues desde S3, no es el mecanismo de escalado.

## Learner Lab y costos

Se crean instancias EC2, ALB, API Gateway y ElastiCache; estos recursos pueden consumir los créditos del laboratorio. Para reducir costos puedes aplicar con una instancia y un nodo de caché:

```powershell
terraform plan -var="asg_min_size=1" -var="asg_desired_capacity=1" -var="asg_max_size=2" -var="cache_node_count=1"
terraform apply -var="asg_min_size=1" -var="asg_desired_capacity=1" -var="asg_max_size=2" -var="cache_node_count=1"
```

Un nodo Valkey no tiene failover Multi-AZ. El lab puede denegar recursos según sus políticas IAM/SCP. Este diseño no requiere VPC Link ni CloudFront.

## Supabase

- `api/.env` debe tener `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `PORT` y `REDIS_URL`.
- `deploy.ps1` carga `.env` en el prefijo privado `site/api/` del bucket de artefactos. La credencial `service_role` no debe usarse.
- En cada EC2, el script de inicio reemplaza `REDIS_URL` por el endpoint de Valkey compartido.
- `/api/live` sirve como health check del target group; `/api/health` también revisa Valkey.

## Rutas API

- `GET /api/products?table=<tabla>`: caché Valkey con TTL de 60 segundos y Supabase como fuente de verdad.
- `POST /api/products/update?table=<tabla>`: actualiza precio/stock y cambia la versión de caché.
- `GET /api/invoices?status=<estado>`: consulta facturas en Supabase.
- `GET /api/health` y `GET /api/live`.

El procesamiento SQS/Lambda para Telegram queda fuera de este despliegue.

## Despliegue

Requisitos: Terraform >= 1.5, AWS CLI v2, PowerShell, credenciales temporales del AWS Academy Learner Lab, bucket privado existente `inova-car-<ID-de-cuenta>-us-east-1` y `LabInstanceProfile` con permiso de lectura en ese bucket. AWS CLI debe poder escribir en el mismo bucket.

Desde la carpeta `Terraform Deploy`:

```powershell
terraform init
terraform plan
terraform apply
.\deploy.ps1
```

Revisa el plan antes de aplicar. El cambio reemplaza la EC2 independiente previa con un ASG y crea un ALB público, API Gateway y Valkey. El script sube el sitio a `site/` y la API/`.env` a `site/api/`. Las instancias sincronizan ambos prefijos desde S3 aproximadamente cada minuto.

Prueba la API:

```powershell
Invoke-WebRequest "$(terraform output -raw api_url)/api/health" -UseBasicParsing
```

Obtén las direcciones:

```powershell
terraform output -raw website_url
terraform output -raw api_url
```

Si Supabase Auth valida Redirect URLs, agrega `website_url` a la lista permitida.

## Escalado y seguridad

- El ASG mantiene instancias en varias AZ y puede crecer hasta el máximo configurado según CPU.
- El ALB verifica `/api/live` y solo envía tráfico a instancias saludables.
- El bucket S3 permanece privado. El perfil de instancia permite que EC2 lea los archivos.
- El Security Group de EC2 acepta HTTP desde el ALB; Valkey acepta conexiones solo desde EC2.
- Las EC2 tienen IP pública para conectarse a S3, Supabase y servicios externos en la VPC por defecto.
- Valkey cifra datos en reposo; el cifrado en tránsito está deshabilitado por simplicidad del lab.
- La disponibilidad del inventario aún depende de Supabase.
- Para revisar el ASG: EC2 > Auto Scaling Groups, o `terraform output -raw autoscaling_group_name`.
- Para comprobar caché, las respuestas de productos muestran `X-Cache: MISS` al cargar y `HIT` durante los siguientes 60 segundos.

Para eliminar recursos, revisa el script y el plan antes de ejecutar `.\destroy.ps1`. El bucket preexistente de artefactos no es administrado ni eliminado por Terraform.
