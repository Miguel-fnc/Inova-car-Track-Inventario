# Prueba del Auto Scaling Group por CPU (meta: 30 %).
#
# Sube el CPU de las EC2 que estén en servicio usando SSM Run Command (sin SSH
# y sin generar tráfico de red), y muestra en vivo cómo reacciona el grupo.
# Las instancias nuevas que lance el escalado NO se estresan, así que el
# promedio baja conforme entran: así se estabiliza un grupo real.
#
# Uso:
#   .\probar-autoscaling.ps1                  # inicia 15 min de carga y monitorea
#   .\probar-autoscaling.ps1 -Minutos 10 -Porcentaje 70
#   .\probar-autoscaling.ps1 -Accion monitorear   # solo observar
#   .\probar-autoscaling.ps1 -Accion detener      # quita la carga ya
#   .\probar-autoscaling.ps1 -Accion estado       # una foto del grupo
#
# Ctrl+C solo detiene el monitoreo; la carga se apaga sola al terminar
# -Minutos o con -Accion detener.
param(
  [ValidateSet("iniciar", "monitorear", "detener", "estado")]
  [string] $Accion = "iniciar",
  [ValidateRange(1, 30)] [int] $Minutos = 15,
  # Porcentaje de núcleos a saturar: 100 = todos. Con 2 instancias al 100 % el
  # promedio queda muy por encima del 30 % y el grupo sube a su máximo.
  [ValidateRange(10, 100)] [int] $Porcentaje = 100,
  [int] $IntervaloSegundos = 30,
  [string] $Region = "us-east-1",
  [string] $ProjectName = "inova-car"
)

$ErrorActionPreference = "Continue"
$Marca = "inova-stress"

$Account = aws sts get-caller-identity --query Account --output text --region $Region
if ($LASTEXITCODE -ne 0 -or -not $Account) { throw "No se pudo verificar la cuenta AWS. Actualiza ~/.aws/credentials." }
$Asg = "$ProjectName-$Account-asg"

function Get-InstanciasEnServicio {
  $ids = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $Asg --region $Region `
    --query "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId" --output text
  return @($ids -split "\s+" | Where-Object { $_ -and $_ -ne "None" })
}

function Invoke-EnInstancias([string[]] $ids, [string] $script, [string] $comentario) {
  # The command travels as a JSON parameters file to avoid quoting problems.
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    $json = @{ commands = @($script) } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    $cmdId = aws ssm send-command --region $Region --document-name AWS-RunShellScript `
      --instance-ids $ids --parameters "file://$tmp" --comment $comentario `
      --query "Command.CommandId" --output text
    if ($LASTEXITCODE -ne 0 -or -not $cmdId) { throw "SSM no aceptó el comando. Revisa que las EC2 estén Online en Systems Manager." }
    return $cmdId
  } finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function Show-Estado {
  $g = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $Asg --region $Region `
    --query "AutoScalingGroups[0].{d:DesiredCapacity,max:MaxSize,i:Instances[].LifecycleState}" --output json | ConvertFrom-Json
  $enServicio = @($g.i | Where-Object { $_ -eq "InService" }).Count
  $arrancando = @($g.i | Where-Object { $_ -like "Pending*" }).Count
  $saliendo = @($g.i | Where-Object { $_ -like "Terminating*" }).Count

  $cpu = aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUUtilization `
    --dimensions Name=AutoScalingGroupName,Value=$Asg `
    --start-time ([DateTime]::UtcNow.AddMinutes(-6).ToString("s")) --end-time ([DateTime]::UtcNow.ToString("s")) `
    --period 60 --statistics Average --region $Region `
    --query "sort_by(Datapoints,&Timestamp)[-1].Average" --output text
  $cpuTxt = if ($cpu -and $cpu -ne "None") { "{0,5:N1} %" -f [double]$cpu } else { "  --  " }

  $alarma = aws cloudwatch describe-alarms --alarm-name-prefix "TargetTracking-$Asg-AlarmHigh" --region $Region `
    --query "MetricAlarms[0].StateValue" --output text

  "{0:HH:mm:ss}  CPU prom: {1}  | deseadas {2}/{3}  en servicio {4}  arrancando {5}  saliendo {6}  | alarma subir: {7}" -f `
    (Get-Date), $cpuTxt, $g.d, $g.max, $enServicio, $arrancando, $saliendo, $alarma
}

function Show-Actividades([datetime] $desde) {
  $acts = aws autoscaling describe-scaling-activities --auto-scaling-group-name $Asg --region $Region --max-items 10 `
    --query "Activities[].[StartTime,StatusCode,Description]" --output json | ConvertFrom-Json
  $acts | Where-Object { [datetime]$_[0] -ge $desde } | Sort-Object { [datetime]$_[0] } | ForEach-Object {
    "  {0:HH:mm:ss}  {1,-12} {2}" -f ([datetime]$_[0]).ToLocalTime(), $_[1], $_[2]
  }
}

function Start-Monitoreo([datetime] $desde, [datetime] $hasta) {
  Write-Host "Monitoreando $Asg cada $IntervaloSegundos s (Ctrl+C para salir)..."
  Write-Host "Con monitoreo detallado el CPU tarda 1-3 min en reflejarse; la alarma necesita 3 min seguidos > 30 %."
  $vistas = @{}
  while ($true) {
    Show-Estado
    Show-Actividades $desde | ForEach-Object { if (-not $vistas.ContainsKey($_)) { $vistas[$_] = $true; Write-Host $_ -ForegroundColor Cyan } }
    if ($hasta -and (Get-Date) -gt $hasta.AddMinutes(25)) { Write-Host "Fin del monitoreo."; break }
    Start-Sleep -Seconds $IntervaloSegundos
  }
}

switch ($Accion) {
  "estado" {
    Show-Estado
    Show-Actividades (Get-Date).AddHours(-2)
  }

  "monitorear" {
    Start-Monitoreo (Get-Date).AddMinutes(-30) $null
  }

  "detener" {
    $ids = Get-InstanciasEnServicio
    if (-not $ids) { throw "No hay instancias en servicio en $Asg." }
    $cmd = Invoke-EnInstancias $ids "pkill -f $Marca || true; echo carga detenida" "detener prueba autoscaling"
    Write-Host "Carga detenida en: $($ids -join ', ') (comando $cmd)"
    Write-Host "El grupo volverá a 2 instancias tras ~15 min con el CPU por debajo de 27 %."
  }

  "iniciar" {
    $ids = Get-InstanciasEnServicio
    if (-not $ids) { throw "No hay instancias en servicio en $Asg." }
    $segundos = $Minutos * 60

    # Busy loops tagged with $Marca so -Accion detener can find them. nohup +
    # setsid keep them alive after the SSM command returns; timeout ends them.
    $bash = @"
n=`$(nproc); k=`$(( (n * $Porcentaje + 99) / 100 )); [ `$k -lt 1 ] && k=1
for i in `$(seq `$k); do
  setsid nohup timeout $segundos bash -c ': $Marca; while :; do :; done' >/dev/null 2>&1 &
done
echo "carga iniciada en `$k de `$n nucleos por $segundos s"
"@

    Write-Host "Cuenta $Account | grupo $Asg"
    Write-Host "Subiendo CPU en $($ids.Count) instancia(s): $($ids -join ', ')"
    Write-Host "Duración: $Minutos min | núcleos saturados: $Porcentaje %"
    $inicio = Get-Date
    $cmd = Invoke-EnInstancias $ids $bash "prueba autoscaling ($Minutos min)"
    Write-Host "Comando SSM: $cmd"
    Write-Host ""
    Write-Host "Qué esperar: CPU > 30 % durante 3 min -> se lanzan instancias nuevas (hasta 4)."
    Write-Host "Al terminar la carga, el grupo regresa a 2 tras ~15 min con CPU < 27 %."
    Write-Host ""
    Start-Monitoreo $inicio $inicio.AddMinutes($Minutos)
  }
}
