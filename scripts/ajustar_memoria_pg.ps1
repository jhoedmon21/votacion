# Ajusta work_mem, maintenance_work_mem y effective_cache_size en postgresql.conf
# para acotar la memoria por consulta de PostgreSQL en una PC de 16 GB.
$f = 'C:\Program Files\PostgreSQL\16\data\postgresql.conf'
$c = Get-Content $f
$c = $c -replace '^#work_mem = 4MB', 'work_mem = 8MB'
$c = $c -replace '^#maintenance_work_mem = 64MB', 'maintenance_work_mem = 128MB'
$c = $c -replace '^#effective_cache_size = 4GB', 'effective_cache_size = 2GB'
Set-Content -Path $f -Value $c
Write-Output 'OK'
