#Requires -Version 7.0
<#
.SYNOPSIS
    Single-surface Netizen Swagger launcher and OpenAPI-route-aware forwarder.
.DESCRIPTION
    This draft intentionally excludes local-swagger's dual listeners, credential
    sourcing and injection, anonymous projection, and mutation metadata.

    Configuration is optional. Without -Config, the launcher uses
    netizen.config.json beside the script, creating it after the OpenAPI
    document has been resolved unambiguously.

    OpenAPI document resolution order:

    1. -Spec
    2. specPath from the configuration document
    3. exactly one adjacent versioned OpenAPI JSON document
    4. failure

    Configuration shape:

    {
      "specPath": "./tvmaze_openapi_v3.0.3.json",
      "upstream": {
        "baseUrl": null,
        "requestHeaders": {}
      }
    }

    The upstream object is optional. When upstream.baseUrl is absent, blank, or
    null, the launcher resolves the first root OpenAPI Server Object using each
    Server Variable Object's default value.

    Swagger Try It Out requests carry the fully rendered selected server base
    to the loopback gateway as reserved per-request control metadata. The
    gateway accepts that computed HTTP(S) base without interpreting individual
    server variables, removes the control header before forwarding, and uses
    the configured/resolved startup base only when the header is absent.

    When upstream.baseUrl is explicitly populated, the in-memory OpenAPI
    document served to Swagger prepends that concrete URL as the default Server
    Object. Existing variable-based Server Objects remain available for user
    selection. The source OpenAPI file is not modified.
.PARAMETER Config
    Optional service configuration document. Defaults to netizen.config.json
    beside the script. Relative paths within it resolve from its directory.
.PARAMETER Spec
    Optional OpenAPI document. Takes precedence over config specPath and
    adjacent-document discovery. Relative paths resolve from the current
    working directory.
.PARAMETER Port
    Preferred loopback port. Defaults to 8080 and may fall forward by ten ports.
.PARAMETER KeepAlive
    Disable the normal 120-second post-load inactivity shutdown.
#>
[CmdletBinding()]
param(
    [string]$Config,

    [string]$Spec,

    [int]$Port = 8080,

    [switch]$KeepAlive
)

$ErrorActionPreference = 'Stop'
$script:Utf8 = [Text.UTF8Encoding]::new($false)

function Resolve-NetizenConfigPath {
    param([string]$BaseDirectory, [string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Assert-NetizenConfigProperties {
    param([object]$Object, [string[]]$Names, [string]$Prefix = '')
    foreach ($name in $Names) {
        if ($null -eq $Object.$name) { throw "Config property '$Prefix$name' is required." }
    }
}

function Install-NetizenSwaggerUiAssets {
    param([string]$CacheDirectory)

    $required = [ordered]@{
        stylesheet = [pscustomobject]@{ Name = 'swagger-ui.css'; Route = '/assets/swagger-ui.css'; ContentType = 'text/css; charset=utf-8' }
        bundle = [pscustomobject]@{ Name = 'swagger-ui-bundle.js'; Route = '/assets/swagger-ui-bundle.js'; ContentType = 'application/javascript; charset=utf-8' }
        preset = [pscustomobject]@{ Name = 'swagger-ui-standalone-preset.js'; Route = '/assets/swagger-ui-standalone-preset.js'; ContentType = 'application/javascript; charset=utf-8' }
    }
    $missing = @($required.Values | Where-Object { -not (Test-Path -LiteralPath (Join-Path $CacheDirectory $_.Name) -PathType Leaf) })
    if ($missing.Count -eq 0) {
        return [pscustomobject]@{ Assets = $required; Directory = $CacheDirectory }
    }

    New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
    $archivePath = Join-Path $CacheDirectory 'swagger-ui-release.zip'
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $releaseUrl = 'https://api.github.com/repos/swagger-api/swagger-ui/releases/latest'
        $headers = @{ 'User-Agent' = [Microsoft.PowerShell.Commands.PSUserAgent]::Chrome }
        $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers
        if ([string]::IsNullOrWhiteSpace([string]$release.zipball_url)) {
            throw 'The latest Swagger UI GitHub release did not provide zipball_url.'
        }

        $downloadPath = "$archivePath.download"
        try {
            Write-Host "Downloading latest Swagger UI release archive ($($release.tag_name))..."
            Invoke-WebRequest -Uri $release.zipball_url -Headers $headers -OutFile $downloadPath -UseBasicParsing | Out-Null
            Move-Item -LiteralPath $downloadPath -Destination $archivePath -Force
        } finally {
            if (Test-Path -LiteralPath $downloadPath -PathType Leaf) {
                Remove-Item -LiteralPath $downloadPath -Force
            }
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($asset in $required.Values) {
            $entries = @($archive.Entries | Where-Object {
                $_.FullName -ceq "dist/$($asset.Name)" -or
                $_.FullName.EndsWith("/dist/$($asset.Name)", [StringComparison]::Ordinal)
            })
            if ($entries.Count -ne 1) {
                throw "Swagger UI archive must contain exactly one dist/$($asset.Name); found $($entries.Count)."
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], (Join-Path $CacheDirectory $asset.Name), $true)
        }
    } finally {
        $archive.Dispose()
    }

    return [pscustomobject]@{ Assets = $required; Directory = $CacheDirectory }
}

function Convert-NetizenOpenApiPathToRegex {
    param([string]$Path)
    $options = [Text.RegularExpressions.RegexOptions]::Compiled -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
    if ($Path -ceq '/') { return [regex]::new('^/$', $options) }

    $matchPath = $Path.TrimEnd('/')
    $pattern = [Text.StringBuilder]::new('^')
    $offset = 0
    foreach ($match in [regex]::Matches($matchPath, '\{[^}]+\}')) {
        $null = $pattern.Append([regex]::Escape($matchPath.Substring($offset, $match.Index - $offset)))
        $null = $pattern.Append('[^/]+')
        $offset = $match.Index + $match.Length
    }
    $null = $pattern.Append([regex]::Escape($matchPath.Substring($offset)))
    $null = $pattern.Append('/?$')
    return [regex]::new($pattern.ToString(), $options)
}

function Convert-NetizenOpenApiPathToSuffixRegexSource {
    param([string]$Path)
    if ($Path -ceq '/') { return '/$' }

    $matchPath = $Path.TrimEnd('/')
    $pattern = [Text.StringBuilder]::new()
    $offset = 0
    foreach ($match in [regex]::Matches($matchPath, '\{[^}]+\}')) {
        $null = $pattern.Append([regex]::Escape($matchPath.Substring($offset, $match.Index - $offset)))
        $null = $pattern.Append('[^/]+')
        $offset = $match.Index + $match.Length
    }
    $null = $pattern.Append([regex]::Escape($matchPath.Substring($offset)))
    $null = $pattern.Append('/?$')
    return $pattern.ToString()
}

function Resolve-NetizenOpenApiReference {
    param([object]$Spec, [object]$Value, [string]$Kind)
    $resolved = $Value
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($null -ne $resolved -and $null -ne $resolved.'$ref') {
        $reference = [string]$resolved.'$ref'
        if (-not $reference.StartsWith('#/', [StringComparison]::Ordinal)) {
            throw "External OpenAPI $Kind reference is not supported for runtime routing: $reference"
        }
        if (-not $visited.Add($reference)) {
            throw "Cyclic OpenAPI $Kind reference is not supported for runtime routing: $reference"
        }
        $resolved = $Spec
        foreach ($token in $reference.Substring(2).Split('/')) {
            $name = $token.Replace('~1', '/').Replace('~0', '~')
            $property = $resolved.PSObject.Properties[$name]
            if ($null -eq $property) { throw "OpenAPI $Kind reference did not resolve: $reference" }
            $resolved = $property.Value
        }
    }
    return $resolved
}

function Get-NetizenOpenApiRoutes {
    param([object]$Spec)
    $httpMethods = @('get', 'post', 'put', 'patch', 'delete', 'head', 'options', 'trace')
    $routes = foreach ($pathProperty in $Spec.paths.PSObject.Properties) {
        $pathItem = Resolve-NetizenOpenApiReference $Spec $pathProperty.Value 'Path Item'
        foreach ($method in $httpMethods) {
            if ($null -eq $pathItem.$method) { continue }
            $operation = $pathItem.$method
            $requestBody = Resolve-NetizenOpenApiReference $Spec $operation.requestBody 'request body'
            [pscustomobject]@{
                Method = $method.ToUpperInvariant()
                Template = $pathProperty.Name
                Regex = Convert-NetizenOpenApiPathToRegex $pathProperty.Name
                IsTemplated = $pathProperty.Name.Contains('{', [StringComparison]::Ordinal)
                RequestContentTypes = if ($null -ne $requestBody -and $null -ne $requestBody.content) {
                    @($requestBody.content.PSObject.Properties.Name)
                } else { @() }
            }
        }
    }
    return @($routes)
}

function Find-NetizenOpenApiRoute {
    param([object[]]$Routes, [string]$Method, [string]$Path)
    $pathMatches = @($Routes | Where-Object { $_.Regex.IsMatch($Path) })
    $route = $pathMatches | Where-Object Method -eq $Method | Sort-Object IsTemplated | Select-Object -First 1
    return [pscustomobject]@{ Route = $route; PathMatched = $pathMatches.Count -gt 0 }
}

function Get-NetizenDefaultUpstreamBaseUrl {
    param([object]$Spec)
    $rootServers = @($Spec.servers)
    if ($rootServers.Count -eq 0) {
        throw 'upstream.baseUrl was not configured and the OpenAPI document declares no root servers.'
    }

    $server = $rootServers[0]
    $url = [string]$server.url
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw 'The first root OpenAPI Server Object has no URL.'
    }
    if ($null -ne $server.variables) {
        foreach ($variable in $server.variables.PSObject.Properties) {
            if ($null -eq $variable.Value.default) {
                throw "OpenAPI server variable '$($variable.Name)' has no default value."
            }
            $url = $url.Replace("{$($variable.Name)}", [string]$variable.Value.default, [StringComparison]::Ordinal)
        }
    }
    if ([regex]::IsMatch($url, '\{[^}]+\}')) {
        throw "The first root OpenAPI server URL contains an unresolved variable: '$url'."
    }
    return $url
}

function Resolve-NetizenUpstreamBaseUrl {
    param([object]$Spec, [object]$Upstream)
    $configuredBaseUrl = if ($null -ne $Upstream) { [string]$Upstream.baseUrl } else { $null }
    $candidate = if ([string]::IsNullOrWhiteSpace($configuredBaseUrl)) {
        Get-NetizenDefaultUpstreamBaseUrl $Spec
    } else {
        $configuredBaseUrl
    }

    [uri]$resolvedUri = $null
    if (-not [uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$resolvedUri) -or $resolvedUri.Scheme -notin @('http', 'https')) {
        throw "The resolved upstream base URL must be an absolute HTTP or HTTPS URL: '$candidate'."
    }
    if (-not [string]::IsNullOrEmpty($resolvedUri.Query) -or -not [string]::IsNullOrEmpty($resolvedUri.Fragment)) {
        throw "The resolved upstream base URL must not contain a query or fragment: '$candidate'."
    }
    return $resolvedUri.AbsoluteUri.TrimEnd('/')
}

function New-NetizenRuntimeOpenApiJson {
    param([string]$SourceJson, [string]$ConfiguredBaseUrl)

    $runtime = $SourceJson | ConvertFrom-Json -Depth 100 -DateKind String
    $configuredServer = [pscustomobject][ordered]@{
        url = $ConfiguredBaseUrl
        description = 'Runtime-configured default upstream.'
    }
    $prependDefault = {
        param([object]$Container, [bool]$Required)
        if ($null -eq $Container) { return }
        $serversProperty = $Container.PSObject.Properties['servers']
        if (-not $Required -and $null -eq $serversProperty) { return }

        $existing = if ($null -ne $serversProperty) { @($serversProperty.Value) } else { @() }
        $matching = $existing | Where-Object {
            [string]::Equals([string]$_.url, $ConfiguredBaseUrl, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        $defaultServer = if ($null -ne $matching) { $matching } else { $configuredServer }
        $remaining = @($existing | Where-Object {
            -not [string]::Equals([string]$_.url, $ConfiguredBaseUrl, [StringComparison]::OrdinalIgnoreCase)
        })
        $newServers = @($defaultServer) + $remaining
        $Container | Add-Member -NotePropertyName servers -NotePropertyValue $newServers -Force
    }

    & $prependDefault $runtime $true
    foreach ($pathProperty in $runtime.paths.PSObject.Properties) {
        $pathItem = Resolve-NetizenOpenApiReference $runtime $pathProperty.Value 'Path Item'
        & $prependDefault $pathItem $false
        foreach ($method in @('get', 'post', 'put', 'patch', 'delete', 'head', 'options', 'trace')) {
            if ($null -ne $pathItem.$method) { & $prependDefault $pathItem.$method $false }
        }
    }
    return $runtime | ConvertTo-Json -Depth 100
}

function Get-NetizenHopByHopHeaderNames {
    param([object]$Headers)
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(
        'Connection', 'Keep-Alive', 'Proxy-Authenticate', 'Proxy-Authorization',
        'TE', 'Trailer', 'Transfer-Encoding', 'Upgrade'
    )) { $null = $names.Add($name) }

    if ($null -ne $Headers) {
        $connectionValues = @()
        if ($Headers -is [Net.WebHeaderCollection]) {
            if ($null -ne $Headers['Connection']) { $connectionValues = @($Headers.GetValues('Connection')) }
        } else {
            [Collections.Generic.IEnumerable[string]]$values = $null
            if ($Headers.TryGetValues('Connection', [ref]$values)) { $connectionValues = @($values) }
        }
        foreach ($connectionValue in $connectionValues) {
            foreach ($token in ([string]$connectionValue).Split(',')) {
                $candidate = $token.Trim()
                if (-not [string]::IsNullOrEmpty($candidate)) { $null = $names.Add($candidate) }
            }
        }
    }
    return ,$names
}

function Test-NetizenUpstreamRequestHeaders {
    param([object]$Headers, [string]$ReservedUpstreamBaseHeader)
    if ($null -eq $Headers) { return }
    $hopByHopNames = Get-NetizenHopByHopHeaderNames $null
    foreach ($header in $Headers.PSObject.Properties) {
        if ([string]::Equals([string]$header.Name, $ReservedUpstreamBaseHeader, [StringComparison]::OrdinalIgnoreCase)) {
            throw "upstream.requestHeaders cannot configure reserved header '$ReservedUpstreamBaseHeader'."
        }
        if ($hopByHopNames.Contains([string]$header.Name)) {
            throw "upstream.requestHeaders cannot configure hop-by-hop header '$($header.Name)'."
        }
    }
}

function Resolve-NetizenRequestUpstreamBaseUrl {
    param(
        [Net.WebHeaderCollection]$Headers,
        [string]$FallbackBaseUrl,
        [string]$SelectionHeader
    )

    $rawValues = $Headers.GetValues($SelectionHeader)
    if ($null -eq $rawValues) { return $FallbackBaseUrl }
    $values = @($rawValues)
    if ($values.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$values[0])) {
        throw "Request header '$SelectionHeader' must contain exactly one non-empty value."
    }

    $candidate = ([string]$values[0]).Trim()
    [uri]$parsed = $null
    if (
        -not [uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -notin @('http', 'https') -or
        [string]::IsNullOrWhiteSpace($parsed.Host)
    ) {
        throw "Request header '$SelectionHeader' must contain an absolute HTTP or HTTPS base URL."
    }
    if (-not [string]::IsNullOrEmpty($parsed.Query) -or -not [string]::IsNullOrEmpty($parsed.Fragment)) {
        throw "Request header '$SelectionHeader' must not contain a query or fragment."
    }
    return $parsed.AbsoluteUri.TrimEnd('/')
}

function Write-NetizenResponseBytes {
    param(
        [Net.HttpListenerResponse]$Response,
        [byte[]]$Bytes,
        [string]$ContentType,
        [int]$StatusCode = 200,
        [object]$Headers = @()
    )
    $Response.StatusCode = $StatusCode
    if (-not [string]::IsNullOrEmpty($ContentType)) { $Response.ContentType = $ContentType }
    foreach ($header in $Headers) { $Response.AppendHeader([string]$header.Name, [string]$header.Value) }
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Write-NetizenLocalFailure {
    param([Net.HttpListenerResponse]$Response, [int]$StatusCode, [string]$Code)
    $bytes = $script:Utf8.GetBytes((@{ error = $Code } | ConvertTo-Json -Compress))
    Write-NetizenResponseBytes $Response $bytes 'application/json; charset=utf-8' $StatusCode
}

function New-NetizenSwaggerBootstrapHtml {
    param([string]$Title, [string]$RuntimeJson)
    $encodedTitle = [Net.WebUtility]::HtmlEncode($Title)
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$encodedTitle</title>
  <style>
    body{margin:0;padding:0}.asset-toolbar{position:sticky;top:0;z-index:10;padding:10px 12px;background:#101017;color:#d5d5e0;font:12px "Segoe UI",Arial,sans-serif;border-bottom:1px solid #ffffff24}.auth-guidance{margin-top:6px;color:#ffe08a}.auth-guidance strong{color:#fff}
    #swagger-ui .topbar{background-color:#1a1a2e}#swagger-ui .topbar-wrapper img{display:none}
  </style>
</head>
<body><div class="asset-toolbar"><div id="asset-status">Initializing Swagger UI assets...</div><div class="auth-guidance">After entering a credential, click <strong>Authorize</strong> inside that credential block. Closing the dialog does not apply it; a closed lock confirms it is active.</div></div><div id="swagger-ui"></div>
<script>
const CONFIG=$RuntimeJson,statusEl=document.getElementById('asset-status');
const load=(tag,attrs)=>new Promise((resolve,reject)=>{const el=document.createElement(tag);Object.assign(el,attrs);el.onload=resolve;el.onerror=()=>reject(new Error('Failed to load '+(attrs.src||attrs.href)));document[tag==='link'?'head':'body'].appendChild(el)});
const ROUTES=CONFIG.routes.map(route=>({...route,matcher:new RegExp(route.suffixPattern)}));
function requestInterceptor(req){
  const target=new URL(req.url,window.location.origin);
  const localControlRoutes=[CONFIG.specRoute,...Object.values(CONFIG.assets)];
  if(target.origin===window.location.origin&&localControlRoutes.includes(target.pathname))return req;
  if(target.origin===window.location.origin&&(target.pathname===CONFIG.forwardingRoute||target.pathname.startsWith(CONFIG.forwardingRoute+'/')))return req;
  const method=(req.method||'GET').toUpperCase();
  let selected=null;
  for(const route of ROUTES){
    if(route.method!==method)continue;
    const match=route.matcher.exec(target.pathname);
    if(match){selected={route,match};break}
  }
  if(!selected)throw new Error('Computed Swagger request URL did not end with a declared OpenAPI operation path.');
  const renderedBase=target.origin+target.pathname.slice(0,selected.match.index);
  req.headers=Object.assign({},req.headers||{},{[CONFIG.upstreamBaseHeader]:renderedBase});
  req.url=window.location.origin+CONFIG.forwardingRoute+selected.match[0]+target.search;
  return req;
}
(async()=>{try{await load('link',{rel:'stylesheet',href:CONFIG.assets.stylesheet});await load('script',{src:CONFIG.assets.bundle});await load('script',{src:CONFIG.assets.preset});SwaggerUIBundle({url:CONFIG.specRoute,dom_id:'#swagger-ui',presets:[SwaggerUIBundle.presets.apis,SwaggerUIStandalonePreset],layout:'StandaloneLayout',tryItOutEnabled:true,persistAuthorization:true,deepLinking:true,displayRequestDuration:true,defaultModelsExpandDepth:1,defaultModelExpandDepth:2,docExpansion:'list',filter:true,validatorUrl:null,requestInterceptor});statusEl.textContent='Swagger UI loaded from local assets.'}catch(error){statusEl.textContent='Swagger UI load failed: '+error.message}})();
</script></body></html>
"@
}

function ConvertTo-NetizenSwaggerRuntimeJson {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Depth 5 -Compress -EscapeHandling EscapeHtml)
}

function Wait-NetizenWork {
    param(
        [object]$PendingContext,
        [object[]]$RequestJobs,
        [bool]$IncludeListener,
        [int]$TimeoutMilliseconds
    )
    $entries = [Collections.Generic.List[object]]::new()
    if ($IncludeListener) {
        $entries.Add([pscustomobject]@{ Kind = 'listener'; Owner = $PendingContext; Handle = ([IAsyncResult]$PendingContext).AsyncWaitHandle })
    }
    foreach ($job in $RequestJobs) {
        $entries.Add([pscustomobject]@{ Kind = 'job'; Owner = $job; Handle = $job.Finished })
    }
    if ($entries.Count -eq 0) { throw 'No listener or request-job wait handle is available.' }

    $handles = [Threading.WaitHandle[]]@($entries | ForEach-Object Handle)
    $index = [Threading.WaitHandle]::WaitAny($handles, $TimeoutMilliseconds)
    if ($index -eq [Threading.WaitHandle]::WaitTimeout) { return $null }
    return $entries[$index]
}

function Complete-NetizenRequestJob {
    param([Management.Automation.Job]$Job)
    $succeeded = $true
    try {
        Receive-Job -Job $Job -Wait -ErrorAction Stop | Out-Host
    } catch {
        $succeeded = $false
        try { Write-Warning 'Request worker failed: request_worker_failed.' } catch {}
    } finally {
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
    return $succeeded
}

$configWasExplicit = $PSBoundParameters.ContainsKey('Config')
if ($configWasExplicit -and [string]::IsNullOrWhiteSpace($Config)) {
    throw '-Config must name a configuration document when supplied.'
}
$specWasExplicit = $PSBoundParameters.ContainsKey('Spec')
if ($specWasExplicit -and [string]::IsNullOrWhiteSpace($Spec)) {
    throw '-Spec must name an OpenAPI document when supplied.'
}

$configPath = if ($configWasExplicit) {
    Resolve-NetizenConfigPath ([string](Get-Location).Path) $Config
} else {
    Join-Path $PSScriptRoot 'netizen.config.json'
}
$configDirectory = Split-Path -Parent $configPath
if (-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
    throw "Configuration directory not found: $configDirectory"
}

$configExists = Test-Path -LiteralPath $configPath -PathType Leaf
$settings = if ($configExists) {
    Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} else {
    [pscustomobject][ordered]@{
        specPath = $null
        upstream = [pscustomobject][ordered]@{
            baseUrl = $null
            requestHeaders = [pscustomobject]@{}
        }
    }
}

$specPath = if (-not [string]::IsNullOrWhiteSpace($Spec)) {
    Resolve-NetizenConfigPath ([string](Get-Location).Path) $Spec
} elseif (-not [string]::IsNullOrWhiteSpace([string]$settings.specPath)) {
    Resolve-NetizenConfigPath $configDirectory ([string]$settings.specPath)
} else {
    $discoveredSpecs = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.json' |
            Where-Object Name -Match '(?i)(?:^|[_-])openapi[_-]v\d+(?:\.\d+)+.*\.json$' |
            Sort-Object Name
    )
    if ($discoveredSpecs.Count -eq 0) {
        throw 'No OpenAPI document was selected: supply -Spec, set config specPath, or place exactly one versioned OpenAPI JSON file beside the launcher.'
    }
    if ($discoveredSpecs.Count -gt 1) {
        $names = $discoveredSpecs.Name -join ', '
        throw "Multiple adjacent OpenAPI documents were found ($names): supply -Spec or set config specPath."
    }
    $discoveredSpecs[0].FullName
}

$cacheDirectory = Join-Path $PSScriptRoot '.swagger-ui'
if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) { throw "Required file not found: $specPath" }

$sourceSpecJson = Get-Content -LiteralPath $specPath -Raw
$openApiDocument = $sourceSpecJson | ConvertFrom-Json -Depth 100 -DateKind String
Assert-NetizenConfigProperties $openApiDocument @('openapi', 'info', 'paths') 'OpenAPI document.'
Assert-NetizenConfigProperties $openApiDocument.info @('title') 'OpenAPI document.info.'

if (-not $configExists) {
    $relativeSpecPath = [IO.Path]::GetRelativePath($configDirectory, $specPath).Replace('\', '/')
    if (-not $relativeSpecPath.StartsWith('.', [StringComparison]::Ordinal)) {
        $relativeSpecPath = "./$relativeSpecPath"
    }
    $settings.specPath = $relativeSpecPath

    $configJson = $settings | ConvertTo-Json -Depth 10
    $temporaryConfigPath = "$configPath.new"
    try {
        [IO.File]::WriteAllText($temporaryConfigPath, "$configJson`n", $script:Utf8)
        Move-Item -LiteralPath $temporaryConfigPath -Destination $configPath
    } finally {
        if (Test-Path -LiteralPath $temporaryConfigPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryConfigPath -Force
        }
    }
    Write-Host "Created configuration: $configPath"
}

$title = [string]$openApiDocument.info.title
$forwardingRoute = '/api'
$upstreamBaseHeader = 'X-Netizen-Upstream-Base'
$configuredUpstreamBaseUrl = if ($null -ne $settings.upstream) { [string]$settings.upstream.baseUrl } else { $null }
$hasConfiguredUpstreamBaseUrl = -not [string]::IsNullOrWhiteSpace($configuredUpstreamBaseUrl)
$upstreamBaseUrl = Resolve-NetizenUpstreamBaseUrl $openApiDocument $settings.upstream
$swaggerSpecJson = if ($hasConfiguredUpstreamBaseUrl) {
    New-NetizenRuntimeOpenApiJson $sourceSpecJson $upstreamBaseUrl
} else {
    $sourceSpecJson
}
$requestHeaders = if ($null -ne $settings.upstream) { $settings.upstream.requestHeaders } else { $null }
Test-NetizenUpstreamRequestHeaders $requestHeaders $upstreamBaseHeader
$runtimeSettings = [pscustomobject]@{
    upstream = [pscustomobject]@{
        baseUrl = $upstreamBaseUrl
        requestHeaders = $requestHeaders
    }
    upstreamBaseHeader = $upstreamBaseHeader
}
$openApiRoutes = Get-NetizenOpenApiRoutes $openApiDocument
if ($openApiRoutes.Count -eq 0) { throw 'The OpenAPI document contains no supported routes.' }
$swaggerRouteDescriptors = @(
    $openApiRoutes |
        Sort-Object IsTemplated, @{ Expression = { $_.Template.Length }; Descending = $true } |
        ForEach-Object {
            [ordered]@{
                method = $_.Method
                template = $_.Template
                suffixPattern = Convert-NetizenOpenApiPathToSuffixRegexSource $_.Template
            }
        }
)

$swaggerAssets = Install-NetizenSwaggerUiAssets $cacheDirectory
$assetRoutes = @{}
$assetPayloads = @{}
foreach ($entry in $swaggerAssets.Assets.GetEnumerator()) {
    $asset = $entry.Value
    $assetRoutes[$entry.Key] = $asset.Route
    $assetPayloads[$asset.Route] = [pscustomobject]@{
        Path = Join-Path $swaggerAssets.Directory $asset.Name
        ContentType = $asset.ContentType
    }
}

$specRoute = '/openapi.json'
$runtimeConfig = [ordered]@{
    title = $title
    specRoute = $specRoute
    forwardingRoute = $forwardingRoute
    assets = [ordered]@{
        stylesheet = $assetRoutes.stylesheet
        bundle = $assetRoutes.bundle
        preset = $assetRoutes.preset
    }
    upstreamBaseHeader = $upstreamBaseHeader
    routes = $swaggerRouteDescriptors
}
$runtimeJson = ConvertTo-NetizenSwaggerRuntimeJson $runtimeConfig
$indexBytes = $script:Utf8.GetBytes((New-NetizenSwaggerBootstrapHtml $title $runtimeJson))
$specBytes = $script:Utf8.GetBytes($swaggerSpecJson)

$regexOptions = [Text.RegularExpressions.RegexOptions]::Compiled -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
$forwardingRegex = [regex]::new('^' + [regex]::Escape($forwardingRoute) + '(?<forwardedPath>/.*)?$', $regexOptions)
foreach ($reservedRoute in @('/', $specRoute) + @($assetPayloads.Keys)) {
    if ($forwardingRegex.IsMatch($reservedRoute)) { throw "forwardingRoute overlaps local route '$reservedRoute'." }
}

$listener = $null
$boundPort = $null
$lastBindError = $null
foreach ($candidatePort in $Port..($Port + 10)) {
    $candidate = [Net.HttpListener]::new()
    $candidate.Prefixes.Add("http://127.0.0.1:$candidatePort/")
    try {
        $candidate.Start()
        $listener = $candidate
        $boundPort = $candidatePort
        break
    } catch {
        $lastBindError = $_.Exception
        $candidate.Close()
    }
}
if ($null -eq $listener) {
    throw "Could not bind to any port in range $Port-$($Port + 10). $($lastBindError.Message)"
}

$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.UseProxy = $false
$httpClient = [Net.Http.HttpClient]::new($handler)
$browserUrl = "http://127.0.0.1:$boundPort/"

Write-Host "Serving configuration: $configPath"
Write-Host "Serving OpenAPI document: $specPath"
Write-Host "Loaded OpenAPI routes: $($openApiRoutes.Count)"
Write-Host "OpenAPI version: $($openApiDocument.openapi)"
Write-Host "Open: $browserUrl"
if ($KeepAlive) {
    Write-Host 'KeepAlive enabled - Ctrl+C to stop.'
} else {
    Write-Host 'Auto-stops after 120 seconds of inactivity following the initial page load.'
}
Start-Process $browserUrl

$workerFunctionNames = @(
    'Write-NetizenResponseBytes', 'Write-NetizenLocalFailure',
    'Find-NetizenOpenApiRoute', 'Get-NetizenHopByHopHeaderNames',
    'Resolve-NetizenRequestUpstreamBaseUrl'
)
$workerInitializationText = '$script:Utf8 = [System.Text.UTF8Encoding]::new($false)'
foreach ($functionName in $workerFunctionNames) {
    $workerInitializationText += "`nfunction $functionName {`n$((Get-Command $functionName -CommandType Function).Definition)`n}`n"
}
$workerInitialization = [scriptblock]::Create($workerInitializationText)
$requestJobs = [Collections.Generic.List[object]]::new()
$pendingContext = $null
$lastRequest = [DateTime]::UtcNow
$initialLoad = $false
$idleTimeout = [TimeSpan]::FromSeconds(120)
$cancellationPollMilliseconds = 1000
$maxConcurrentRequests = 8

try {
    while ($listener.IsListening) {
        foreach ($completedJob in @($requestJobs | Where-Object State -in @('Completed', 'Failed', 'Stopped'))) {
            $null = Complete-NetizenRequestJob $completedJob
            $null = $requestJobs.Remove($completedJob)
        }

        $canAcceptRequest = $requestJobs.Count -lt $maxConcurrentRequests
        if ($canAcceptRequest -and $null -eq $pendingContext) { $pendingContext = $listener.GetContextAsync() }

        # Returning to PowerShell periodically is the console-cancellation boundary.
        $timeoutMilliseconds = $cancellationPollMilliseconds
        if ($initialLoad -and -not $KeepAlive) {
            $remaining = $idleTimeout - ([DateTime]::UtcNow - $lastRequest)
            if ($remaining -le [TimeSpan]::Zero) {
                Write-Host 'No activity for 120 seconds - shutting down.'
                break
            }
            $timeoutMilliseconds = [Math]::Min(
                $cancellationPollMilliseconds,
                [Math]::Max(1, [int][Math]::Ceiling($remaining.TotalMilliseconds))
            )
        }

        $signaled = Wait-NetizenWork $pendingContext @($requestJobs) $canAcceptRequest $timeoutMilliseconds
        if ($null -eq $signaled) { continue }
        if ($signaled.Kind -eq 'job') {
            $null = Complete-NetizenRequestJob $signaled.Owner
            $null = $requestJobs.Remove($signaled.Owner)
            continue
        }

        $completedTask = $pendingContext
        $pendingContext = $null
        try { $context = $completedTask.GetAwaiter().GetResult() }
        finally { $completedTask.Dispose() }
        $lastRequest = [DateTime]::UtcNow
        if ([string]::Equals($context.Request.Url.AbsolutePath, '/', [StringComparison]::Ordinal)) { $initialLoad = $true }

        $requestHandler = {
            param(
                [Net.HttpListenerContext]$Context,
                [byte[]]$IndexBytes,
                [byte[]]$SpecBytes,
                [string]$SpecRoute,
                [hashtable]$AssetPayloads,
                [regex]$ForwardingRegex,
                [object]$Settings,
                [object[]]$OpenApiRoutes,
                [Net.Http.HttpClient]$HttpClient
            )
            $request = $Context.Request
            $response = $Context.Response
            $path = $request.Url.AbsolutePath
            $responseAttempted = $false

            try {
                try {
                    if ([string]::Equals($path, '/', [StringComparison]::Ordinal)) {
                        $responseAttempted = $true
                        Write-NetizenResponseBytes $response $IndexBytes 'text/html; charset=utf-8'
                        return
                    }
                    if ([string]::Equals($path, $SpecRoute, [StringComparison]::Ordinal)) {
                        $responseAttempted = $true
                        Write-NetizenResponseBytes $response $SpecBytes 'application/json; charset=utf-8'
                        return
                    }
                    if ($AssetPayloads.ContainsKey($path)) {
                        $asset = $AssetPayloads[$path]
                        $assetBytes = [IO.File]::ReadAllBytes($asset.Path)
                        $responseAttempted = $true
                        Write-NetizenResponseBytes $response $assetBytes $asset.ContentType
                        return
                    }

                    $forwardingMatch = $ForwardingRegex.Match($path)
                    if (-not $forwardingMatch.Success) {
                        $responseAttempted = $true
                        Write-NetizenLocalFailure $response 404 'route_not_found'
                        return
                    }
                    $apiPath = $forwardingMatch.Groups['forwardedPath'].Value
                    if ([string]::IsNullOrEmpty($apiPath)) { $apiPath = '/' }
                    $routeMatch = Find-NetizenOpenApiRoute $OpenApiRoutes $request.HttpMethod $apiPath
                    if ($null -eq $routeMatch.Route) {
                        $responseAttempted = $true
                        if ($routeMatch.PathMatched) {
                            Write-NetizenLocalFailure $response 405 'method_not_allowed'
                        } else {
                            Write-NetizenLocalFailure $response 404 'openapi_route_not_found'
                        }
                        return
                    }

                    try {
                        $requestUpstreamBaseUrl = Resolve-NetizenRequestUpstreamBaseUrl $request.Headers $Settings.upstream.baseUrl $Settings.upstreamBaseHeader
                    } catch {
                        $responseAttempted = $true
                        Write-NetizenLocalFailure $response 400 'invalid_upstream_base'
                        return
                    }

                    $upstreamRequest = $null
                    try {
                        $target = [uri]($requestUpstreamBaseUrl.TrimEnd('/') + $apiPath + $request.Url.Query)
                        $upstreamRequest = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($request.HttpMethod), $target)
                        $deferredContentHeaders = [Collections.Generic.List[object]]::new()
                        $hopByHopNames = Get-NetizenHopByHopHeaderNames $request.Headers
                        foreach ($key in $request.Headers.AllKeys) {
                            if ($key -in @('Host', 'Content-Length', 'Accept-Encoding', 'Content-Type', $Settings.upstreamBaseHeader) -or $hopByHopNames.Contains($key)) { continue }
                            if (-not $upstreamRequest.Headers.TryAddWithoutValidation($key, $request.Headers.GetValues($key))) {
                                $deferredContentHeaders.Add([pscustomobject]@{ Name = $key; Values = @($request.Headers.GetValues($key)) })
                            }
                        }

                        $configuredContentType = $null
                        if ($null -ne $Settings.upstream.requestHeaders) {
                            foreach ($header in $Settings.upstream.requestHeaders.PSObject.Properties) {
                                $isRequestHeader = $upstreamRequest.Headers.TryAddWithoutValidation($header.Name, [string]$header.Value)
                                if ($isRequestHeader) {
                                    $null = $upstreamRequest.Headers.Remove($header.Name)
                                    $null = $upstreamRequest.Headers.TryAddWithoutValidation($header.Name, [string]$header.Value)
                                } else {
                                    for ($i = $deferredContentHeaders.Count - 1; $i -ge 0; $i--) {
                                        if ($deferredContentHeaders[$i].Name -ieq $header.Name) { $deferredContentHeaders.RemoveAt($i) }
                                    }
                                    if ($header.Name -ieq 'Content-Type') {
                                        $configuredContentType = [string]$header.Value
                                    } else {
                                        $deferredContentHeaders.Add([pscustomobject]@{ Name = $header.Name; Values = @([string]$header.Value) })
                                    }
                                }
                            }
                        }

                        $hasContentMetadata = -not [string]::IsNullOrEmpty($request.ContentType) -or -not [string]::IsNullOrEmpty($configuredContentType) -or $deferredContentHeaders.Count -gt 0
                        if ($request.HasEntityBody -or $hasContentMetadata) {
                            $requestBytes = [byte[]]@()
                            if ($request.HasEntityBody) {
                                $memory = [IO.MemoryStream]::new()
                                $request.InputStream.CopyTo($memory)
                                $requestBytes = $memory.ToArray()
                                $memory.Dispose()
                            }
                            $upstreamRequest.Content = [Net.Http.ByteArrayContent]::new($requestBytes)
                            $requestContentType = if ($configuredContentType) {
                                $configuredContentType
                            } elseif ($request.ContentType) {
                                $request.ContentType
                            } elseif ($request.HasEntityBody) {
                                @($routeMatch.Route.RequestContentTypes)[0]
                            } else { $null }
                            if ($requestContentType) { $null = $upstreamRequest.Content.Headers.TryAddWithoutValidation('Content-Type', $requestContentType) }
                            foreach ($contentHeader in $deferredContentHeaders) {
                                $null = $upstreamRequest.Content.Headers.TryAddWithoutValidation($contentHeader.Name, $contentHeader.Values)
                            }
                        }

                        $upstreamResponse = $null
                        try {
                            $upstreamResponse = $HttpClient.Send($upstreamRequest)
                            $rawBytes = $upstreamResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                            $contentType = if ($upstreamResponse.Content.Headers.ContentType) { $upstreamResponse.Content.Headers.ContentType.ToString() } else { $null }
                            $forwardedHeaders = [Collections.Generic.List[object]]::new()
                            $excludedHeaders = Get-NetizenHopByHopHeaderNames $upstreamResponse.Headers
                            foreach ($name in @('Content-Length', 'Content-Type')) { $null = $excludedHeaders.Add($name) }
                            foreach ($headerCollection in @($upstreamResponse.Headers, $upstreamResponse.Content.Headers)) {
                                foreach ($pair in $headerCollection) {
                                    if ($excludedHeaders.Contains($pair.Key)) { continue }
                                    foreach ($value in $pair.Value) {
                                        $forwardedHeaders.Add([pscustomobject]@{ Name = $pair.Key; Value = $value })
                                    }
                                }
                            }
                            $responseAttempted = $true
                            Write-NetizenResponseBytes $response $rawBytes $contentType ([int]$upstreamResponse.StatusCode) $forwardedHeaders
                        } finally {
                            if ($null -ne $upstreamResponse) { $upstreamResponse.Dispose() }
                        }
                    } catch {
                        try { Write-Warning 'Upstream forwarding failed: upstream_forwarding_failed.' } catch {}
                        $responseAttempted = $true
                        Write-NetizenLocalFailure $response 502 'upstream_forwarding_failed'
                    } finally {
                        if ($null -ne $upstreamRequest) { $upstreamRequest.Dispose() }
                    }
                } catch {
                    try { Write-Warning 'Request worker failed: request_worker_failed.' } catch {}
                    if (-not $responseAttempted) {
                        try {
                            $responseAttempted = $true
                            Write-NetizenLocalFailure $response 500 'request_worker_failed'
                        } catch {}
                    }
                }
            } finally {
                try { $response.OutputStream.Close() } catch {}
            }
        }

        $job = Start-ThreadJob -InitializationScript $workerInitialization -ThrottleLimit $maxConcurrentRequests -ScriptBlock $requestHandler -ArgumentList @(
            $context, $indexBytes, $specBytes, $specRoute, $assetPayloads,
            $forwardingRegex, $runtimeSettings, $openApiRoutes, $httpClient
        )
        $requestJobs.Add($job)
    }
} finally {
    try { $listener.Stop() } catch { try { Write-Warning 'Listener shutdown failed: listener_stop_failed.' } catch {} }
    foreach ($job in @($requestJobs)) { $null = Complete-NetizenRequestJob $job }
    try { $httpClient.Dispose() } catch { try { Write-Warning 'HTTP client disposal failed: http_client_dispose_failed.' } catch {} }
    try { $listener.Close() } catch { try { Write-Warning 'Listener close failed: listener_close_failed.' } catch {} }
    Write-Host 'Stopped.'
}
