# Run only with hospital approval because full scans may consume CPU/disk.
Update-MpSignature
Start-MpScan -ScanType FullScan
Get-MpThreatDetection | Format-List *
