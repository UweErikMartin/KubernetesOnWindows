# useful information https://www.jamessturtevant.com/posts/Windows-Containers-on-Windows-10-without-Docker-using-Containerd/
# https://github.com/kubernetes-sigs/sig-windows-tools
# https://stackoverflow.com/questions/71531188/can-not-start-containerd-container-on-windows
# https://gist.github.com/jsturtevant/6ffc1db253a700f28dd8e0fb706a6bad
# https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/hns.psm1

$ContainerdVersion  = "1.6.10"
$ContainerdFileName = -join ("containerd-",$ContainerdVersion,"-windows-amd64.tar.gz")
$ContainerdDownload = -join ("https://github.com/containerd/containerd/releases/download/v",$ContainerdVersion,"/",$ContainerdFileName)

$CrictlVersion		= "1.25.0"
$CrictlFileName		= -join ("crictl-v",$CrictlVersion,"-windows-amd64.tar.gz")
$CrictlDownload		= -join ("https://github.com/kubernetes-sigs/cri-tools/releases/download/v",$CrictlVersion,"/",$CrictlFileName)

$CniVersion			= "0.3.0"
$CniFileName		= -join ("windows-container-networking-cni-amd64-v",$CniVersion,".zip")
$CniDownload		= -join ("https://github.com/microsoft/windows-container-networking/releases/download/v",$CniVersion,"/",$CniFileName)

$HnsModuleFileName	= "hns.psm1"
$HnsModuleDownload 	= -join ("https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/",$HnsModuleFileName)

###############################################################################
# Helper function:
# 
# Checking Windows Pre-requisites ro run containerd and networks
###############################################################################
$requiredWindowsFeatures = @(
    "Containers",
    "Microsoft-Hyper-V",
    "Microsoft-Hyper-V-Management-PowerShell")

function checkOrInstallWindowsFeatures() {
	[CmdletBinding()]
	Param(
		[parameter(Mandatory=$true)] $requiredFeatures
	)

	$allFeaturesInstalled = $true
	
	foreach ($feature in $requiredFeatures) {
		$f = Get-WindowsOptionalFeature -Online -FeatureName $feature
		if ($f.State -ne "Enabled") {
			Write-Warning "Windows feature: '$feature' is not installed, installing now ..."
			Enable-WindowsOptionalFeature -Online -FeatureName $feature
			$allFeaturesInstalled = $false
		}
	}

	return $allFeaturesInstalled
}

###############################################################################
# Helper function:
# 
# Downloads a component from the Internet if not yet available into the 
# current users download folder
###############################################################################
function checkOrDownloadFile() {
[CmdletBinding()]
	Param(
		[parameter(Mandatory=$true)] [string] $FileName,
		[parameter(Mandatory=$true)] [string] $SourceUrl
	)
	
	$UserDownloadFolder = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
	$DestinationPath = -join ( $UserDownloadFolder, "\", $FileName )
	
	if (-not (Test-Path($DestinationPath)))
	{
		Write-Host "Downloading $FileName from $SourceUrl into $UserDownloadFolder/$FileName"
		Invoke-WebRequest -URI $SourceUrl -OutFile $DestinationPath
	} else {
		Write-Host "skip download ... File $DestinationPath already downloaded"
	}
	return $DestinationPath
}

###############################################################################
# Helper function:
# 
# returns the current version of containerd or null if containerd is not
# available
###############################################################################
function getInstalledVersion() {
	[CmdletBinding()]
	Param (
		[parameter(mandatory=$true)] [string] $command
	)
	
	$Path = Get-Command $command -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "Path"

	if ( $Path ) {
		$v = Invoke-Expression -Command "& '$Path' --version"
		if ($v -match ".*v(?<VER>\d+.\d+.\d+).*") {
			return $Matches.VER
		}
	}
	return $null
}

###############################################################################
# Helper function:
# 
# checks and installs the requested containerd Version
###############################################################################
function checkAndInstallContainerd {
	[CmdletBinding()]
	Param (
		[parameter(mandatory=$true)] [string] $DownloadLocation,
		[parameter(mandatory=$true)] [string] $Version
	)

	$installedVersion = getInstalledVersion "containerd"
	
	if ($installedVersion -ne $Version) {
		$ContainerdPath	= -join ($env:ProgramFiles,"\containerd")
		Write-Host "Install Containerd v$Version into $ContainerdPath"

		if (-not (Test-Path -Path $ContainerdPath)) {
			mkdir -Force $ContainerdPath | Out-Null
		} else {
			# it can happen that containerd is not in the path and
			# therefore not found. Check the default location snd stop and 
			# remove if it is there
			if ( (Get-Service -Name "containerd" -ErrorAction SilentlyContinue).Status -eq "Running" ) {
				Stop-Service "containerd"
			}
			Invoke-Expression "& '$ContainerdPath/containerd.exe' --unregister-service"
		}
		
		tar -xvf $DownloadLocation --strip-components 1 --directory $ContainerdPath
		addPath $ContainerdPath
		return "$ContainerdPath\containerd.exe"
	} else {
		return(Get-Command "containerd").Path
	}
}

###############################################################################
# Helper function:
# 
# checks and installs the requested crictl Version
###############################################################################
function checkAndInstallCrictl {
	[CmdletBinding()]
	Param (
		[parameter(mandatory=$true)] [string] $Download,
		[parameter(mandatory=$true)] [string] $Version
	)

	$installedVersion = getInstalledVersion "crictl"
	
	if ($installedVersion -ne $Version) {
		$CrictlPath	= -join ($env:ProgramFiles,"\crictl")
		Write-Host "Install crictl v$Version into $CrictlPath"

		if (-not (Test-Path -Path $CrictlPath)) {
			mkdir -Force $CrictlPath | Out-Null
		}
		
		tar -xvf $Download --directory $CrictlPath
		addPath $CrictlPath

		$ProfilePath = [Environment]::GetFolderPath("UserProfile")
		if (!(Test-Path "ProfilePath\.crictl\crictl.yaml")) {
			if (!(Test-Path "$ProfilePath\.crictl"))
			{
				New-Item -Path "$ProfilePath\.crictl" -ItemType "directory" -Force
			}
@"
runtime-endpoint: npipe://./pipe/containerd-containerd
image-endpoint: npipe://./pipe/containerd-containerd
timeout: 10
debug: false
pull-image-on-create: true
"@ | Set-Content "$ProfilePath\.crictl\crictl.yaml" -Force
		}
		
		return "$CrictlPath\crictl.exe"
	} else {
		return(Get-Command "crictl").Path
	}
}

###############################################################################
# Helper function:
# 
# Adds a path to the Machine PATH variable in case it does not exist yet
###############################################################################
function addPath() {
	[CmdletBinding()]
	Param (
		[parameter(mandatory=$true)] [string] $ProgramPath
	)
	
	Write-Host "Adding Path $ProgramPath"
	$CurrentPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine) -split ";"
	if ( ! $currentPath.Contains($ProgramPath) )
	{
		Write-Host "Adding $ProgramPath to PATH environment"
		$currentPath += $ProgramPath
		$currentPath = $currentPath -join ";"
		[Environment]::SetEnvironmentVariable("Path", $currentPath, [System.EnvironmentVariableTarget]::Machine)
	}
}

###############################################################################
# Main script
# The script requires elevation
###############################################################################
if (-Not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
	Throw "Please run this script with elevated permission (Run As Administrator)"
	exit
}

$allInstalled = checkOrInstallWindowsFeatures $requiredWindowsFeatures

if ( ! $allInstalled ) {
	Write-Warning "Installation of optional features was done - please start the script again"
	exit 1
}

# Download and install containerd
$download = checkOrDownloadFile $ContainerdFileName $ContainerdDownload
$Containerd = checkAndInstallContainerd $download $ContainerdVersion
if ( $Containerd ) {
	$containerdPath = Split-Path $Containerd -Parent
	Write-Host "Containerd Path: $containerdPath"
	Invoke-Expression "& '$containerd' config default" | Out-File "$containerdPath\config.toml" -Encoding ascii
	#config file fixups
	$config = Get-Content "$containerdPath\config.toml"
	$config = $config -replace "bin_dir = (.)*$", "bin_dir = `"$Env:SystemDrive\\opt\\cni\\bin`""
	$config = $config -replace "conf_dir = (.)*$", "conf_dir = `"$Env:SystemDrive\\etc\\cni\\net.d`""
	$config | Set-Content "$containerdPath\config.toml" -Force 
}

$download = checkOrDownloadFile $CniFileName $CniDownload
Write-Host "Extract cni-plugins into $Env:SystemDrive\opt\cni\bin"
Expand-Archive -Path $download -DestinationPath "$Env:SystemDrive\opt\cni\bin" -Force

$download = checkOrDownloadFile $CrictlFileName $CrictlDownload
checkAndInstallCrictl $download $CrictlVersion

$NatNetwork = Get-HnsNetwork | Where-Object { $_.Name -eq "nat" }

if (-not $NatNetwork ) {
	$download = checkOrDownloadFile $HnsModuleFileName $HnsModuleDownload
	Import-Module $download

	$subnet="10.244.1.0/24" 
	$gateway="10.244.1.1"
	New-HNSNetwork -Type NAT -AddressPrefix $subnet -Gateway $gateway -Name "nat"
	$NatNetwork = Get-HnsNetwork | Where-Object { $_.Name -eq "nat" }
	
@"
{
    "cniVersion": "0.2.0",
    "name": "nat",
    "type": "nat",
    "master": "Ethernet",
    "ipam": {
        "subnet": "$subnet",
        "routes": [
            {
                "GW": "$gateway"
            }
        ]
    },
    "capabilities": {
        "portMappings": true,
        "dns": true
    }
}
"@ | Set-Content "c:\etc\cni\net.d\0-containerd-nat.json" -Force
}

$NatNetwork = Get-HnsNetwork | Where-Object { $_.Name -eq "nat" }
Write-Host "Nat-Network exists with AddressPrefix: " $NatNetwork.Subnets.AddressPrefix " and Gateway: " $NatNetwork.Subnets.GatewayAddress

Write-Host "starting containerd ..."
Invoke-Expression "& '$containerd' --register-service"
Start-Service containerd

exit 0




