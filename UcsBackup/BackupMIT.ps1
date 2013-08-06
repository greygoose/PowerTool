#
# Ike Kent
# MonitorSp
#
# To get a usage message:
# 	BackupMit
# 

#
#
# A simple demo script for the UCS XML API and PowerTool libraries.
#
# This script produces the following artifacts:
# 1) Full State backup
# 2) Config All backup
# 3) UCS MIT snap-shot - queries children of topRoot hierarchically and stores in xml file for off-line processing.
# 
# Examples:
#
# To backup the MIT
# 
# 	BackupMit.ps1 -ucsip 10.29.141.18 -user admin -password="Nbv12345" -backupDir 'c:\Backups'
#



#
# Command Line parameters
#
[CmdletBinding()]
Param(
	$disallowunnamed,
	[string] $ucsip,
	[string] $user,
	[string] $password,
	[string] $backupDir
)



# 
# Check module dependencies
# 
if ((Get-Module |where {$_.Name -ilike "CiscoUcsPS"}).Name -ine "CiscoUcsPS")
{
	Write-Host "Loading Module: Cisco UCS PowerTool Module"
	Import-Module CiscoUcsPs
}



# 
# print a usage message and exit
#
function printUsage([string] $aInMsg)
{
	Write-Host $aInMsg
	Write-Host ""
	Write-Host "Usage: "
	Write-Host "	BackupMit.ps1 -ucsip <ip-address> -user <ucs-username> -password=<ucs-password>  -backupDir <backup-directory>"
	Write-Host ""
        Write-Host ""
	Write-Host "Example:"
	Write-Host ""
	Write-Host "	BackupMit.ps1 -ucsip 10.29.141.18 -user admin -password=\"Nbv12345\" -backupDir \'c:\Backups\'"
	Write-Host ""

	exit 1
}



if ($usage)
{
    printUsage "" 
}

$output = Set-UcsPowerToolConfiguration -SupportMultipleDefaultUcs $false

# Error if there are unknown command line options
if ($disallowunnamed)
{
	printUsage "You have extraneous command line options"
}
if ($ucsip -eq "")
{
	printUsage "Error, no ucs ip provided"
}           
if ($user -eq "")
{
	printUsage "Error, no ucs username provided"
}           
if ($password -eq "")
{
	printUsage "Error, no ucs password"
}           



try 
{
	$passwordSecure = ConvertTo-SecureString -AsPlainText -Force -string $password
	$cred = New-Object System.Management.Automation.PSCredential($user, $passwordSecure)
	Connect-Ucs $ucsip -Credential $cred

	$lSession = Get-UcsPSSession 
        $lCookie = $lSession.cookie 
        $lName = $lSession.name

        $lFullStatePattern = $backupDir + '\${ucs}-${yyyy}-${dd}-${MM}-${HH}-${mm}-config-system.tar.gz'
        $lConfigAllPattern = $backupDir + '\${ucs}-${yyyy}-${dd}-${MM}-${HH}-${mm}-config-all.xml'
        $lMitFilename= $backupDir + '\' + $lName + "{0:yyyy-MM-dd-HH-mm}-MIT.xml" -f (Get-Date)

	Write-Host "Running a full-state backup of the system"
        # Write-Host "Full State: " $lFullStatePattern
        Backup-Ucs -Type full-state -PathPattern $lFullStatePattern

	Write-Host "Running a config-all backup of the system"
        # Write-Host "Config All: " $lConfigAllPattern
        Backup-Ucs -Type config-all -PathPattern $lConfigAllPattern

        # Save query of MIT to a file for off-line processing.
        # Write-Host "Mit: " $lMitPattern
        $lQuery = '<configResolveChildren cookie="' + $lCookie + '" inHierarchical="true" inDn=""/>' 
	Write-Host "Running query of entire MIT: " $lQuery
	$lMit = Invoke-UcsXml -XmlQuery $lQuery
	$lMit.toString() | Out-File $lMitFilename
}
catch
{ 
	Write-Error "Caught error during info gathering"
	Write-Error ([String] ${Error})
	Write-Error "Continuing"
}
finally
{
	Disconnect-Ucs
}



