#
#
# Ike Kent
# MonitorSp
#
# To get a usage message:
#	IdentityReport -usage 
# 
#
#
# Get an identity report for the listed ucs domains:
#	IdentityReport -ucsips <ucs-ip1,ucs-ip2> -report IdReport.html
#
# Examples:
#
# To see report of identities on two ucs domains:
# 	ShowIdentity -ucsips 10.29.141.18,10.29.141.21 -report IdReport.html
#
#



#
# Command Line parameters
#
[CmdletBinding()]
Param(
	$disallowunnamed,
	[string[]] $ucsips,
	[string] $report,
	[switch] $usage=$false
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
	Write-Host "	IdentityReport -ucsips <ucs-ip1,ucs-ip2> -report IdReport.html"
	Write-Host ""
	Write-Host "Supported Options:"
	Write-Host "	-usage 			    - (this) usage message"
	Write-Host "	-ucsips <ucs-ip1,ucs-ip2>   - array of UCS ip addresses"
	Write-Host ""
	Write-Host "Example:"
	Write-Host ""
	Write-Host "To see report of mac-addresses:"
	Write-Host "     IdentityReport -ucsip 10.29.141.18,10.29.141.21 -report IdReport"
	Write-Host ""
	exit 1
}



# 
# For pumping out a pretty html report 
# 
function getDocHead()
{

    $lDocHead = @'
<!DOCTYPE html>
	<html lang="eng"> 
	<head>
	<meta charset="utf-8" />

	<title>UCS Identity Report </title>

		<!-- include the Tools -->
		<script src="media/js/jquery.tools.min.js"></script>

		<!-- standalone page styling (can be removed) -->
		<!-- include the Tools -->
  		<link rel="stylesheet" href="resources/ui/1.10.3/themes/smoothness/jquery-ui.css" />
  		<link rel="stylesheet" href="resources/styles.css" />
		<script src="resources/jquery-1.9.1.js"></script>
		<script src="resources/ui/1.10.3/jquery-ui.js"></script>
	</head>
	<style>
		tr:nth-child(even) {background: #CCC}
		tr:nth-child(odd) {background: #FFF}
	</style>

	<body>
		<div id="tabs">
		<ul>
			<li><a href="#tabs-1">Server UUIDs</a></li>
			<li><a href="#tabs-2">MAC Addresses</a></li>
			<li><a href="#tabs-3">WWNs</a></li>
			<li><a href="#tabs-4">IP Addresses</a></li>
			<li><a href="#tabs-5">IQNs</a></li>
			<li><a href="#tabs-6">Conflicts</a></li>
		</ul>
'@

	return $lDocHead
}



# 
# For pumping out a pretty html report 
# 
function getDocTail()
{

	$lDocTail= @'
		</div>

		<script>
			// perform JavaScript after the document is scriptable.
			$(function() {
    				$( "#tabs" ).tabs().addClass();
			});
		</script>
	</body
</html>
'@

	return $lDocTail
}



function createReport([string] $aInReportFile)
{
	$lDocHead = getDocHead
	Add-Content $aInReportFile $lDocHead


	# GRAB OUR UUID ADDRESSES 
	$lUuids = Get-UcsUuidPoolAddr 
	$lUuidTable = $lUuids | ConvertTo-Html -Fragment -Property $global:UUID_FORMAT

	Add-Content $aInReportFile "<div id='tabs-1'>"
	Add-Content $aInReportFile "<H2> Server UUIDs </H2>"
	$lUuidTable | Add-Content $aInReportFile
	Add-Content $aInReportFile "</div>"
	Add-Content $aInReportFile ""
	Add-Content $aInReportFile ""

	# GRAB OUR MAC ADDRESSES 
	$lMacs = Get-UcsMacPoolAddr 
	$lMacTable = $lMacs | ConvertTo-Html -Fragment -Property $global:MAC_FORMAT

        # GRAB DUPLICATES
	$lDupMacs = $lMacs | Group-Object {$_.id} | Where-Object {$_.count -gt 1 } | select -ExpandProperty Group |  select Ucs,Id,assigned,assignedToDn | sort-object id

	Add-Content $aInReportFile "<div id='tabs-2'>"
	Add-Content $aInReportFile "<H2> MAC Addresses </H2>"
	$lMacTable | Add-Content $aInReportFile
	Add-Content $aInReportFile "</div>"
	Add-Content $aInReportFile ""
	Add-Content $aInReportFile ""


	# GRAB OUR FC ADDRESSES 
	$lWwns = Get-UcsFcPoolAddr 
	$lWwnTable = $lWwns | ConvertTo-Html -Fragment -Property $global:WWN_FORMAT

        # GRAB DUPLICATES
	$lDupWwns= $lWwns | Group-Object {$_.id} | Where-Object {$_.count -gt 1 } | select -ExpandProperty Group | select Ucs,Id,assigned,assignedToDn | sort-object id

	Add-Content $aInReportFile "<div id='tabs-3'>"
	Add-Content $aInReportFile "<H2> FC WWNs </H2>"
	$lWwnTable | Add-Content $aInReportFile
	Add-Content $aInReportFile "</div>"
	Add-Content $aInReportFile ""
	Add-Content $aInReportFile ""


	# GRAB OUR IP ADDRESSES 
	$lIps = Get-UcsIpPoolAddr 
	$lIpTable = $lIps | ConvertTo-Html -Fragment -Property $global:IP_FORMAT

        # GRAB DUPLICATES
	$lDupIps = $lIps | Group-Object {$_.id} | Where-Object {$_.count -gt 1 } | select -ExpandProperty Group | select Ucs,Id,assigned,assignedToDn | sort-object id

	Add-Content $aInReportFile "<div id='tabs-4'>"
	Add-Content $aInReportFile "<H2> IPs</H2>"
	$lIpTable | Add-Content $aInReportFile
	Add-Content $aInReportFile "</div>"
	Add-Content $aInReportFile ""
	Add-Content $aInReportFile ""


	# GRAB OUR IQN ADDRESSES 
	$lIqns = Get-UcsIqnPoolAddr 
	$lIqnTable = $lIqns | ConvertTo-Html -Fragment -Property $global:IQN_FORMAT

        # GRAB DUPLICATES
	$lDupIqns = $lIqns | Group-Object {$_.id} | Where-Object {$_.count -gt 1 } | select -ExpandProperty Group | select Ucs,Name,assigned,assignedToDn | sort-object Name

	Add-Content $aInReportFile "<div id='tabs-5'>"
	Add-Content $aInReportFile "<H2> IQNs</H2>"
	$lIqnTable | Add-Content $aInReportFile
	Add-Content $aInReportFile "</div>"
	Add-Content $aInReportFile ""
	Add-Content $aInReportFile ""

	# CONFLICTS (DUPLICATE ADDRESSES ACROSS DOMAINS)
	$lDupMacTable = $lDupMacs | ConvertTo-Html -Fragment 
	$lDupWwnTable = $lDupWwns | ConvertTo-Html -Fragment 
	$lDupIpTable =  $lDupIps  | ConvertTo-Html -Fragment 
	$lDupIqnTable = $lDupIqns | ConvertTo-Html -Fragment 

	Add-Content $aInReportFile "<div id='tabs-6'>"

	Add-Content $aInReportFile "<H2> Duplicate MACs</H2>"
	$lDupMacTable | Add-Content $aInReportFile

	Add-Content $aInReportFile "<H2> Duplicate WWNs</H2>"
	$lDupWwnTable | Add-Content $aInReportFile

	Add-Content $aInReportFile "<H2> Duplicate IQNs</H2>"
	$lDupIqnTable | Add-Content $aInReportFile

	Add-Content $aInReportFile "<H2> Duplicate IPs</H2>"
	$lDupIpTable | Add-Content $aInReportFile

	Add-Content $aInReportFile "</div>"

	Add-Content $aInReportFile ""
	Add-Content $aInReportFile ""

	$lDocTail = getDocTail
	Add-Content $aInReportFile $lDocTail
}



$global:MAC_FORMAT =
		@{expression="ucs";label="Domain"},
		@{expression="id";label="Identity"},
		@{expression="assigned";label="Assigned"},
		@{expression="owner";label="Owner"},
		@{expression="assignedToDn";label="Assigned To"}

$global:WWN_FORMAT =
		@{expression="ucs";label="Domain"},
		@{expression="id";label="Identity"},
		@{expression="assigned";label="Assigned"},
		@{expression="owner";label="Owner"},
		@{expression="assignedToDn";label="Assigned To"}

$global:UUID_FORMAT =
		@{expression="ucs";label="Domain"},
		@{expression="id";label="Identity"},
		@{expression="assigned";label="Assigned"},
		@{expression="owner";label="Owner"},
		@{expression="assignedToDn";label="Assigned To"}

$global:IP_FORMAT =
		@{expression="ucs";label="Domain"},
		@{expression="id";label="Identity"},
		@{expression="assigned";label="Assigned"},
		@{expression="owner";label="Owner"},
		@{expression="assignedToDn";label="Assigned To"}

$global:IQN_FORMAT =
		@{expression="ucs";label="Domain"},
		@{expression="name";label="Name"},
		@{expression="assigned";label="Assigned"},
		@{expression="owner";label="Owner"},
		@{expression="assignedToDn";label="Assigned To"}

$global:DUP_FORMAT = 
		@{expression="key";label="Identity"},
		@{expression="value";label="Domains"}


# Print usage message if necessary
if ($usage)
{
    printUsage "" 
}

$output = Set-UcsPowerToolConfiguration -SupportMultipleDefaultUcs $true

# Error if there are unknown command line options
if ($disallowunnamed)
{
	printUsage "You have extraneous command line options"
}

if ($report -eq "")
{
	printUsage "Error, no report file specified"
}
if (Test-Path $report)
{ 
	Write-Error "Error, report file `"$report`" already exists"
	exit 1
}
if ($ucsips.length -eq 0)
{ 
	printUsage "No UCS domains provided"
}

try 
{
	# Connect to each UCS system
	foreach ($ucs in $ucsips)
	{
		Write-Host "Connecting to domain : $ucs"
		${lUcsCred} = Get-Credential
		${myCon} = Connect-Ucs -Name $ucs -Credential ${lUcsCred} 
	}

	createReport $report
}
catch
{ 
	Write-Error "Caught error during info gathering"
	Write-Error ([String] ${Error})
	Write-Error "Continuing"
}
finally
{
	Write-Host "UCS: Logging out of UCS: $lUcs"
	$ucslogout = Disconnect-Ucs 
}



