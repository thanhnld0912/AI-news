<#
  Đăng ký (hoặc gỡ) tác vụ Windows Task Scheduler để chạy monitor.ps1 mỗi ngày.

    .\install-task.ps1                     Chạy mỗi ngày lúc 07:00
    .\install-task.ps1 -Times 07:00,19:00  Chạy 2 lần/ngày
    .\install-task.ps1 -Remove             Gỡ tác vụ
#>
param(
    [string[]]$Times = @('07:00'),
    [string]$TaskName = 'AI Feed Monitor',
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Đã gỡ tác vụ '$TaskName'."
    exit 0
}

$script = Join-Path $PSScriptRoot 'monitor.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" `
    -WorkingDirectory $PSScriptRoot
$triggers = @($Times | ForEach-Object { New-ScheduledTaskTrigger -Daily -At $_ })
# StartWhenAvailable: nếu máy tắt đúng giờ hẹn, tác vụ sẽ chạy ngay khi máy bật lại
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
    -Description 'Gửi bản tin AI & Kỹ thuật phần mềm từ các nguồn RSS' -Force | Out-Null

Write-Host "Đã đăng ký tác vụ '$TaskName' chạy lúc: $($Times -join ', ')"
Write-Host "Chạy thử ngay: Start-ScheduledTask -TaskName '$TaskName'"
