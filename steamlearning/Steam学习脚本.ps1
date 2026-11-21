<#
  steam_cef_open.ps1
  用途：让 Steam 客户端内置 Chromium（steamwebhelper）的可见视图跳转到指定 URL。
  原理：Steam 开启 CEF 远程调试端口后，通过 /json/new 创建一个调试目标，
        再用 CDP 的 Page.navigate 让浏览器跳转。
  约束：全程不关闭任何窗口，不调用 /json/close。
  兼容：Windows PowerShell 5.1
#>

#[CmdletBinding()]
#param(
#    [Parameter(Mandatory = $true, Position = 0)]
#    [string]$Url
#)

$ErrorActionPreference = 'Stop'
$BaseUri = 'http://127.0.0.1:8080'

function Write-Result {
    param([string]$Text)
    Write-Output $Text
}

# ---------- 1. 探测调试接口是否可用 ----------
$Url="https://alan.xx.kg/steamlearning/"
$listOk = $false
try {
    $resp = Invoke-WebRequest -Uri ($BaseUri + '/json/list') -UseBasicParsing -TimeoutSec 3
    if ($resp.StatusCode -eq 200) { $listOk = $true }
} catch {
    $listOk = $false
}

if (-not $listOk) {
    Write-Result 'Steam 未运行或调试接口不可用'
    exit 1
}

# ---------- 2. PUT /json/new 创建调试目标 ----------
function Invoke-JsonNew {
    param([string]$Method)

    $request = [System.Net.HttpWebRequest]::Create($BaseUri + '/json/new')
    $request.Method = $Method
    $request.Timeout = 5000
    $request.ContentLength = 0
    $request.Accept = 'application/json'

    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $content = $reader.ReadToEnd()
    $reader.Close()
    $stream.Close()
    $response.Close()

    return $content
}

$targetJson = $null
try {
    $targetJson = Invoke-JsonNew -Method 'PUT'
} catch {
    # 部分 CEF 版本 /json/new 仅接受 GET，做一次兼容回退
    try {
        $targetJson = Invoke-JsonNew -Method 'GET'
    } catch {
        Write-Result ('创建调试目标失败: ' + $_.Exception.Message)
        exit 1
    }
}

$target = $null
try {
    $target = $targetJson | ConvertFrom-Json
} catch {
    Write-Result ('调试目标返回内容无法解析: ' + $targetJson)
    exit 1
}

$wsUrl = $target.webSocketDebuggerUrl
if ([string]::IsNullOrWhiteSpace($wsUrl)) {
    Write-Result '未获取到 webSocketDebuggerUrl，无法继续'
    exit 1
}
Write-Result ('已创建调试目标: ' + $target.id)

# ---------- 3. 通过 CDP Page.navigate 跳转 ----------
$payload = [ordered]@{
    id     = 1
    method = 'Page.navigate'
    params = [ordered]@{ url = $Url }
} | ConvertTo-Json -Depth 5 -Compress

$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$sendSegment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$payloadBytes)

$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object System.Threading.CancellationTokenSource
$cts.CancelAfter(8000)

try {
    $ws.ConnectAsync([Uri]$wsUrl, $cts.Token).GetAwaiter().GetResult()
} catch {
    Write-Result ('WebSocket 连接失败: ' + $_.Exception.Message)
    try { $ws.Dispose() } catch {}
    exit 1
}

try {
    $ws.SendAsync($sendSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()

    $buffer = New-Object byte[] 8192
    $recvSegment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buffer)
    $sb = New-Object System.Text.StringBuilder

    do {
        $result = $ws.ReceiveAsync($recvSegment, $cts.Token).GetAwaiter().GetResult()
        if ($result.Count -gt 0) {
            [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
        }
    } while (-not $result.EndOfMessage)

    Write-Result ('CDP 应答: ' + $sb.ToString())
} catch {
    Write-Result ('CDP 通信异常: ' + $_.Exception.Message)
}

# 保持 1 秒后退出；不调用 /json/close，不关闭任何窗口
Start-Sleep -Seconds 1
try { $ws.Dispose() } catch {}
exit 0
