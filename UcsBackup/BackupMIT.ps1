#
# Ike Kent
# MonitorSp
#
# To get a usage message:
# 	BackupMit
# 

#
#
# A simple demo script to illustrate the UCS XML API and PowerTool libraries.
# This script queries the entire UCS MIT and saves the response in an xml file
# for off-line processing.
# 
# Examples:
#
# To backup the MIT
# 
# 	BackupMit.ps1 -ucsip 10.29.141.18 -backupDir 'c:\Backups'
#



#
# Command Line parameters
#
[CmdletBinding()]
Param(
	$disallowunnamed,
	[string] $ucsip,
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
	Write-Host "	BackupMit -ucsip <ucs-ip> -outfile=<filename>"
	Write-Host ""
	Write-Host "Supported Options:"
	Write-Host "	-outfile<filename>         - backup file to store MIT in "
        Write-Host ""
        Write-Host ""
	Write-Host "Example:"
	Write-Host ""
	Write-Host "	BackupMit -ucsip 10.29.141.18 -file=backup.xml"
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
if ($outfile -eq "")
{
	printUsage "Error, no backup file specified"
}           

${lUcsCred} = Get-Credential

try 
{
	${myCon} = Connect-Ucs -Name $ucsip -Credential ${lUcsCred} -ErrorAction SilentlyContinue
	$lSession = Get-UcsPSSession 
        $lCookie = $lSession.cookie 
        $lName = $lSession.name

        $lFullStatePattern = $backupDir + '\${ucs}-${yyyy}-${dd}-${MM}-${HH}${mm}-config-system.tar.gz'
        $lConfigAllPattern = $backupDir + '\${ucs}-${yyyy}-${dd}-${MM}-${HH}${mm}-config-all.xml'
        $lMitFilename= $backupDir + '\' + $lName + "{0:yyyy-MM-dd-HHmm}-MIT.xml" -f (Get-Date)

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





