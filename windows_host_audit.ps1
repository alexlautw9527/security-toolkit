$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$out = "windows_audit_$env:COMPUTERNAME`_$ts"
New-Item -ItemType Directory -Path $out -Force | Out-Null

Get-ComputerInfo | Out-File "$out\computerinfo.txt"
Get-HotFix | Sort-Object InstalledOn -Descending | Export-Csv "$out\hotfix.csv" -NoTypeInformation
Get-NetTCPConnection -State Listen | Export-Csv "$out\listening_ports.csv" -NoTypeInformation
Get-Service | Export-Csv "$out\services.csv" -NoTypeInformation
Get-NetFirewallProfile | Format-List * | Out-File "$out\firewall_profiles.txt"

try {
  Get-SmbServerConfiguration | Format-List * | Out-File "$out\smb_server_config.txt"
} catch {}

try {
  Get-TlsCipherSuite | Select-Object Name | Export-Csv "$out\tls_cipher_suites.csv" -NoTypeInformation
} catch {}

Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
                 HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* `
  -ErrorAction SilentlyContinue |
  Where-Object DisplayName |
  Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
  Sort-Object DisplayName |
  Export-Csv "$out\installed_software.csv" -NoTypeInformation

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Created $out.zip"
