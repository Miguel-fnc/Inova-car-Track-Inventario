$ErrorActionPreference = "Stop"

$ProjectPath = $PSScriptRoot
$PackagePath = Join-Path $ProjectPath "package"
$ZipPath = Join-Path $ProjectPath "lambda_function.zip"
$Python = Get-Command python -ErrorAction SilentlyContinue

if (-not $Python) {
  throw "No se encontro Python. Instala Python 3.12 o usa AWS CloudShell para construir el paquete. Docker no es necesario."
}

$pythonVersion = & $Python.Source --version 2>&1
if ($pythonVersion -notmatch "Python 3\.(12|13|14)\.") {
  throw "Se requiere Python 3.12 o posterior para construir dependencias compatibles con Lambda. Detectado: $pythonVersion"
}

if (Test-Path -LiteralPath $PackagePath) {
  Remove-Item -LiteralPath $PackagePath -Recurse -Force
}
if (Test-Path -LiteralPath $ZipPath) {
  Remove-Item -LiteralPath $ZipPath -Force
}
New-Item -ItemType Directory -Path $PackagePath | Out-Null

# Download Linux x86_64 wheels for Lambda Python 3.12, not Windows wheels.
$pipArgs = @(
  "install", "--disable-pip-version-check", "--no-cache-dir", "--only-binary=:all:",
  "--no-compile", "--target", $PackagePath,
  "--platform", "manylinux_2_28_x86_64",
  "--platform", "manylinux_2_27_x86_64",
  "--platform", "manylinux2014_x86_64",
  "--python-version", "3.12",
  "--implementation", "cp",
  "--abi", "cp312",
  "--abi", "abi3",
  "--abi", "none",
  "-r", (Join-Path $ProjectPath "requirements.txt")
)
& $Python.Source -m pip @pipArgs
if ($LASTEXITCODE -ne 0) {
  throw "No se pudieron descargar wheels Linux compatibles. Revisa Python/pip y la conexion a PyPI."
}

Copy-Item -LiteralPath (Join-Path $ProjectPath "lambda_function.py") -Destination $PackagePath
[System.IO.Compression.ZipFile]::CreateFromDirectory($PackagePath, $ZipPath)

Write-Host "Paquete Linux para Lambda creado: $ZipPath"
