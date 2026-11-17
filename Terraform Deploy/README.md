# Inova Car: EC2 pública y archivos en S3

## Arquitectura sencilla

Navegador -> EC2 pública con Nginx -> archivos locales sincronizados desde S3.

La EC2 sirve el sitio por HTTP en el puerto 80. El bucket S3 permanece privado; la instancia usa el perfil preexistente LabInstanceProfile para leer site/. Supabase continúa manejando la base de datos y la autenticación desde el JavaScript del sitio.

## Requisitos del Learner Lab

- Debe existir el bucket inova-car-<ID-de-cuenta>-us-east-1.
- El perfil LabInstanceProfile debe tener permiso para ejecutar s3:ListBucket en el bucket y s3:GetObject en site/*.
- Para publicar desde tu computadora, tus credenciales de AWS CLI necesitan permiso para subir objetos al bucket.
- La VPC predeterminada debe tener una subred pública con asignación de IPv4 pública.

## Aplicar el cambio

Abre PowerShell en esta carpeta y revisa primero el plan:

    terraform plan

Este plan eliminará API Gateway, VPC Link, ALB y Auto Scaling que gestionaba la configuración anterior, y creará una EC2 pública. El bucket y los archivos del sitio no se eliminan.

Si el plan muestra esos cambios esperados, aplica:

    terraform apply

Después sube los archivos de la página:

    .\deploy.ps1

Abre la dirección que imprime el script. También puedes consultarla con:

    terraform output -raw website_url

La instancia sincroniza S3 al iniciar y aproximadamente cada minuto. Si acabas de subir cambios, espera hasta un minuto y recarga la página.

## Problemas comunes

- Si el sitio no carga, verifica que la EC2 esté en estado Running y que el security group permita HTTP por el puerto 80.
- Si aparece 403/404 o una página vacía, revisa que LabInstanceProfile permita leer el prefijo site/ y mira /var/log/cloud-init-output.log y /var/log/inova-site-sync.log dentro de la EC2.
- El sitio usa HTTP. Supabase debe permitir el origen de la URL de EC2 si tu configuración restringe los redirect URLs o los orígenes.

## Eliminar los recursos de este Terraform

    .\destroy.ps1

Esto destruye la EC2 y el security group. El bucket preexistente y sus archivos permanecen.

