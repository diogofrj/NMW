#description: Installs Sophos Server Protection Endpoint agent and registers with Sophos Central.
#execution mode: IndividualWithRestart
#tags: Nerdio, Sophos
<#
Notes:
IMPORTANT: Refer to the Sophos Integration Article for instructions on how to use this script!
https://nmw.zendesk.com/hc/en-us/articles/1500004124602

This script installs Sophos Server Protection Endpoint software components. 
#>

# Start logging
$SaveVerbosePreference = $VerbosePreference
$VerbosePreference = 'continue'
$VMTime = Get-Date
$LogTime = $VMTime.ToUniversalTime()
mkdir "C:\Windows\temp\NMWLogs\ScriptedActions\sophosinstall" -Force
Start-Transcript -Path "C:\windows\temp\NMWLogs\ScriptedActions\sophosinstall\ps_log.txt" -Append
Write-Host "################# New Script Run #################"
Write-host "Current time (UTC-0): $LogTime"
  
# Pass in secure variables from NMW
$auth   = $SecureVars.sophosauth
$apikey = $SecureVars.sophosapikey

# Error out if required secure variables are not passed
if(!$auth -or !$apikey){
    Write-Error "ERROR: Required variables sophosauth and/or sophosapikey are not being passed from NMW. Please add these secure variables" -ErrorAction Stop
}

$locationsApi = "https://api1.central.sophos.com/gateway/migration-tool/v1/deployment/agent/locations"

# Determines how PowerShell responds to a non-terminating error. Stop will make the script stop execution in case of an error.
# Please refer to the Microsoft PowerShell documentation for more details.
$ErrorActionPreference = "Stop"

function Get-DateTime {
    return "[{0:yyyy/MM/dd} {0:HH:mm:ss}]" -f (Get-Date)
}

function Log {
    [CmdletBinding()]
    Param(
        [Parameter(Position=0, Mandatory=$true)] [string]$data,
        [Parameter(Position=1, Mandatory=$false)] [bool]$error = 0
    )

    Add-Content -Value "$(Get-DateTime) $data" -Path $logFile
    if ($error) {
        Write-host "$(Get-DateTime) $data" -ForegroundColor Red
    } else {
        Write-host "$(Get-DateTime) $data"
    }
}

function Run-CommandWithRetry {
    [CmdletBinding()]
    Param(
        [Parameter(Position=0, Mandatory=$true)] $command,
        [Parameter(Position=1, Mandatory=$false)] [int]$delayInSecs = 5,
        [Parameter(Position=2, Mandatory=$false)] [int]$maxRetries = 2
    )

    $retryCount = 0
    $success = $false
    $cmdString = $command.ToString()
    do {
        try {
            $result = & $command
            $success = $true
            return $result
        } catch {
            $retryCount = $retryCount + 1
            if ($retryCount -gt $maxRetries) {
                throw $_.Exception
            } else {
                Log "Failed to execute [$cmdString] - $($_.Exception.Message)" -error 1
                Log "Retrying in $delayInSecs seconds... ($retryCount/$maxRetries)"
                Start-Sleep -s $delayInSecs
            }
        }
    } while (!($success));
}

function Is-OSVersionSupported {
    $osCaption = (gwmi win32_operatingsystem).caption
    $osVersion = (gwmi win32_operatingsystem).version
    Log "Running on $osCaption ($osVersion)"

    # getting major and minor version numbers from version string, e.g. 6.2.123
    $major = [int]$osVersion.split("\.")[0];
    $minor = [int]$osVersion.split("\.")[1];
    # OS caption must match the naming for server and also checking for supported major/minor version numbers
    return $osCaption -match "Microsoft Windows Server" -and ($major -gt 6 -or ($major -eq 6 -and $minor -gt 1))
}

function Get-InstallerLink {
    [CmdletBinding()]
    Param([Parameter(Position=0, Mandatory=$true)] [string]$installerType)

    Log "Getting location of the $installerType from $locationsApi"
    $hdrs = @{}
    $hdrs.Add("x-api-key", $apikey)
    $hdrs.Add("Authorization", "Basic $auth")
    $response = Invoke-RestMethod -Method 'Get' -Uri $locationsApi -Headers $hdrs
    # convert the response object (json) to the PowerShell's friendly json
    $json = $response | ConvertTo-Json
    # convert the PowerShell json into an object so we can access its properties directly for searching/filtering purposes
    $x = $json | ConvertFrom-Json
    # filter by given installer type
    $installer = $x.installerInfo | where { $_.platform -eq $installerType }
    $installerUrl = $installer.url
    [regex]$linkRegex = '^https:\/\/.+\.sophos.com\/api\/download\/.*\.exe$'
    if (!($linkRegex.Matches($installerUrl).Success)) {
        throw "Invalid format of the installer location: $installerUrl"
    }
    return $installerUrl
}

function Download-Installer {
    [CmdletBinding()]
    Param(
        [Parameter(Position=0, Mandatory=$true)] [string]$url,
        [Parameter(Position=1, Mandatory=$true)] [string]$destination
    )

    Log "Downloading installer from $url"
    [Net.ServicePointManager]::SecurityProtocol = 
    [Net.SecurityProtocolType]::Tls12
    $WebClient = New-Object System.Net.WebClient
    $WebClient.DownloadFile($url, $destination)

    if (!(Test-Path $destination)) {
        throw "Download has finished but something went wrong - cannot find the installer in $destination"
    }

    Log "Installer has been downloaded to $destination"
}

$tempDir = $env:TEMP
if (!(Test-Path $tempDir)) {
    Write-Host "$(Get-DateTime) $tempDir folder does not exist." -ForegroundColor Red
    return
}

$logFile = "C:\windows\temp\NMWLogs\ScriptedActions\sophosinstall\logfile.log"
try {
    # first attempt to log to a file, if does not exist file will be created otherwise it will append to an existing log file
    Log "Script processing has started, logging to $logFile"
} catch {
    Write-Host "$(Get-DateTime) Unable to write to a log file $logFile" -ForegroundColor Red
    Write-Host "$(Get-DateTime) Exception Message: $($_.Exception.Message)" -ForegroundColor Red
    return
}

if (!($SecureVars.sophosapikey) -or !($auth)) {
    Log "Invalid values for one or more script arguments: 'apiKey', 'auth'" -error 1
    return
}

if (!(Is-OSVersionSupported)) {
    Log "OS version is not supported." -error 1
    # script could return here but decided to carry on with the execution
}

try {
    $installerUrl = Run-CommandWithRetry { Get-InstallerLink -installerType "Windows Thin Installer" }
    $installerUrl = $installerUrl | Out-String
} catch {
    Log "Error on getting link to the installer - $($_.Exception.Message)" -error 1
    return
}

Write-Host "Running InstallerURL Variable: $InstallerURL"
$downloadLocation = "$tempDir\SophosSetup.exe"
try {
    Run-CommandWithRetry { Download-Installer -url $installerUrl -destination $downloadLocation }
} catch {
    Log "Error on downloading the installer - $($_.Exception.Message)" -error 1
    return
}
Log "Running installer $downloadLocation"
try {
    $result = Start-Process -FilePath "$downloadLocation" -PassThru -Wait -ArgumentList '--products=all --quiet'
    $exitCode = $result.ExitCode
    if ($exitCode -eq 0) {
        Log "Sophos Server Protection has been installed."
    } else {
        Log "Installation has not completed: $exitCode" -error 1
    }
} catch {
    Log "Error on installing Sophos Server Protection - $($_.Exception.Message)" -error 1
}

# End Logging
Stop-Transcript
$VerbosePreference=$SaveVerbosePreference

# LEGAL: 'Sophos' and 'Sophos Anti-Virus' are registered trademarks of Sophos Limited and Sophos Group. All other product
# and company names mentioned are trademarks or registered trademarks of their respective owners.
