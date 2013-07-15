#
#
# Ike Kent
# MonitorSp
#
# To get a usage message:
# 	MonitorSp 
# 
# 

#
#
# A simple demo script to illustrate the UCS XML API and PowerTool libraries.
# It is intended to monitor a service profile that is associated with physical 
# hardware via a compute pool.  If a fatal fault occurs, it decomissions 
# the physical blade/rack-server and re-associates the service profile with 
# another server.  
#
#
# The fail-over criteria is the existence of a "fatal" fault.
# Fatal faults are defined provided by users in a csv file. 
#  
# For example: 
#
# type,code,name
# "cpu","F0180","fltProcessorUnitVoltageThresholdNonRecoverable"
# "memory","F0184","fltMemoryUnitDegraded"
# "memory","F0185","fltMemoryUnitInoperable"
# "memory","F0537","fltMemoryBufferUnitThermalThresholdNonRecoverable"
# "memory","F0191","fltMemoryArrayVoltageThresholdNonRecoverable"
# "memory","F0188","fltMemoryUnitThermalThresholdNonRecoverable
#
# You can simulate a fail-over by setting the "usrLbl" field of the physical
# blade to "SIM FAILURE" if the script is run with the -sim option
# 
# Examples:
#
# To monitor service profile Bill polling every 10 minutes:
# 
# 	MonitorSp -ucsip 10.29.141.18 -poll 600 -spdn org-root/ls-Orcl -logfile=info.log -fault fault.csv
#
#
# To monitor service profile Bill polling every 5 minutes and fail-over if the user
# updates the physical nodes user label to "SIM FAILURE"
#
# 	MonitorSp -ucsip 10.29.141.18 -poll 300 -spdn org-root/ls-VmScale" -sim
#


#
# Command Line parameters
#
[CmdletBinding()]
Param(
	$disallowunnamed,
	[Parameter(Mandatory=$true)]
	[string] $ucsip,
	[Parameter(Mandatory=$true)]
	[string] $spdn,
	[Parameter(Mandatory=$true)]
	[string] $fault,
	[string] $logfile,
	[switch] $sim=$false,
	[switch] $usage=$false,
	[int] $poll=300
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
	Write-Host "     MonitorSp -ucsip <ucs-ip> -spdn <dn> -fault <csv file> [-poll <time-secs>] [-sim] "
	Write-Host ""
	Write-Host "Supported Options:"
	Write-Host "	-logfile <fname>        - log file (default is monitor.log)"
        Write-Host "	-spdn <dn>    		- service profile dn"
        Write-Host "	-poll <seconds>    	- poll time in seconds (>60)"
        Write-Host "	-sim     		- allow fail-over to be simulated.  If the usrLbl "
	Write-Host "				  	property on the blade/rack-unit is set to SIM FAILURE "
	Write-Host "					the server is treated as a failed server "
        Write-Host "	-fault     		- csv file with fault (code,name,type)  type is either memory or cpu"
	Write-Host "Example:"
	Write-Host ""
	Write-Host "To monitor service profile Bill polling every 5 minutes:"
	Write-Host "	MonitorSp -ucsip 10.29.141.18 -poll 300 -spdn org-root/ls-Bill -fault fault.csv"
	Write-Host ""
	Write-Host ""
        Write-Host "    MonitorSp -ucsip 10.29.141.21 -poll 60 -spdn org-root/ls-VmScale -fault fault.csv -sim"
	Write-Host ""
	Write-Host ""
	exit 1
}




# 
# Print debug output to a log file
# 
function debugPrint
{
		$aInMsg = ""
		for ($i=0; $i -lt $args.length; $i++)
		{
			$aInMsg += $args[$i]
		}
		if ($global:gLogInit -eq $false)
		{
			$global:gLogInit = $true
			$lMsg = "-- Log Start $(get-date -format MM-dd-yy-HH:mm:ss)"
			$lMsg > $logfile
			Write-Verbose $lMsg
		}
		$aInMsg >> $logfile
		Write-Verbose $aInMsg
}




# 
# Case sensitive hashtable
# 
function New-CHashTable
{
	New-Object Collections.Hashtable ([StringComparer]::CurrentCulture)
}




#
# Track the passed warning for the passed dn
#
function addWarning ([string] $aInDn, [string] $aInWarning)
{
	debugPrint $aInDn " : " $aInWarning
	if (!$global:poolWarnings.containsKey($aInDn))
	{
		$global:poolWarnings[$aInDn] = @()
	}
	$global:poolWarnings[$aInDn] += $aInWarning
}




#
# Determine if the blade should fail-over
#
function shouldFailOver ([string] $aInSpDn, [hashtable] $aInSpInfo)
{

	if ((!$aInSpInfo["summary"].containsKey("foundSp")) -or
	    ($aInSpInfo["summary"]["foundSp"] -notlike "true"))
	{
		Write-Warning("Unable to get service profile information for " + $aInSpDn)
		Write-Warning("Will not fail-over service profile :" + $aInSpDn)
		return $false
	}

	if ((!$aInSpInfo["summary"].containsKey("assignState")) -or
	    ($aInSpInfo["summary"]["assignState"] -notlike "assigned"))
	{
		$lAssignState = ""
		if ($aInSpInfo["summary"].containsKey("assignState")) 
		{
			$lAssignState = $aInSpInfo["summary"]["assignState"]
		}
		Write-Warning ("Service profile is not assigned :" + $lAssignState)
		Write-Warning("Will not fail-over service profile :" + $aInSpDn)
		return $false
	}

	if ((!$aInSpInfo["summary"].containsKey("assocState")) -or
	    ($aInSpInfo["summary"]["assocState"] -notlike "associated"))
	{
		$lAssocState = ""
		if ($aInSpInfo["summary"].containsKey("assocState"))
		{
			$lAssocState = $aInSpInfo["summary"]["assocState"]
		}

		Write-Warning("Service profile is not associated :" + $lAssocState)
		Write-Warning("Will not fail-over service profile :" + $aInSpDn)
		return $false
	}

	if ((!$aInSpInfo["summary"].containsKey("type")) -or
	    ($aInSpInfo["summary"]["type"] -notlike "instance"))
	{
		$lType = ""
		if ($aInSpInfo["summary"].containsKey("type")) 
		{
			$lType = $aInSpInfo["summary"]["type"]
		}
		Write-Warning("Service profile is not an instance :" + $lType)
		Write-Warning("Will not fail-over service profile :" + $aInSpDn)
		return $false
	}

	if ((!$aInSpInfo["summary"].containsKey("pooled")) -or
	    ($aInSpInfo["summary"]["pooled"] -notlike "true"))
	{
		Write-Warning("Service profile is not pooled ")
		Write-Warning("Will not fail-over service profile :" + $aInSpDn)
		return $false
	}

	if (!$aInSpInfo["summary"].containsKey("poolName"))
	{
		Write-Warning("Could not determine compute pool name")
		Write-Warning("Will not fail-over service profile :" + $aInSpDn)
		return $false
	}

	# Just print a warning if there are no servers in the pool
	# We still fail-over
	if ($aInSpInfo["summary"].containsKey("availPhysInPool") -and
             (([int]$aInSpInfo["summary"]["availPhysInPool"]) -lt 1))
	{
		$lPoolDn = $aInOutSpInfo["summary"]["poolDn"]
		Write-Warning("The compute pool has no available resources: " + $lPoolDn)
	}

	if ($global:SIM_MODE)
	{
		$lFailOver = isSimFailure $aInSpDn $aInSpInfo
		if ($lFailOver)
		{
			Write-Warning("Simulated fail-over condition met ")
			Write-Warning("Failing over service profile :" + $aInSpDn)
			return $true
		}
	}

        # This is the critical piece of code that must be implemented in order
        # to identify scenarios where fail-over should be performed.
        # For illustrative purposes only - fail-over will be done if a
        # processUnit or memoryUnit is inoperable
        # (These scenarios could be identified by faults too)

	$lFailOver = isComputeFailed $aInSpDn $aInSpInfo
	if ($lFailOver)
	{
		Write-Warning("Compute fail-over condition met ")
		Write-Warning("Failing over service profile :" + $aInSpDn)
		return $true
	}

	$lFailOver = isMemoryFailed $aInSpDn $aInSpInfo
	if ($lFailOver)
	{
		Write-Warning("Memory fail-over condition met ")
		Write-Warning("Failing over service profile :" + $aInSpDn)
		return $true
	}

        return $false
}




# 
# Simple memory failure check
# We search for memory faults in the list of faults
#
function isMemoryFailed ([string] $aInSpDn, [hashtable] $aInSpInfo)
{
	$lFailed = $false
	write-Host "Checking memory faults "

	# Print out fault information
	$lFaultClass="Cisco.ucs.faultInst"
	if ($aInSpInfo.containsKey($lFaultClass))
	{
		foreach ($lDn in $aInSpInfo[$lFaultClass].keys)
		{
			$lCode = $aInSpInfo[$lFaultClass][$lDn]["code"]
			if ($global:FAIL_MEMORY_FAULTS.containsKey($lCode))
			{
				$lSeverity = $aInSpInfo[$lFaultClass][$lDn]["severity"]
				$lastTransition = $aInSpInfo[$lFaultClass][$lDn]["lastTransition"]
				$lId = $aInSpInfo[$lFaultClass][$lDn]["id"]
				$lDesc = $aInSpInfo[$lFaultClass][$lDn]["descr"]
				Write-Warning("Memory failure trigger fault:")
				Write-Warning($lSeverity + "   " + $lCode + "   " + $lastTransition + "   " + $lId + "   " + $lDesc) 
				$lFailed = $true
			}
		}
	}

	if ($lFailed)
	{
		Write-Warning("Memory failure")
	}
	else
	{
		Write-Warning("Memory ok")
	}
	return $lFailed
}




#
# Simple cpu failure check
# We search for cpu faults in the list of faults
#
function isComputeFailed ([string] $aInSpDn, [hashtable] $aInSpInfo)
{
	$lFailed = $false
	write-Host "Checking cpu faults "

	# Print out fault information
	$lFaultClass="Cisco.ucs.faultInst"
	if ($aInSpInfo.containsKey($lFaultClass))
	{
		foreach ($lDn in $aInSpInfo[$lFaultClass].keys)
		{
			$lCode = $aInSpInfo[$lFaultClass][$lDn]["code"]
			if ($global:FAIL_CPU_FAULTS.containsKey($lCode))
			{
				$lSeverity = $aInSpInfo[$lFaultClass][$lDn]["severity"]
				$lastTransition = $aInSpInfo[$lFaultClass][$lDn]["lastTransition"]
				$lId = $aInSpInfo[$lFaultClass][$lDn]["id"]
				$lDesc = $aInSpInfo[$lFaultClass][$lDn]["descr"]
				Write-Warning("CPU failure trigger fault:")
				Write-Warning( $lSeverity + "   " + $lCode + "   " + $lastTransition + "   " + $lId + "   " + $lDesc )
				$lFailed = $true
			}
		}
	}

	if ($lFailed)
	{
		Write-Warning("Compute failure")
	}
	else
	{
		Write-Warning("Compute ok")
	}
	return $lFailed
}




#
# For simulation purposes, we fail-over if the "usrLbl" on the rack-unit
# or blade has the value "SIM FAILURE"
#
function isSimFailure ([string] $aInSpDn, [hashtable] $aInSpInfo)
{
	$lPhysClass = $null
	if ($aInSpInfo.containsKey("Cisco.ucs.computeBlade"))
	{
		$lPhysClass = "Cisco.ucs.computeBlade"
	}
	else
	{
		$lPhysClass = "Cisco.ucs.computeRackUnit"
	}

	foreach ($lDn in $aInSpInfo[$lPhysClass].keys)
	{
		$lKey = "usrLbl"
		if ($aInSpInfo[$lPhysClass][$lDn].containsKey("usrLbl"))
		{
			$lUsrLbl = $aInSpInfo[$lPhysClass][$lDn]["usrLbl"]
			# write-Host "Label is :" $lUsrLbl
			if ($lUsrLbl -eq $global:FAILED_LABEL)
			{
				Write-Warning("Sim fail-over")
				return $true;
			}
		}
	}
	Write-Warning("Sim ok")
	return $false
}




#
# Add the passed SP info to our master Map
#
function addSpInfo([hashtable] $aInOutSpInfo, [string] $aInClass, [string] $aInDn, [hashtable] $aInAttrMap)
{
	if (!$aInOutSpInfo.containsKey($aInClass))
	{
		$aInOutSpInfo[$aInClass] = New-CHashtable
	}
	$aInOutSpInfo[$aInClass][$aInDn] = $aInAttrMap
}




#
# Add the passed block IdMap to our master IdMap
#
function addSpSummaryInfo([hashtable] $aInOutSpInfo, [string] $aInName, [string] $aInValue)
{
	if (!$aInOutSpInfo.containsKey("summary"))
	{
		$aInOutSpInfo["summary"] = New-CHashtable
	}
	$aInOutSpInfo["summary"][$aInName] = $aInValue
}




# 
# Print some information about the service profile 
#
function printSpInfo ([string] $aInMsg, [hashtable] $aInSpInfo)
{
	# Print out the SP's logical information
	write-Host ""
	write-Warning "Logical Server Information"
	foreach ($lClass in $global:SP_LOG_CLASS)
	{
		if ($aInSpInfo.containsKey($lClass))
		{
			foreach ($lDn in $aInSpInfo[$lClass].keys)
			{
				write-Host $lDn ":"
				foreach ($lKey in $global:SP_LOG_MAP[$lClass])
				{
					if ($aInSpInfo[$lClass][$lDn].containsKey($lKey))
					{
		 				write-Host "`t" $lKey ":" $aInSpInfo[$lClass][$lDn][$lKey]
					}
				}
			}
		}
	}

	# Print out the SP's physical information
	write-Host ""
	write-Warning "Physical Server Information"
	foreach ($lClass in $global:SP_PHYS_CLASS)
	{
		if ($aInSpInfo.containsKey($lClass))
		{
			foreach ($lDn in $aInSpInfo[$lClass].keys)
			{
				write-Host $lDn ":" 
				foreach ($lKey in $global:SP_PHYS_MAP[$lClass])
				{
					if ($aInSpInfo[$lClass][$lDn].containsKey($lKey))
					{
		 				write-Host "`t" $lKey ":" $aInSpInfo[$lClass][$lDn][$lKey]
					}
				}
			}
		}
	}

	# Print out fault information
	write-Host ""
	write-Warning "Faults:"
	$lFaultClass="Cisco.ucs.faultInst"
	if ($aInSpInfo.containsKey($lFaultClass))
	{
		foreach ($lDn in $aInSpInfo[$lFaultClass].keys)
		{
			write-Host $lDn ":"
			foreach ($lKey in $global:FAULT_PROPS)
			{
				if ($aInSpInfo[$lFaultClass][$lDn].containsKey($lKey))
				{
					write-Host "`t" $lKey ":" $aInSpInfo[$lFaultClass][$lDn][$lKey]
				}
			}
		}
	}

}




function failOverSp([string] $aInSpDn, [hashtable] $aInSpInfo)
{
	$lPnDn = $aInSpInfo["summary"]["pnDn"]
	Write-Host "Failing over server (" $aInSpDn ")(" $lPnDn ")"

	$lIsBlade = ($lPnDn -like '*blade-*')
		
	# Manually dis-associate service profile - we will associate shortly. 
	# This should be quicker than waiting for system to decomission server.

	Write-Host "Deleting requirement for service profile :"  $aInSpDn  
	Start-UcsTransaction
	Get-UcsServiceProfile -dn $aInSpDn | Disconnect-UcsServiceProfile -force

	# Decomission the physical server 
	if ($lIsBlade)
	{
		Write-Host "Decommissioning blade : "  $lPnDn 
		#Get-UcsBlade -dn $lPnDn | Decommission-UcsBlade -force
		Set-UcsManagedObject -force -XmlTag computeBlade -PropertyMap @{dn = $lPnDn ; lc= "decommission"}
	}
	else
	{
		Write-Host "Decommissioning rack-unit: "  $lPnDn 
		#Get-UcsBlade -dn $lPnDn | Decommission-UcsRackUnit -force
		Set-UcsManagedObject -force -XmlTag computeBlade -PropertyMap @{dn = $lPnDn ; lc= "decommission"}
	}
	Complete-UcsTransaction

	# Now, we want to associate service profile to pool
	$lPoolDn = $aInSpInfo["summary"]["poolDn"]
	$lPoolName = $aInSpInfo["summary"]["poolName"]

	Write-Host "Associating sp ("  $aInSpDn ") with pool (" $lPoolName ")"
	Get-UcsServiceProfile -dn $aInSpDn | Associate-UcsServiceProfile -ServerPoolName $lPoolName -force
}




# 
# Get information on the identified mo
#
function getMoInfo([string] $aInDn, [hashtable] $aInOutSpInfo, [bool] $aInHier, [array] $aInIntClass)
{
	debugPrint "getMoInfo : " $aInDn
        $lOutIdMap = @{}
	if ($aInHier) 
	{
		$lMos = (Get-UcsManagedObject -dn $aInDn -hierarchy)
	}
	else
	{
		$lMos = (Get-UcsManagedObject -dn $aInDn -hierarchy)
	}
	foreach ($lMo in $lMos)
	{
		$lClass = $lMo.getType().fullname
		if ($aInIntClass -contains $lClass)
      		{
			debugPrint "Processing (" $lClass ") (" $lMo.dn ")"
			$lDn = $lMo.dn
			$lMoMap = @{}
			foreach ($lProp in $lMo.PSObject.Properties)
			{
				$lMoMap[$lProp.Name] = $lProp.Value
			}
			addSpInfo $aInOutSpInfo $lClass $lDn $lMoMap
	        	if ($lMo -like "Cisco.Ucs.computePool")
			{
				$lPoolName = $lMo.name
				addSpSummaryInfo $aInOutSpInfo "poolName" $lPoolName
			}
		}
	}
}




# 
# Query the ucs for identity related information.
# Results are stored in an IdMap.
# (IdMap[poolDn][type] = array of id hashtables that describe a block of ids)
#
function querySpInfo([string] $aInSpDn, [hashtable] $aInOutSpInfo, [array] $aInIntClass)
{
	debugPrint "querySpInfo : " $aInSpDn

        $lMos = (Get-UcsServiceProfile -dn $aInSpDn -hierarchy)
	foreach ($lMo in $lMos)
	{
		$lClass = $lMo.getType().fullname
		# Write-Host "Type: " $lClass
		if ($aInIntClass -contains $lClass)
      		{
			debugPrint "Processing (" $lClass ") (" $lMo.dn ")"
			$lDn = $lMo.dn
			$lMoMap = @{}
			foreach ($lProp in $lMo.PSObject.Properties)
			{
				$lMoMap[$lProp.Name] = $lProp.Value;
			}
			addSpInfo $aInOutSpInfo $lClass $lDn $lMoMap

	        	if ($lMo -like "Cisco.Ucs.lsServer")
      			{
				$lName = $lMo.name
				addSpSummaryInfo $aInOutSpInfo "foundSp" "true"
				addSpSummaryInfo $aInOutSpInfo "assignState" $lMo.assignState
				addSpSummaryInfo $aInOutSpInfo "assocState" $lMo.assocState
				addSpSummaryInfo $aInOutSpInfo "type" $lMo.type
				addSpSummaryInfo $aInOutSpInfo "pnDn" $lMo.pnDn
				Write-Host "Found service profile (name=" $lName ")"
			}
	        	if ($lMo -like "Cisco.Ucs.lsRequirement")
			{
				$lPnPoolDn = $lMo.pnPoolDn
				if ($lPnPoolDn.length -gt 0)
				{
					$lHasRequirement = $true
					addSpSummaryInfo $aInOutSpInfo "pooled" "true"
					addSpSummaryInfo $aInOutSpInfo "poolDn" $lMo.pnPoolDn
					addSpSummaryInfo $aInOutSpInfo "availPhysInPool" 0
				}
			}
		}
	}

	# Get information on the physical node
	if ($aInOutSpInfo["summary"]["assignState"] -eq "assigned")
	{
		getMoInfo $aInOutSpInfo["summary"]["pnDn"]  $aInOutSpInfo $true $global:POLL_CLASSES 
	}

	# Get information on the compute pool
	if ($aInOutSpInfo["summary"]["pooled"] -eq "true")
	{
		$lPoolDn = $aInOutSpInfo["summary"]["poolDn"]
		getMoInfo $lPoolDn  $aInOutSpInfo $true $global:POLL_CLASSES 

		if ($aInOutSpInfo.containsKey("Cisco.Ucs.ComputePool") -and
		     $aInOutSpInfo["Cisco.Ucs.ComputePool"].containsKey($lPoolDn))
		{
		     $lSize = [int] $aInOutSpInfo["Cisco.Ucs.ComputePool"][$lPoolDn]["size"]
		     $lAssigned = [int] $aInOutSpInfo["Cisco.Ucs.ComputePool"][$lPoolDn]["assigned"]
		     $lAvail = $lSize - $lAssigned
		     addSpSummaryInfo $aInOutSpInfo "availPhysInPool" $lAvail
		}
	}
}




#
# Read in csv file to global structures
# (checks that necessary fields are present)
# File should have fields (code,name,type)  type is either memory or cpu"
function getFaults([string] $aInFileName)
{
	$lObjs = Import-CSV $aInFileName
	foreach ($lObj in $lObjs)
	{
		$lName = $lObj.name
		$lType = $lObj.type
		$lCode = $lObj.code
		if (($lName.length -gt 0) -and
		    ($lType.length -gt 0) -and
		    ($lCode.length -gt 0))
		{
			if ($lType -like "memory")	
			{
				$global:FAIL_MEMORY_FAULTS[$lCode] = $lName
			}
			elseif ($lType -like "cpu")	
			{
				$global:FAIL_CPU_FAULTS[$lCode] = $lName
			}
			else
			{
				printUsage "Unsupported fault type"
			}
		}
		else
		{
				printUsage "Unsupported fault type"
		}
	}
	return
}




function logout([string] $aInUcs)
{
        # Logout of UCS
        try {
		Write-Host "UCS: Logging out of UCS: $lUcs"
		$ucslogout = Disconnect-Ucs 
	} 
	catch
	{
		# Don't worry about exceptions during logout
		# (should not happen)
		Write-Warning "Caught exception when logging out"
		Write-Warning ([String] ${Error})
		Write-Warning "Ignoring"
	}
}



if ($usage)
{
    printUsage "" 
}

$output = Set-UcsPowerToolConfiguration -SupportMultipleDefaultUcs $false

$global:SIM_MODE=$sim
$global:FAILED_LABEL="SIM FAILURE"

# Classes we are interested in keeping track of
$global:POLL_CLASSES = @(
    "Cisco.Ucs.computeBlade", "Cisco.Ucs.computeRackUnit", "Cisco.Ucs.FaultInst",
    "Cisco.Ucs.MemoryUnit", "Cisco.Ucs.ProcessorUnit",
    "Cisco.Ucs.lsServer", "Cisco.Ucs.lsRequirement", "Cisco.Ucs.lsBinding"
    "Cisco.Ucs.computePool", "Cisco.Ucs.VnicEther", "Cisco.Ucs.VnicFc",
    "Cisco.Ucs.VnicEtherIf", "Cisco.Ucs.VnicFcIf")

# Physical classes we will print out (in order we will display)
$global:SP_PHYS_CLASS = @(
    "Cisco.Ucs.computeBlade", "Cisco.Ucs.computeRackUnit",
    "Cisco.Ucs.MemoryUnit", "Cisco.Ucs.ProcessorUnit")

# Attributes we will print out
$global:SP_PHYS_MAP= @{}
$global:SP_PHYS_MAP["Cisco.Ucs.computeBlade"] = @("operState", "operability", "vendor", "model", "serial", "assignedToDn")
$global:SP_PHYS_MAP["Cisco.Ucs.computeRackUnit"] = @("operState", "operability", "vendor", "model", "serial", "assignedToDn")
$global:SP_PHYS_MAP["Cisco.Ucs.MemoryUnit"] = @( "operState", "operability", "presence", "vendor", "model", "serial", "formFactor", "location") 
$global:SP_PHYS_MAP["Cisco.Ucs.ProcessorUnit"] = @( "operState", "operability", "presence", "vendor", "model", "serial", "speed", "stepping", "cores") 


# Logical classes we will print out (in order we will display)
$global:SP_LOG_CLASS = @("Cisco.Ucs.lsServer", "Cisco.Ucs.lsRequirement", "Cisco.Ucs.lsBinding", 
    "Cisco.Ucs.computePool", "Cisco.Ucs.VnicEther", "Cisco.Ucs.VnicFc",
    "Cisco.Ucs.VnicEtherIf", "Cisco.Ucs.VnicFcIf")

$global:SP_LOG_MAP= @{}
$global:SP_LOG_MAP["Cisco.Ucs.lsServer"] = @("name", "uuid", "pnDn", "type", "operState", "operBiosProfileName", "operBootPolicyName", "operHostFwPolicyName", "operIdentPoolName")
$global:SP_LOG_MAP["Cisco.Ucs.lsRequirement"] = @(  "pnPoolDn")
$global:SP_LOG_MAP["Cisco.Ucs.lsBinding"] = @( "assignedToDn", "computeEpDn" )
$global:SP_LOG_MAP["Cisco.Ucs.computePool"] = @( "size", "assigned")

$global:SP_LOG_MAP["Cisco.Ucs.vnicEther"] = @( "addr", "switchId", "operSpeed" )
$global:SP_LOG_MAP["Cisco.Ucs.vnicEtherIf"] = @( "addr", "switchId")
$global:SP_LOG_MAP["Cisco.Ucs.vnicFc"] = @( "addr", "switchId", "operSpeed" )
$global:SP_LOG_MAP["Cisco.Ucs.vnicFcIf"] = @( "initiator", "switchId")

$global:FAULT_PROPS= @("code", "severity", "lastTransition", "id", "descr", "created", "cause", "rule", "type" )

# Fault codes for memory/cpu
$global:FAIL_MEMORY_FAULTS = @{}
$global:FAIL_CPU_FAULTS= @{}


# Error if there are unknown command line options
if ($disallowunnamed)
{
	printUsage "You have extraneous command line options"
}

Write-Host "Reading faults to monitor from :" $fault
#getFaults $fault

${lUcsCred} = Get-Credential

while ($true)
{
	try 
	{
		${myCon} = Connect-Ucs -Name $ucsip -Credential ${lUcsCred} -ErrorAction SilentlyContinue
	
		# Get id information for each of the pools
		Write-Host "Calling to get service profile information"
       		$lSpInfoMap = @{}
		addSpSummaryInfo $lSpInfoMap "foundSp" "false"
		querySpInfo $spDn $lSpInfoMap $global:POLL_CLASSES 

		printSpInfo "SP Summary Information :" $lSpInfoMap
	
		Write-Host "Checking fail-over "
		$lFailOver = shouldFailOver $spdn $lSpInfoMap
		if ($lFailOver)
		{
			failOverSp $spDn $lSpInfoMap
		}
	}
	catch
	{ 
		Write-Error "Caught error during info gathering"
		Write-Error ([String] ${Error})
		Write-Error "Continuing"
	}
	finally
	{
			logout	$ucsip
	}

	# Get id information for each of the pools
	$lDate = Get-Date
	Write-Host $lDate
	Write-Host "Sleeping for " $poll " seconds"
	Start-Sleep -s $poll
}




