###############################################################################
# Helper function:
# 
# Remove a path to the Machine PATH variable in case it does not exist yet
###############################################################################
function removePath() {
	[CmdletBinding()]
	Param (
		[parameter(mandatory=$true)] [string] $ProgramPath
	)
	
	$CurrentPath = [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine) -split ";"
	if ( $currentPath.Contains($ProgramPath) )
	{
		Write-Host "Remove $ProgramPath from PATH environment"
		$currentPath = $currentPath | Where { $_ -ne $ProgramPath }
		$currentPath = $currentPath -join ";"
		[Environment]::SetEnvironmentVariable("Path", $currentPath, [System.EnvironmentVariableTarget]::Machine)
	}
}
###############################################################################
# Main Script
###############################################################################
$containerd = Get-Command -Name "containerd" -ErrorAction SilentlyContinue

if ( -not $containerd ) {
	Write-Warning "Containerd cannot be found - not installed? - exiting ..."
	exit (1)
}

$containerdService = Get-Service -Name containerd -ErrorAction SilentlyContinue

if ( $containerdService ) {
	if ($containerdService.Status -eq "Running") {
		Write-Host "Stop containerd Service"
		Stop-Service -Name containerd
	}
	Write-Host "Unregister containerd Service"
	containerd.exe --unregister-service
}

$containerdPath = Split-Path $containerd.Path -Parent

Write-Host "Remove Directory $containerdPath"
Remove-Item $containerdPath -Recurse
removePath $containerdPath