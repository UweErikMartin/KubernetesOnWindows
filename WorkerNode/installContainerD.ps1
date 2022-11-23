# useful information https://www.jamessturtevant.com/posts/Windows-Containers-on-Windows-10-without-Docker-using-Containerd/
# https://stackoverflow.com/questions/71531188/can-not-start-containerd-container-on-windows
# https://gist.github.com/jsturtevant/6ffc1db253a700f28dd8e0fb706a6bad
# https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/hns.psm1

$ContainerdVersion  = "1.6.10"
$CrictlVersion		= "1.25.0"
$ContainerdFileName = -join ("cri-containerd-cni-",$ContainerdVersion,"-windows-amd64.tar.gz")
$ContainerdDownload = -join ("https://github.com/containerd/containerd/releases/download/v",$ContainerdVersion,"/",$ContainerdFileName)
$CrictlFileName		= -join ("crictl-v",$CrictlVersion,"-windows-amd64.tar.gz")
$CrictlDownload		= -join ("https://github.com/kubernetes-sigs/cri-tools/releases/download/v",$CrictlVersion,"/",$CrictlFileName)
$HnsModuleFileName	= "hns.psm1"
$HnsModuleDownload 	= -join ("https://github.com/Microsoft/SDN/raw/master/Kubernetes/windows/",$HnsModuleFileName)

$UserDownloadFolder = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path

$requiredWindowsFeatures = @(
    "Containers",
    "Hyper-V",
    "Hyper-V-PowerShell")

function ValidateWindowsFeatures {
    $allFeaturesInstalled = $true
    foreach ($feature in $requiredWindowsFeatures) {
        $f = Get-WindowsFeature -Name $feature
        if (-not $f.Installed) {
            Write-Warning "Windows feature: '$feature' is not installed."
            $allFeaturesInstalled = $false
        }
    }
	Write-Warning "To enable nested virtualization run "
	Write-Warning "Set-VMProcessor -VMName <VMName> -ExposeVirtualizationExtensions $true"

	return $allFeaturesInstalled
}


if (-not (ValidateWindowsFeatures)) {
    Write-Output "Installing required windows features..."

    foreach ($feature in $requiredWindowsFeatures) {
        Install-WindowsFeature -Name $feature
    }

    Write-Output "Please reboot and re-run this script."
    exit 0
}

if (-not (Test-Path("$UserDownloadFolder/$ContainerdFileName")))
{
	Write-Host "Downloading Containerd Version $ContainerdVersion from $ContainerdDownload into $UserDownloadFolder\$ContainerdFileName"
	Invoke-WebRequest $ContainerdDownload -OutFile "$UserDownloadFolder\$ContainerdFileName"
}
else
{
	Write-Host "skip download ... File $UserDownloadFolder\$ContainerdFileName already downloaded"
}

if (-not (Test-Path("$UserDownloadFolder/$CrictlFileName")))
{
	Write-Host "Downloading crictl Version $CrictlVersion from $CrictlDownload into $UserDownloadFolder\$CrictlFileName"
	Invoke-WebRequest $CrictlDownload -OutFile "$UserDownloadFolder\$CrictlFileName"
}
else
{
	Write-Host "skip download ... File $UserDownloadFolder\$CrictlFileName already downloaded"
}

if (-not (Test-Path("$UserDownloadFolder/$HnsModuleFileName")))
{
	Write-Host "Downloading HostNetworkServices Powershell Module $HnsModuleFileName from $HnsModuleDownload into $UserDownloadFolder\$HnsModuleFileName"
	Invoke-WebRequest $HnsModuleDownload -OutFile "$UserDownloadFolder\$HnsModuleFileName"
}
else
{
	Write-Host "skip download ... File $UserDownloadFolder\$HnsModuleFileName already downloaded"
}
	
if (-not (Get-Command "containerd" -ErrorAction SilentlyContinue)) {
	$ContainerdPath	= -join ($env:ProgramFiles,"\containerd")
	$Containerd = -join ($ContainerdPath,"\containerd.exe")
	Write-Host "Install Containerd v$ContainerdVersion into $ContainerdPath"
	if (-not (Test-Path -Path $ContainerdPath)) {
		mkdir -Force $ContainerdPath | Out-Null
		tar -xvf "$UserDownloadFolder\$ContainerdFileName" --directory $ContainerdPath
		
		# check whether this is already in the path
		if ( ! ($env:Path -split ";").Contains($ContainerdPath) )
		{
			Write-Host "Adding $ContainerdPath to PATH environment"
			$env:Path += ";$ContainerdPath"
			[Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)
		}
		
		# init the containerd config file
		containerd.exe config default | Out-File "$ContainerdPath\config.toml" -Encoding ascii
		
		# copy the cni-plugins to the "linux-style" folders
		if (-not (Test-Path("$Env:SystemDrive/etc/cni")))
		{	
			mkdir -Force "$Env:SystemDrive/etc/cni/net.d" | Out-Null
			Copy-Item -Path "$ContainerdPath\cni\conf\*" -Recurse -Destination "$Env:SystemDrive/etc/cni/net.d"
		}
		
		if (-not (Test-Path("$Env:SystemDrive/opt/cni")))
		{
			mkdir -Force "$Env:SystemDrive/opt/cni")))
			Copy-Item -Path "$ContainerdPath\cni\bin" -Recurse -Destination "$Env:SystemDrive/opt/cni"
		}
	}
}

$CrictlPath	= -join ($env:ProgramFiles,"\crictl")
$crictl 	= -join ($CrictlPath,"\crictl.exe")
if (-not (Get-Command "crictl" -ErrorAction SilentlyContinue)) {
	Write-Host "Install crictl v$CrictlVersion into $CrictlPath"
	if (-not (Test-Path -Path $CrictlPath)) {
		mkdir -Force $CrictlPath | Out-Null
		tar -xvf "$UserDownloadFolder\$CrictlFileName" --directory $CrictlPath
		
		# check whether this is already in the path
		if ( ! ($env:Path -split ";").Contains($CrictlPath) )
		{
			Write-Host "Adding $CrictlPath to PATH environment"
			$env:Path += ";$CrictlPath"
			[Environment]::SetEnvironmentVariable("Path", $env:Path, [System.EnvironmentVariableTarget]::Machine)
		}
		
		# init the crictl config
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
	}
}

$NatNetwork = Get-HnsNetwork | Where-Object { $_.Name -eq "nat" }

if (-not $NatNetwork ) {
	Import-Module $UserDownloadFolder\$HnsModuleFileName

	$subnet="10.244.1.0/16" 
	$gateway="10.244.1.1"
	New-HNSNetwork -Type Nat -AddressPrefix $subnet -Gateway $gateway -Name "nat"
	$NatNetwork = Get-HnsNetwork | Where-Object { $_.Name -eq "nat" }
}
Write-Host "Nat-Network exists with AddressPrefix: " $NatNetwork.Subnets.AddressPrefix " and Gateway: " $NatNetwork.Subnets.GatewayAddress
