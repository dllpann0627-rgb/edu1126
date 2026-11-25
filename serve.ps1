param(
    [switch]$NoBrowser,
    [ValidateRange(0, 65535)][int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$routes = @{
    '/' = @('index.html', 'text/html; charset=utf-8')
    '/index.html' = @('index.html', 'text/html; charset=utf-8')
    '/app.css' = @('app.css', 'text/css; charset=utf-8')
    '/app.js' = @('app.js', 'application/javascript; charset=utf-8')
    '/data.js' = @('data.js', 'application/javascript; charset=utf-8')
    '/map.js' = @('map.js', 'application/javascript; charset=utf-8')
    '/coastal-sunset.webp' = @('coastal-sunset.webp', 'image/webp')
    '/boundaries/index.js' = @('boundaries/index.js', 'application/javascript; charset=utf-8')
}

function Write-HttpHeader($Stream, [string]$Status, [string]$Type, [long]$Length) {
    $headers = @(
        "HTTP/1.1 $Status"
        "Content-Type: $Type"
        "Content-Length: $Length"
        'Connection: close'
        'Cache-Control: no-store'
        'X-Content-Type-Options: nosniff'
        "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'"
        ''
        ''
    )
    $bytes = [Text.Encoding]::ASCII.GetBytes($headers -join "`r`n")
    $Stream.Write($bytes, 0, $bytes.Length)
}

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()
try {
    $actualPort = $listener.LocalEndpoint.Port
    $expectedHost = "127.0.0.1:$actualPort"
    $url = "http://$expectedHost/"
    Write-Host "Local URL: $url"
    Write-Host 'Keep this window open while using the app. Press Ctrl+C to stop.'
    if (-not $NoBrowser) {
        try { Start-Process $url }
        catch { Write-Warning 'Open the Local URL in your browser.' }
    }

    while ($true) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 35
            continue
        }
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 1500
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            try {
                $request = $reader.ReadLine()
                if ($request -cnotmatch '^(GET|HEAD) ([^ ]+) HTTP/1\.[01]$') {
                    Write-HttpHeader $stream '400 Bad Request' 'text/plain' 0
                    continue
                }
                $method = $Matches[1]
                $path = $Matches[2].Split('?')[0]
                $hostHeader = ""
                $complete = $false
                for ($i = 0; $i -lt 64; $i++) {
                    $header = $reader.ReadLine()
                    if ($null -eq $header) { break }
                    if ($header -eq '') { $complete = $true; break }
                    if ($header -match '^Host:\s*(\S+)$') { $hostHeader = $Matches[1] }
                }
                if (-not $complete -or $hostHeader -ne $expectedHost) {
                    Write-HttpHeader $stream '400 Bad Request' 'text/plain' 0
                    continue
                }
                $route = $routes[$path]
                if ($path -cmatch '^/boundaries/[0-9]{2}\.gz$') {
                    $route = @($path.Substring(1), 'application/octet-stream')
                }
                if (-not $route) {
                    Write-HttpHeader $stream '404 Not Found' 'text/plain' 0
                    continue
                }
                $filePath = Join-Path $PSScriptRoot $route[0]
                if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                    Write-HttpHeader $stream '404 Not Found' 'text/plain' 0
                    continue
                }
                $file = [IO.File]::OpenRead($filePath)
                try {
                    Write-HttpHeader $stream '200 OK' $route[1] $file.Length
                    if ($method -eq 'GET') { $file.CopyTo($stream) }
                } finally {
                    $file.Dispose()
                }
            } finally {
                $reader.Dispose()
            }
        } catch [IO.IOException] {
            # Browsers may cancel requests or close unused connections.
        } finally {
            $client.Dispose()
        }
    }
} finally {
    $listener.Stop()
}
