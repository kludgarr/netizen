#Requires -Version 7.0
<#
.SYNOPSIS
    Open a Netizen OpenAPI document in a local Swagger UI.
.DESCRIPTION
    The launcher serves Swagger UI on loopback and forwards "Try it out"
    requests to the upstream selected by the OpenAPI document, config.json, or
    the server controls rendered by Swagger UI.

    OpenAPI document resolution order:

    1. -Spec
    2. specPath from config.json (or -Config)
    3. exactly one adjacent *_openapi_v*.json document
    4. failure

    When the configuration file does not exist, it is created only after the
    OpenAPI document and its default upstream have been resolved successfully.
.PARAMETER Config
    Configuration file. Defaults to config.json beside this script. Relative
    paths inside it resolve from the configuration file's directory.
.PARAMETER Spec
    OpenAPI document. This takes precedence over config specPath and discovery.
    A relative path resolves from the current working directory.
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
$script:SwaggerUiVersion = '5.32.8'
$script:ServerSelectionHeader = 'X-Netizen-Upstream-Base'

function Resolve-NetizenPath {
    param([string]$BaseDirectory, [string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Assert-NetizenHeaderName {
    param([string]$Name, [string]$Source)

    if ([string]::IsNullOrEmpty($Name) -or $Name -notmatch '^[!#$%&''*+\-.^_`|~0-9A-Za-z]+$') {
        throw "$Source contains an invalid HTTP header name."
    }
}

function Assert-NetizenHeaderValue {
    param([AllowEmptyString()][string]$Value, [string]$Source)

    if ([regex]::IsMatch($Value, '[\x00-\x08\x0A-\x1F\x7F]')) {
        throw "$Source contains a prohibited HTTP control character."
    }
}

function Assert-NetizenContentType {
    param([string]$Value, [string]$Source)

    Assert-NetizenHeaderValue $Value $Source
    [Net.Http.Headers.MediaTypeHeaderValue]$parsed = $null
    if (-not [Net.Http.Headers.MediaTypeHeaderValue]::TryParse($Value, [ref]$parsed)) {
        throw "$Source is not a valid media type."
    }
}

function Get-NetizenHopByHopHeaderNames {
    param([object]$Headers)

    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(
        'Connection', 'Keep-Alive', 'Proxy-Authenticate', 'Proxy-Authorization',
        'TE', 'Trailer', 'Transfer-Encoding', 'Upgrade'
    )) {
        $null = $names.Add($name)
    }

    if ($null -ne $Headers) {
        $connectionValues = @()
        if ($Headers -is [Net.WebHeaderCollection]) {
            if ($null -ne $Headers['Connection']) {
                $connectionValues = @($Headers.GetValues('Connection'))
            }
        } else {
            [Collections.Generic.IEnumerable[string]]$values = $null
            if ($Headers.TryGetValues('Connection', [ref]$values)) {
                $connectionValues = @($values)
            }
        }

        foreach ($value in $connectionValues) {
            foreach ($token in ([string]$value).Split(',')) {
                $candidate = $token.Trim()
                if (-not [string]::IsNullOrEmpty($candidate)) {
                    $null = $names.Add($candidate)
                }
            }
        }
    }
    return ,$names
}

function Test-NetizenConfiguredRequestHeaders {
    param([object]$Headers)

    if ($null -eq $Headers) { return }
    $hopByHop = Get-NetizenHopByHopHeaderNames $null
    foreach ($header in $Headers.PSObject.Properties) {
        $name = [string]$header.Name
        if (
            $null -eq $header.Value -or
            $header.Value -is [Array] -or
            $header.Value -is [Collections.IDictionary] -or
            $header.Value -is [pscustomobject]
        ) {
            throw "Config upstream.requestHeaders.$name must be a scalar value."
        }
        $value = [string]$header.Value
        Assert-NetizenHeaderName $name "Config upstream.requestHeaders.$name"
        Assert-NetizenHeaderValue $value "Config upstream.requestHeaders.$name"
        if ([string]::Equals($name, 'Content-Type', [StringComparison]::OrdinalIgnoreCase)) {
            Assert-NetizenContentType $value 'Config upstream.requestHeaders.Content-Type'
        }

        if ([string]::Equals($name, $script:ServerSelectionHeader, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Config upstream.requestHeaders cannot set reserved header '$($script:ServerSelectionHeader)'."
        }
        if ($hopByHop.Contains($name)) {
            throw "Config upstream.requestHeaders cannot set hop-by-hop header '$name'."
        }
        if ($name -in @('Host', 'Content-Length')) {
            throw "Config upstream.requestHeaders cannot set transport-managed header '$name'."
        }
    }
}

function Install-NetizenSwaggerUiAssets {
    param([string]$CacheDirectory)

    $version = $script:SwaggerUiVersion
    $assetDirectory = Join-Path $CacheDirectory $version
    $required = [ordered]@{
        stylesheet = [pscustomobject]@{
            Name = 'swagger-ui.css'
            Route = '/assets/swagger-ui.css'
            ContentType = 'text/css; charset=utf-8'
        }
        bundle = [pscustomobject]@{
            Name = 'swagger-ui-bundle.js'
            Route = '/assets/swagger-ui-bundle.js'
            ContentType = 'application/javascript; charset=utf-8'
        }
        preset = [pscustomobject]@{
            Name = 'swagger-ui-standalone-preset.js'
            Route = '/assets/swagger-ui-standalone-preset.js'
            ContentType = 'application/javascript; charset=utf-8'
        }
    }

    $missing = @(
        $required.Values | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $assetDirectory $_.Name) -PathType Leaf)
        }
    )
    if ($missing.Count -eq 0) {
        return [pscustomobject]@{ Assets = $required; Directory = $assetDirectory }
    }

    New-Item -ItemType Directory -Force -Path $CacheDirectory, $assetDirectory | Out-Null
    $archivePath = Join-Path $CacheDirectory "swagger-ui-v$version.zip"
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        $releaseUrl = "https://api.github.com/repos/swagger-api/swagger-ui/releases/tags/v$version"
        $headers = @{ 'User-Agent' = [Microsoft.PowerShell.Commands.PSUserAgent]::Chrome }
        $temporaryPath = "$archivePath.download"
        try {
            $release = Invoke-RestMethod -Uri $releaseUrl -Headers $headers
            if ([string]::IsNullOrWhiteSpace([string]$release.zipball_url)) {
                throw "Swagger UI release v$version did not provide a source archive."
            }
            Write-Host "Downloading Swagger UI v$version..."
            Invoke-WebRequest -Uri $release.zipball_url -Headers $headers -OutFile $temporaryPath -UseBasicParsing | Out-Null
            Move-Item -LiteralPath $temporaryPath -Destination $archivePath
        } finally {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($asset in $required.Values) {
            $entries = @(
                $archive.Entries | Where-Object {
                    $_.FullName -ceq "dist/$($asset.Name)" -or
                    $_.FullName.EndsWith("/dist/$($asset.Name)", [StringComparison]::Ordinal)
                }
            )
            if ($entries.Count -ne 1) {
                throw "Swagger UI v$version archive must contain exactly one dist/$($asset.Name); found $($entries.Count)."
            }
            $destination = Join-Path $assetDirectory $asset.Name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $destination, $true)
        }
    } finally {
        $archive.Dispose()
    }

    return [pscustomobject]@{ Assets = $required; Directory = $assetDirectory }
}

function Convert-NetizenOpenApiPathToRegex {
    param([string]$Path)

    $options = [Text.RegularExpressions.RegexOptions]::Compiled -bor
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
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
    param([object]$Document, [object]$Value, [string]$Kind)

    $resolved = $Value
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($null -ne $resolved -and $null -ne $resolved.PSObject.Properties['$ref']) {
        $reference = [string]$resolved.'$ref'
        if (-not $reference.StartsWith('#/', [StringComparison]::Ordinal)) {
            throw "External OpenAPI $Kind reference is not supported by the local proxy: $reference"
        }
        if (-not $visited.Add($reference)) {
            throw "Cyclic OpenAPI $Kind reference is not supported by the local proxy: $reference"
        }

        $resolved = $Document
        foreach ($token in $reference.Substring(2).Split('/')) {
            $name = $token.Replace('~1', '/').Replace('~0', '~')
            $property = $resolved.PSObject.Properties[$name]
            if ($null -eq $property) {
                throw "OpenAPI $Kind reference did not resolve: $reference"
            }
            $resolved = $property.Value
        }
    }
    return $resolved
}

function Convert-NetizenServerToBaseRegex {
    param([object]$Server)

    $template = [string]$Server.url
    if ([string]::IsNullOrWhiteSpace($template)) {
        throw 'An effective OpenAPI Server Object has no URL.'
    }
    $template = $template.TrimEnd('/')

    $pattern = [Text.StringBuilder]::new('^')
    $offset = 0
    foreach ($match in [regex]::Matches($template, '\{(?<name>[^}]+)\}')) {
        $null = $pattern.Append([regex]::Escape($template.Substring($offset, $match.Index - $offset)))
        $variableName = $match.Groups['name'].Value
        $variableProperty = if ($null -ne $Server.variables) {
            $Server.variables.PSObject.Properties[$variableName]
        } else {
            $null
        }
        if ($null -eq $variableProperty) {
            throw "OpenAPI server URL references undeclared variable '$variableName'."
        }

        $enumProperty = $variableProperty.Value.PSObject.Properties['enum']
        $allowedValues = if ($null -ne $enumProperty) { @($enumProperty.Value) } else { @() }
        if ($allowedValues.Count -gt 0) {
            $alternatives = @($allowedValues | ForEach-Object { [regex]::Escape([string]$_) })
            $null = $pattern.Append('(?:' + ($alternatives -join '|') + ')')
        } else {
            # An unconstrained Server Variable may occupy more than one path
            # segment; query and fragment delimiters are never part of a base.
            $null = $pattern.Append('[^?#]+?')
        }
        $offset = $match.Index + $match.Length
    }
    $null = $pattern.Append([regex]::Escape($template.Substring($offset)))
    $null = $pattern.Append('/?$')

    $options = [Text.RegularExpressions.RegexOptions]::Compiled -bor
        [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    return [regex]::new($pattern.ToString(), $options)
}

function Get-NetizenOpenApiRoutes {
    param([object]$Document, [string]$ConfiguredBaseUrl)

    $methods = @('get', 'post', 'put', 'patch', 'delete', 'head', 'options', 'trace')
    $rootServers = @($Document.servers)
    $routes = foreach ($pathProperty in $Document.paths.PSObject.Properties) {
        $pathItem = Resolve-NetizenOpenApiReference $Document $pathProperty.Value 'Path Item'
        $pathServersProperty = $pathItem.PSObject.Properties['servers']
        $pathServers = if ($null -ne $pathServersProperty) { @($pathServersProperty.Value) } else { $rootServers }
        foreach ($method in $methods) {
            if ($null -ne $pathItem.PSObject.Properties[$method]) {
                $operation = $pathItem.$method
                $operationServersProperty = $operation.PSObject.Properties['servers']
                $effectiveServers = if ($null -ne $operationServersProperty) {
                    @($operationServersProperty.Value)
                } else {
                    $pathServers
                }
                $allowedBasePatterns = [Collections.Generic.List[regex]]::new()
                if (-not [string]::IsNullOrWhiteSpace($ConfiguredBaseUrl)) {
                    $options = [Text.RegularExpressions.RegexOptions]::Compiled -bor
                        [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
                        [Text.RegularExpressions.RegexOptions]::IgnoreCase
                    $allowedBasePatterns.Add([regex]::new(
                        '^' + [regex]::Escape($ConfiguredBaseUrl.TrimEnd('/')) + '/?$',
                        $options
                    ))
                }
                foreach ($server in $effectiveServers) {
                    $allowedBasePatterns.Add((Convert-NetizenServerToBaseRegex $server))
                }
                [pscustomobject]@{
                    Method = $method.ToUpperInvariant()
                    Template = $pathProperty.Name
                    Regex = Convert-NetizenOpenApiPathToRegex $pathProperty.Name
                    IsTemplated = $pathProperty.Name.Contains('{', [StringComparison]::Ordinal)
                    AllowedBasePatterns = @($allowedBasePatterns)
                }
            }
        }
    }
    return @($routes)
}

function Expand-NetizenOpenApiServerUrl {
    param([object]$Server)

    $url = [string]$Server.url
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw 'The first root OpenAPI Server Object has no URL.'
    }

    if ($null -ne $Server.variables) {
        foreach ($variable in $Server.variables.PSObject.Properties) {
            $defaultProperty = $variable.Value.PSObject.Properties['default']
            if ($null -eq $defaultProperty) {
                throw "OpenAPI server variable '$($variable.Name)' has no default value."
            }
            $url = $url.Replace(
                "{$($variable.Name)}",
                [string]$defaultProperty.Value,
                [StringComparison]::Ordinal
            )
        }
    }

    if ([regex]::IsMatch($url, '\{[^}]+\}')) {
        throw "The first root OpenAPI server URL contains an unresolved variable: '$url'."
    }
    return $url
}

function ConvertTo-NetizenAbsoluteBaseUrl {
    param([string]$Value, [string]$Source)

    [uri]$uri = $null
    if (
        -not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https') -or
        [string]::IsNullOrWhiteSpace($uri.Host)
    ) {
        throw "$Source must resolve to an absolute HTTP or HTTPS URL: '$Value'."
    }
    if (-not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "$Source must not contain a query or fragment: '$Value'."
    }
    if (-not [string]::IsNullOrEmpty($uri.UserInfo)) {
        throw "$Source must not contain user information: '$Value'."
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Resolve-NetizenDefaultBaseUrl {
    param([object]$Document, [object]$Upstream)

    $configured = if ($null -ne $Upstream) { [string]$Upstream.baseUrl } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return ConvertTo-NetizenAbsoluteBaseUrl $configured 'Config upstream.baseUrl'
    }

    $servers = @($Document.servers)
    if ($servers.Count -eq 0) {
        throw 'Config upstream.baseUrl is empty and the OpenAPI document declares no root servers.'
    }
    $expanded = Expand-NetizenOpenApiServerUrl $servers[0]
    return ConvertTo-NetizenAbsoluteBaseUrl $expanded 'The first root OpenAPI server'
}

function New-NetizenSwaggerSpecJson {
    param([string]$SourceJson, [string]$ConfiguredBaseUrl)

    if ([string]::IsNullOrWhiteSpace($ConfiguredBaseUrl)) { return $SourceJson }

    # JsonDocument/Utf8JsonWriter are available on PowerShell 7.0's .NET Core
    # runtime and preserve every untouched JSON token exactly by type. This
    # avoids ConvertFrom-Json retyping timestamp-looking example strings.
    $readOnlyDocument = $SourceJson | ConvertFrom-Json -Depth 100
    $matchingServerIndex = -1
    $serverIndex = 0
    foreach ($server in @($readOnlyDocument.servers)) {
        if (
            $matchingServerIndex -lt 0 -and
            [string]::Equals([string]$server.url, $ConfiguredBaseUrl, [StringComparison]::OrdinalIgnoreCase)
        ) {
            $matchingServerIndex = $serverIndex
        }
        $serverIndex++
    }

    $jsonDocument = [Text.Json.JsonDocument]::Parse($SourceJson)
    try {
        if ($jsonDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'The OpenAPI document root must be a JSON object.'
        }

        $stream = [IO.MemoryStream]::new()
        $writerOptions = [Text.Json.JsonWriterOptions]::new()
        $writerOptions.Indented = $true
        $writer = [Text.Json.Utf8JsonWriter]::new($stream, $writerOptions)
        try {
            $writer.WriteStartObject()
            $wroteServers = $false
            foreach ($property in $jsonDocument.RootElement.EnumerateObject()) {
                if ($property.Name -cne 'servers') {
                    $property.WriteTo($writer)
                    continue
                }
                if ($property.Value.ValueKind -ne [Text.Json.JsonValueKind]::Array) {
                    throw "OpenAPI document property 'servers' must be an array."
                }

                $wroteServers = $true
                $writer.WritePropertyName('servers')
                $writer.WriteStartArray()
                if ($matchingServerIndex -ge 0) {
                    $index = 0
                    foreach ($serverElement in $property.Value.EnumerateArray()) {
                        if ($index -eq $matchingServerIndex) { $serverElement.WriteTo($writer) }
                        $index++
                    }
                } else {
                    $writer.WriteStartObject()
                    $writer.WriteString('url', $ConfiguredBaseUrl)
                    $writer.WriteEndObject()
                }

                $index = 0
                foreach ($serverElement in $property.Value.EnumerateArray()) {
                    if ($index -ne $matchingServerIndex) { $serverElement.WriteTo($writer) }
                    $index++
                }
                $writer.WriteEndArray()
            }

            if (-not $wroteServers) {
                $writer.WritePropertyName('servers')
                $writer.WriteStartArray()
                $writer.WriteStartObject()
                $writer.WriteString('url', $ConfiguredBaseUrl)
                $writer.WriteEndObject()
                $writer.WriteEndArray()
            }
            $writer.WriteEndObject()
            $writer.Flush()
            return $script:Utf8.GetString($stream.ToArray())
        } finally {
            $writer.Dispose()
            $stream.Dispose()
        }
    } finally {
        $jsonDocument.Dispose()
    }
}

function ConvertTo-NetizenRuntimeJson {
    param([object]$Value)

    return $Value | ConvertTo-Json -Depth 6 -Compress -EscapeHandling EscapeHtml
}

function New-NetizenSwaggerHtml {
    param([string]$Title, [string]$RuntimeJson)

    $encodedTitle = [Net.WebUtility]::HtmlEncode($Title)
    return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$encodedTitle</title>
  <link rel="stylesheet" href="/assets/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="/assets/swagger-ui-bundle.js"></script>
<script src="/assets/swagger-ui-standalone-preset.js"></script>
<script>
const NETIZEN=$RuntimeJson;
const ROUTES=NETIZEN.routes.map(route=>({...route,matcher:new RegExp(route.suffixPattern)}));
function requestInterceptor(req){
  const target=new URL(req.url,window.location.origin);
  if(target.origin===window.location.origin&&NETIZEN.localRoutes.includes(target.pathname))return req;
  if(target.origin===window.location.origin&&(target.pathname===NETIZEN.proxyRoute||target.pathname.startsWith(NETIZEN.proxyRoute+'/')))return req;
  const method=(req.method||'GET').toUpperCase();
  let selected=null;
  for(const route of ROUTES){
    if(route.method!==method)continue;
    const match=route.matcher.exec(target.pathname);
    if(match){selected={route,match};break;}
  }
  if(!selected)throw new Error('Swagger request did not match a declared OpenAPI operation.');
  const selectedBase=target.origin+target.pathname.slice(0,selected.match.index);
  req.headers=Object.assign({},req.headers||{},{[NETIZEN.serverSelectionHeader]:selectedBase});
  req.url=window.location.origin+NETIZEN.proxyRoute+selected.match[0]+target.search;
  return req;
}
SwaggerUIBundle({
  url:NETIZEN.specRoute,
  dom_id:'#swagger-ui',
  presets:[SwaggerUIBundle.presets.apis,SwaggerUIStandalonePreset],
  layout:'StandaloneLayout',
  tryItOutEnabled:true,
  validatorUrl:null,
  requestInterceptor
});
</script>
</body>
</html>
"@
}

function Find-NetizenOpenApiRoute {
    param([object[]]$Routes, [string]$Method, [string]$Path)

    $pathMatches = @($Routes | Where-Object { $_.Regex.IsMatch($Path) })
    $route = $pathMatches |
        Where-Object { $_.Method -eq $Method } |
        Sort-Object IsTemplated |
        Select-Object -First 1
    return [pscustomobject]@{
        Route = $route
        PathMatched = $pathMatches.Count -gt 0
    }
}

function Resolve-NetizenRequestBaseUrl {
    param([Net.WebHeaderCollection]$Headers, [string]$DefaultBaseUrl, [object]$Route)

    $rawValues = $Headers.GetValues($script:ServerSelectionHeader)
    $candidate = if ($null -eq $rawValues) {
        $DefaultBaseUrl
    } else {
        $values = @($rawValues)
        if ($values.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$values[0])) {
            throw "Header '$($script:ServerSelectionHeader)' must contain exactly one value."
        }
        $rawSelected = [string]$values[0]
        Assert-NetizenHeaderValue $rawSelected "Header '$($script:ServerSelectionHeader)'"
        $rawSelected.Trim()
    }

    $resolved = ConvertTo-NetizenAbsoluteBaseUrl $candidate 'Selected upstream base URL'
    $allowed = @($Route.AllowedBasePatterns | Where-Object { $_.IsMatch($resolved) }).Count -gt 0
    if (-not $allowed) {
        throw 'Selected upstream base URL is not declared by config or the effective OpenAPI Server Objects.'
    }
    return $resolved
}

function Write-NetizenResponseBytes {
    param(
        [Net.HttpListenerResponse]$Response,
        [byte[]]$Bytes,
        [string]$ContentType,
        [int]$StatusCode = 200,
        [object[]]$Headers = @()
    )

    if ($StatusCode -lt 100 -or $StatusCode -gt 599) {
        throw "Invalid HTTP response status code: $StatusCode"
    }
    if (-not [string]::IsNullOrEmpty($ContentType)) {
        Assert-NetizenContentType $ContentType 'Response Content-Type'
    }

    $validatedHeaders = @($Headers)
    foreach ($header in $validatedHeaders) {
        Assert-NetizenHeaderName ([string]$header.Name) 'Response header'
        Assert-NetizenHeaderValue ([string]$header.Value) "Response header '$($header.Name)'"
    }

    $Response.StatusCode = $StatusCode
    if (-not [string]::IsNullOrEmpty($ContentType)) {
        $Response.ContentType = $ContentType
    }
    foreach ($header in $validatedHeaders) {
        $Response.AppendHeader([string]$header.Name, [string]$header.Value)
    }
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Write-NetizenFailure {
    param([Net.HttpListenerResponse]$Response, [int]$StatusCode, [string]$Code)

    $bytes = $script:Utf8.GetBytes((@{ error = $Code } | ConvertTo-Json -Compress))
    Write-NetizenResponseBytes $Response $bytes 'application/json; charset=utf-8' $StatusCode
}

if ($Port -lt 1 -or $Port -gt 65525) {
    throw '-Port must be between 1 and 65525.'
}

$configWasExplicit = $PSBoundParameters.ContainsKey('Config')
if ($configWasExplicit -and [string]::IsNullOrWhiteSpace($Config)) {
    throw '-Config must name a configuration file when supplied.'
}
$specWasExplicit = $PSBoundParameters.ContainsKey('Spec')
if ($specWasExplicit -and [string]::IsNullOrWhiteSpace($Spec)) {
    throw '-Spec must name an OpenAPI document when supplied.'
}

$configPath = if ($configWasExplicit) {
    Resolve-NetizenPath ([string](Get-Location).Path) $Config
} else {
    Join-Path $PSScriptRoot 'config.json'
}
$configDirectory = Split-Path -Parent $configPath
if (-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
    throw "Configuration directory not found: $configDirectory"
}

$configExists = Test-Path -LiteralPath $configPath -PathType Leaf
$settings = if ($configExists) {
    Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 100
} else {
    [pscustomobject][ordered]@{
        specPath = $null
        upstream = [pscustomobject][ordered]@{
            baseUrl = $null
            requestHeaders = [pscustomobject]@{}
        }
    }
}
if ($null -eq $settings.upstream) {
    $settings | Add-Member -NotePropertyName upstream -NotePropertyValue ([pscustomobject][ordered]@{
        baseUrl = $null
        requestHeaders = [pscustomobject]@{}
    }) -Force
}
if ($null -eq $settings.upstream.requestHeaders) {
    $settings.upstream | Add-Member -NotePropertyName requestHeaders -NotePropertyValue ([pscustomobject]@{}) -Force
}
Test-NetizenConfiguredRequestHeaders $settings.upstream.requestHeaders

$specPath = if ($specWasExplicit) {
    Resolve-NetizenPath ([string](Get-Location).Path) $Spec
} elseif (-not [string]::IsNullOrWhiteSpace([string]$settings.specPath)) {
    Resolve-NetizenPath $configDirectory ([string]$settings.specPath)
} else {
    $discovered = @(
        Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.json' |
            Where-Object { $_.Name -match '(?i)_openapi_v\d+(?:\.\d+)+\.json$' } |
            Sort-Object Name
    )
    if ($discovered.Count -eq 0) {
        throw 'No OpenAPI document was selected: use -Spec, set config specPath, or place exactly one versioned OpenAPI JSON file beside serve.ps1.'
    }
    if ($discovered.Count -gt 1) {
        throw "Multiple adjacent OpenAPI documents were found ($($discovered.Name -join ', ')): use -Spec or config specPath."
    }
    $discovered[0].FullName
}
if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) {
    throw "OpenAPI document not found: $specPath"
}

$sourceSpecJson = Get-Content -LiteralPath $specPath -Raw
$document = $sourceSpecJson | ConvertFrom-Json -Depth 100
foreach ($requiredProperty in @('openapi', 'info', 'paths')) {
    if ($null -eq $document.PSObject.Properties[$requiredProperty]) {
        throw "OpenAPI document property '$requiredProperty' is required."
    }
}
if ($null -eq $document.info.PSObject.Properties['title'] -or [string]::IsNullOrWhiteSpace([string]$document.info.title)) {
    throw "OpenAPI document property 'info.title' is required."
}

$defaultBaseUrl = Resolve-NetizenDefaultBaseUrl $document $settings.upstream
$configuredBaseUrl = [string]$settings.upstream.baseUrl
$swaggerSpecJson = if ([string]::IsNullOrWhiteSpace($configuredBaseUrl)) {
    $sourceSpecJson
} else {
    New-NetizenSwaggerSpecJson $sourceSpecJson $defaultBaseUrl
}
$routes = Get-NetizenOpenApiRoutes $document $(
    if ([string]::IsNullOrWhiteSpace($configuredBaseUrl)) { $null } else { $defaultBaseUrl }
)
if ($routes.Count -eq 0) {
    throw 'The OpenAPI document declares no supported HTTP operations.'
}

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

$assets = Install-NetizenSwaggerUiAssets (Join-Path $PSScriptRoot '.swagger-ui')
$assetPayloads = @{}
$assetRoutes = @()
foreach ($entry in $assets.Assets.GetEnumerator()) {
    $asset = $entry.Value
    $assetRoutes += $asset.Route
    $assetPayloads[$asset.Route] = [pscustomobject]@{
        Path = Join-Path $assets.Directory $asset.Name
        ContentType = $asset.ContentType
    }
}

$specRoute = '/openapi.json'
$proxyRoute = '/api'
$routeDescriptors = @(
    $routes |
        Sort-Object IsTemplated, @{ Expression = { $_.Template.Length }; Descending = $true } |
        ForEach-Object {
            [ordered]@{
                method = $_.Method
                suffixPattern = Convert-NetizenOpenApiPathToSuffixRegexSource $_.Template
            }
        }
)
$runtimeJson = ConvertTo-NetizenRuntimeJson ([ordered]@{
    specRoute = $specRoute
    proxyRoute = $proxyRoute
    localRoutes = @($specRoute) + $assetRoutes
    serverSelectionHeader = $script:ServerSelectionHeader
    routes = $routeDescriptors
})
$indexBytes = $script:Utf8.GetBytes((New-NetizenSwaggerHtml ([string]$document.info.title) $runtimeJson))
$specBytes = $script:Utf8.GetBytes($swaggerSpecJson)

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
$httpClient = [Net.Http.HttpClient]::new($handler)
$browserUrl = "http://127.0.0.1:$boundPort/"

Write-Host "Serving configuration: $configPath"
Write-Host "Serving OpenAPI document: $specPath"
Write-Host "Default upstream: $defaultBaseUrl"
Write-Host "Loaded OpenAPI operations: $($routes.Count)"
Write-Host "Open: $browserUrl"
if ($KeepAlive) {
    Write-Host 'KeepAlive enabled - Ctrl+C to stop.'
} else {
    Write-Host 'Auto-stops after 120 seconds of inactivity following the initial page load.'
}
try {
    Start-Process $browserUrl | Out-Null
} catch {
    Write-Warning "Could not open the browser automatically. Open $browserUrl manually."
}

$lastRequest = [DateTime]::UtcNow
$initialLoad = $false
$idleTimeout = [TimeSpan]::FromSeconds(120)
$pendingContext = $null

try {
    :listenerLoop while ($listener.IsListening) {
        if ($null -eq $pendingContext) {
            $pendingContext = $listener.GetContextAsync()
        }

        while (-not $pendingContext.Wait(500)) {
            if ($initialLoad -and -not $KeepAlive -and ([DateTime]::UtcNow - $lastRequest) -ge $idleTimeout) {
                Write-Host 'No activity for 120 seconds - shutting down.'
                break listenerLoop
            }
        }

        $completedTask = $pendingContext
        $pendingContext = $null
        try {
            $context = $completedTask.GetAwaiter().GetResult()
        } finally {
            $completedTask.Dispose()
        }

        $request = $context.Request
        $response = $context.Response
        $path = $request.Url.AbsolutePath
        $lastRequest = [DateTime]::UtcNow
        if ([string]::Equals($path, '/', [StringComparison]::Ordinal)) {
            $initialLoad = $true
        }
        $responseAttempted = $false

        try {
            if ([string]::Equals($path, '/', [StringComparison]::Ordinal)) {
                $responseAttempted = $true
                Write-NetizenResponseBytes $response $indexBytes 'text/html; charset=utf-8'
                continue
            }
            if ([string]::Equals($path, $specRoute, [StringComparison]::Ordinal)) {
                $responseAttempted = $true
                Write-NetizenResponseBytes $response $specBytes 'application/json; charset=utf-8'
                continue
            }
            if ($assetPayloads.ContainsKey($path)) {
                $asset = $assetPayloads[$path]
                $assetBytes = [IO.File]::ReadAllBytes($asset.Path)
                $responseAttempted = $true
                Write-NetizenResponseBytes $response $assetBytes $asset.ContentType
                continue
            }

            $apiPath = $null
            if ([string]::Equals($path, $proxyRoute, [StringComparison]::Ordinal)) {
                $apiPath = '/'
            } elseif ($path.StartsWith("$proxyRoute/", [StringComparison]::Ordinal)) {
                $apiPath = $path.Substring($proxyRoute.Length)
            }
            if ($null -eq $apiPath) {
                $responseAttempted = $true
                Write-NetizenFailure $response 404 'route_not_found'
                continue
            }

            $routeMatch = Find-NetizenOpenApiRoute $routes $request.HttpMethod $apiPath
            if ($null -eq $routeMatch.Route) {
                $responseAttempted = $true
                if ($routeMatch.PathMatched) {
                    Write-NetizenFailure $response 405 'method_not_allowed'
                } else {
                    Write-NetizenFailure $response 404 'openapi_route_not_found'
                }
                continue
            }

            try {
                $requestBaseUrl = Resolve-NetizenRequestBaseUrl $request.Headers $defaultBaseUrl $routeMatch.Route
            } catch {
                $responseAttempted = $true
                Write-NetizenFailure $response 400 'invalid_upstream_base'
                continue
            }

            $upstreamRequest = $null
            try {
                $target = [uri]($requestBaseUrl.TrimEnd('/') + $apiPath + $request.Url.Query)
                $upstreamRequest = [Net.Http.HttpRequestMessage]::new(
                    [Net.Http.HttpMethod]::new($request.HttpMethod),
                    $target
                )
                $contentHeaders = [Collections.Generic.List[object]]::new()
                $requestHopByHop = Get-NetizenHopByHopHeaderNames $request.Headers

                foreach ($name in $request.Headers.AllKeys) {
                    if ($name -in @(
                        'Host', 'Content-Length', 'Accept-Encoding', 'Content-Type',
                        $script:ServerSelectionHeader
                    ) -or $requestHopByHop.Contains($name)) {
                        continue
                    }
                    $values = @($request.Headers.GetValues($name))
                    Assert-NetizenHeaderName $name "Request header '$name'"
                    foreach ($value in $values) {
                        Assert-NetizenHeaderValue ([string]$value) "Request header '$name'"
                    }
                    if (-not $upstreamRequest.Headers.TryAddWithoutValidation($name, [string[]]$values)) {
                        $contentHeaders.Add([pscustomobject]@{ Name = $name; Values = [string[]]$values })
                    }
                }

                $configuredContentType = $null
                foreach ($header in $settings.upstream.requestHeaders.PSObject.Properties) {
                    $name = [string]$header.Name
                    $value = [string]$header.Value
                    $null = $upstreamRequest.Headers.Remove($name)
                    for ($index = $contentHeaders.Count - 1; $index -ge 0; $index--) {
                        if ([string]::Equals($contentHeaders[$index].Name, $name, [StringComparison]::OrdinalIgnoreCase)) {
                            $contentHeaders.RemoveAt($index)
                        }
                    }

                    if ([string]::Equals($name, 'Content-Type', [StringComparison]::OrdinalIgnoreCase)) {
                        $configuredContentType = $value
                    } elseif (-not $upstreamRequest.Headers.TryAddWithoutValidation($name, $value)) {
                        $contentHeaders.Add([pscustomobject]@{ Name = $name; Values = [string[]]@($value) })
                    }
                }

                $requestContentType = if (-not [string]::IsNullOrEmpty($configuredContentType)) {
                    $configuredContentType
                } else {
                    [string]$request.ContentType
                }
                $hasContentMetadata = -not [string]::IsNullOrEmpty($requestContentType) -or $contentHeaders.Count -gt 0
                if ($request.HasEntityBody -or $hasContentMetadata) {
                    $requestBytes = [byte[]]@()
                    if ($request.HasEntityBody) {
                        $memory = [IO.MemoryStream]::new()
                        try {
                            $request.InputStream.CopyTo($memory)
                            $requestBytes = $memory.ToArray()
                        } finally {
                            $memory.Dispose()
                        }
                    }
                    $upstreamRequest.Content = [Net.Http.ByteArrayContent]::new($requestBytes)
                    if (-not [string]::IsNullOrEmpty($requestContentType)) {
                        Assert-NetizenContentType $requestContentType 'Request Content-Type'
                        if (-not $upstreamRequest.Content.Headers.TryAddWithoutValidation('Content-Type', $requestContentType)) {
                            throw 'Request Content-Type could not be forwarded.'
                        }
                    }
                    foreach ($header in $contentHeaders) {
                        if (-not $upstreamRequest.Content.Headers.TryAddWithoutValidation($header.Name, $header.Values)) {
                            throw "Request content header '$($header.Name)' could not be forwarded."
                        }
                    }
                }

                $upstreamResponse = $null
                try {
                    $upstreamResponse = $httpClient.SendAsync($upstreamRequest).GetAwaiter().GetResult()
                    $responseBytes = $upstreamResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()

                    [Collections.Generic.IEnumerable[string]]$contentTypeValues = $null
                    $contentType = $null
                    if ($upstreamResponse.Content.Headers.TryGetValues('Content-Type', [ref]$contentTypeValues)) {
                        $contentTypes = @($contentTypeValues)
                        if ($contentTypes.Count -ne 1) {
                            throw 'Upstream response contained multiple Content-Type values.'
                        }
                        $contentType = [string]$contentTypes[0]
                        Assert-NetizenContentType $contentType 'Upstream response Content-Type'
                    }

                    $forwardedHeaders = [Collections.Generic.List[object]]::new()
                    $excludedHeaders = Get-NetizenHopByHopHeaderNames $upstreamResponse.Headers
                    foreach ($name in @('Content-Length', 'Content-Type')) {
                        $null = $excludedHeaders.Add($name)
                    }
                    foreach ($collection in @($upstreamResponse.Headers, $upstreamResponse.Content.Headers)) {
                        foreach ($pair in $collection) {
                            if ($excludedHeaders.Contains($pair.Key)) { continue }
                            Assert-NetizenHeaderName ([string]$pair.Key) 'Upstream response header'
                            foreach ($value in $pair.Value) {
                                Assert-NetizenHeaderValue ([string]$value) "Upstream response header '$($pair.Key)'"
                                $forwardedHeaders.Add([pscustomobject]@{
                                    Name = [string]$pair.Key
                                    Value = [string]$value
                                })
                            }
                        }
                    }

                    $responseAttempted = $true
                    $responseParameters = @{
                        Response = $response
                        Bytes = $responseBytes
                        ContentType = $contentType
                        StatusCode = [int]$upstreamResponse.StatusCode
                        Headers = @($forwardedHeaders)
                    }
                    Write-NetizenResponseBytes @responseParameters
                } finally {
                    if ($null -ne $upstreamResponse) { $upstreamResponse.Dispose() }
                }
            } catch {
                Write-Warning "Upstream request failed: $($_.Exception.Message)"
                if (-not $responseAttempted) {
                    $responseAttempted = $true
                    Write-NetizenFailure $response 502 'upstream_request_failed'
                }
            } finally {
                if ($null -ne $upstreamRequest) { $upstreamRequest.Dispose() }
            }
        } catch {
            Write-Warning "Local request failed: $($_.Exception.Message)"
            if (-not $responseAttempted) {
                try {
                    $responseAttempted = $true
                    Write-NetizenFailure $response 500 'local_request_failed'
                } catch {}
            }
        } finally {
            try { $response.OutputStream.Close() } catch {}
        }
    }
} finally {
    try { $listener.Stop() } catch {}
    try { $httpClient.Dispose() } catch {}
    try { $listener.Close() } catch {}
    Write-Host 'Stopped.'
}
