#
# Ike Kent
# MigrateUCS-Identity <ucs>
# MigrateUCS-Identity for usage message.
#
# 
# The MigrateUCS-Identity will combine UCS identity pools from various sources and generate an xml configuration
# that can be posted to UCS central.  The sources will typically be UCS systems but, can also be CSV files 
# (perhaps created a previous run of this script). A number of files are created by the script - however, the
# most important is the XML command file that can be posted to UCS central.  
# 
#
# Generated Files
# Log file (for debuging only)                 : migrate.log
# CSV file with merged ids                     : migrate.csv
# XML file that contains UCS central commands: : migrate.xml
# CSV id file for each ucs system              : <system-ip>-ids.csv (with -cvsperucs flag)
#
#
# Supported otions:
# 
# -keepuuidprefix                                - the uuid prefix is cleared (set to all zeros) by default for 
#                                                  uuid pools.  This option preserves the prefix.
# -csvperucs 			                 - create a csv file for each ucs system (for archive purposes).
# -overwrite                                     - over-write existing files if they exist
# -logFile <log-filename>                        - set the logfilename (default is migrate.log)
# -commandFile <command-filename>                - set the command-filename (default is migrate.xml)
# -outIdFile <out-id-filename>  	         - set the csv filename for the merged identities
# -inIdFiles <in-id-filename>[,<in-id-filename>] - list of csv files to merge
# -ucsips <ucs-ip>[,<ucs-ip>]                    - list of ucs ip addresses
#
#
# Typical Usage:
#  
# Example 1: 
# To merge the identities of two ucs systems, over-writing files (with same name) and
# creating csv files describing ids each ucs system (for archival purposes):
# 
# MigrateUCS-Identity.ps1 -overwrite -ucs 10.29.141.18,10.29.141.21 -csvperucs 
# 
# 
# Example 2: 
# To merge the identities from two ucs systems and two csv files, over-writing files (with same name)
#
# MigrateUCS-Identity.ps1 -overwrite -ucs 10.29.141.18,10.29.141.21 -idFiles 10.29.141.33-ids.csv,10.29.141.36-ids.csv  -csvperucs 
# 
#
# Details:
# Where possible, the script attempts to combine the identities from various sources with-out any modification.  
# However, this is not always possible due to name conflicts or over-lapping blocks.  Below, we list some scenarios
# where the data must be massaged in order to have a valid configuration.
# 
# i) Uuid pools with the distinguished name but different prefixes will be renamed.   The new name will contain the  
#    suffix "-RENAME".  A warning message is printed if this happens.
# ii) IQN pools with the distinguished name but different prefixes will be renamed.   The new name will contain the  
#    suffix "-RENAME".  A warning message is printed if this happens.
# iii) Any over-lapping identity blocks in a pool will be combined to create a new compound block;
# iv) Since the maximum UCS block size is 1000 identities, any blocks with > 1000 identities will be broken down 
#     into multiple blocks.  
# v) WWN pools with the same name but different purposes will be renamed.  WWN node and port pools will be renamed with
#    suffix "-RENAME_NP".  WWN node pools will be renamed "-RENAME_NODE".  WWN port pools will not be renamed.
# vi) When pools with different assignment order are merged, a warning message is printed;
# vii) Ip pools can be merged, however, a warning message will be printed if blocks in the pool have different
#      primary dns, secondary dns, subnet or default gateway.
#




# 
# We use an IdMap structure to organize the blocks. 
# IdMap[poolDn][type] = array of hashtables that describe an identity block.
# The type is one of ["ippool", "wwpnpool" "wwnnpnpool", "wwnnpool", "uuidpool", "macpool"]
# 



#
# Command Line parameters
#

[CmdletBinding()]
Param(
	$disallowunnamed,
	[switch] $csvperucs,
	[switch] $keepuuidprefix,
	[switch] $overwrite,
	[string] $logFile,
	[string] $commandFile,
	[string] $outIdFile,
	[string[]] $inIdFiles,
	[string[]] $ucsips
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
	Write-Host "     MigrateUcsIdentity [-csvperucs] [-keepuuidprefix] [ucsSystem]"
	Write-Host ""
	Write-Host "Supported Options:"
	Write-Host "	-keepuuidprefix - the uuid prefix is cleared (set to all zeros) by default for "
	Write-Host "                      uuid pools.  This option preserves the prefix."
	Write-Host "	-csvperucs            - create a csv file for each ucs system (for archive purposes)."
	Write-Host "	-overwrite            - over-write existing files if they exist"
        Write-Host "	-inIdFiles <fname>[,<fname>] - list of csv files to merge"
        Write-Host "	-ucsips <ucs-ip>[,<ucs-ip>] - list of ucs ip addresses"
        Write-Host "	-logFile <fname>      - set the logfilename (default is migrate.log)"
	Write-Host "	-commandFile <fname>  - set the command-filename (default is migrate.xml)"
        Write-Host "	-outIdFile <fname>    - set the csv filename for the merged identities"
	Write-Host ""
	Write-Host "Examples:"
	Write-Host ""
	Write-Host "To migrate identities from 2 ucs systems;  Overwrite files."
	Write-Host "	MigrateUcsIdentity -csvperucs -ucs 10.29.141.18,10.29.141.21 -overwrite"
	Write-Host ""
	Write-Host "To migrate identities from 2 ucs files;  Overwrite files."
	Write-Host "	MigrateUcsIdentity -csvperucs -inIdFiles 10.29.141.18-ids.csv,10.29.141.21-ids.csv -overwrite"
	Write-Host ""
	Write-Host "To migrate identities from 2 ucs systems and 2 id files; Generate csv files for each system;  Overwrite files "
	Write-Host "	MigrateUcsIdentity -csvperucs -ucs 10.29.141.18,10.29.141.21 -inIdFiles 10.29.141.44-ids.csv,10.29.141.31-ids.csv -overwrite"
	Write-Host ""
	exit
}




# 
# Case sensitive hashtable
# 
function New-CHashTable
{
	New-Object Collections.Hashtable ([StringComparer]::CurrentCulture)
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
			$lMsg > $logFile
			Write-Verbose $lMsg
		}
		$aInMsg >> $logFile
		Write-Verbose $aInMsg
}



# 
# Get array of DNs in hierarchy of passed DN
# 
function getDns([string] $aInDn)
{
	$lRns = $aInDn.split("/")
	$lDnArray = @()
	$lDn = ""
	for ($i=0; $i -lt  $lRns.length; $i++)
	{
            if ($i -ne 0)
	    {
	        $lDn = $lDn + "/"
        }
        $lDn = $lDn + $lRns[$i] 
	    $lDnArray += $lDn
	}
	return ,$lDnArray
}



# 
# Get list of orgs for passed dn
# 
function getOrgs([string] $aInOrg)
{
	$lRns = $aInOrg.split("/")
	$lDnArray = @()
	$lDn = ""
	for ($i=0; $i -lt  $lRns.length; $i++)
	{
		if ($lRns[$i] -match "^org-.*")
		{
			if ($i -ne 0)
			{
				$lDn = $lDn + "/"
			}
			$lDn = $lDn + $lRns[$i] 
			$lDnArray += $lDn
		}
	}

	# foreach ($lOrg in $lDnArray){ debugPrint "getOrgs returning :  " $lOrg}

	return ,$lDnArray
}


# 
# Get the passed dn's org
# 
function getOrg([string] $aInDn)
{
	$lOrgs += getOrgs $aInDn
	$lOutOrg = $lOrgs[$lOrgs.length-1]
	# debugPrint "getOrg (" $aInDn ")(" $lOutOrg ")"
}



# 
# Convert mac to 64 bit unsigned int
#
function macToInt([string] $aInMac)
{
	$lPairs = $aInMac.split(":") 
	$lMacString = ""
	foreach ($lPair in $lPairs)
	{
		$lMacString = $lMacString + $lPair
	}
	$lMacInt = [System.Convert]::ToUInt64($lMacString,16)

	# debugPrint "macToInt (" $aInMac ") (" $lMacInt ")"

	return $lMacInt
}



# 
# Convert ip to 32 bit unsigned int
#
function ipToInt([string] $aInIp)
{
	# Ip address
	$lIpInt = [uint32] 0
	$lQuads = $aInIp.split(".") 
	if ($lQuads.length -eq 4)
	{
		$lIpInt += [System.Convert]::ToUInt32($lQuads[3],10)
		$lIpInt += [System.Convert]::ToUInt32($lQuads[2],10) * ([uint32] 256)
		$lIpInt += [System.Convert]::ToUInt32($lQuads[1],10) *  ([uint32] 256) *  ([uint32] 256)
		$lIpInt += [System.Convert]::ToUInt32($lQuads[0],10) *  ([uint32] 256) *  ([uint32] 256) * ([uint32] 256)
	}

	# debugPrint "ipToInt (" $aInIp ") (" $lIpInt ")"

	return $lIpInt
}



# 
# Convert wwn to 64 bit unsigned int
#
function wwnToInt([string] $aInWwn)
{
	$lPairs = $aInWwn.split(":") 
	$lWwnString = ""
	foreach ($lPair in $lPairs)
	{
		$lWwnString = $lWwnString + $lPair
	}
	$lWwnInt = [System.Convert]::ToUInt64($lWwnString,16)

	# debugPrint "wwnToInt (" $aInWwn ") (" $lWwnInt")"

	return $lWwnInt
}



# 
# Convert a 64 bit unsigned int to a wwn string
#
function wwnToString([uint64] $aInWwnInt)
{
    	# The wwn is of the form: 20:00:00:25:B5:00:23:AA

	$lWwnStr = "{0:X}" -f $aInWwnInt
	$lWwnStr = ('0' * (16 - $lWwnStr.length)) + $lWwnStr
	for ($i = 2; $i -lt 22; $i += 3)
	{
		$lWwnStr = $lWwnStr.insert($i, ":")
	}

    	# debugPrint "wwnToString(" $lWwnStr ") (" $aInWwnInt ")"

	return $lWwnStr
}




# 
# Convert a 64 bit unsigned int to a mac string
#
function macToString([uint64] $aInMacInt)
{
        # The mac string should be of the form : 00:22:B5:00:01:09

	$lMacStr = "{0:X}" -f $aInMacInt
	$lMacStr = ('0' * (12 - $lMacStr.length)) + $lMacStr
	for ($i = 2; $i -lt 15; $i += 3)
	{
		$lMacStr = $lMacStr.insert($i, ":")
	}

    	# debugPrint "macToString(" $lMacStr ") (" $aInMacInt ")"

	return $lMacStr
}



# 
# Convert a 32 bit unsigned int to an ip string
#
function ipToString([uint32] $aInIpInt)
{
	# debugPrint "ipToString (" $aInIpInt ")"

        # Output the ip in the dotted quad format : w.x.y.z
	# Powershell does not truncate on division!
        $lIp = ""
	$lZ = $aInIpInt -band 0xFF

	$lY = [uint32] [Math]::Truncate($aInIpInt / 256) -band 0xFF
	$lX = [uint32] [Math]::Truncate($aInIpInt / 65536) -band  0xFF
	$lW = [uint32] [Math]::Truncate($aInIpInt / 16777216) -band 0xFF
	$lIp = ([string] $lW) + "." + ([string] $lX) + "." + ([string] $lY) + "." + ([string] $lZ)

	# debugPrint "ipToString (" $lIp ") (" $aInIpInt ")"
	return $lIp
}



# 
# Convert a 64 bit unsigned int to a uuid string
#
function uuidToString([uint64] $aInInt)
{
	$lHexStr = "{0:X}" -f $aInInt
	$lHexStr = ('0' * (16 - $lHexStr.length)) + $lHexStr

	$lUuidStr = $lHexStr.subString(0,4) + "-" +  $lHexStr.subString(4,12) 

    	# debugPrint "uuidToString (=" $aInInt ") (" $lUuidStr ")"

	return $lUuidStr
}



# 
# Get the uuid attributes (64 bit integers) from a passed block dn or rn
#
function parseUuidBlockRn([string] $aInUuidRange, [ref] $aOutFrom, [ref] $aOutTo)
{
        # The uuid attributes is of the form: block-from-9999-123456789012-to-

        if ($aInUuidRange -match "/block\-from\-([A-F0-9]{4})\-([A-F0-9]{12})\-to\-([A-F0-9]{4})\-([A-F0-9]{12})")
        {
                $lFromStr = $matches[1] + $matches[2]
                $lToStr = $matches[3] + $matches[4]

                $aOutFrom.Value = [System.Convert]::ToUInt64($lFromStr,16)
                $aOutTo.Value = [System.Convert]::ToUInt64($lToStr,16)
	        # debugPrint "parseUuidBlockRn (" $aInUuidRange ")(from=" $aOutFrom.Value ")(to=" $aOutTo.Value ")"
                return
        }
        Write-Error "Error the uuid rn is not of the expected form : " $aInUuidRange
	Write-Error "     Exiting"
	exit
}



# 
# Get the iqn attributes (64 bit integers) from a passed block dn or rn
#
function parseIqnBlockRn([string] $aInIqnRange, [ref] $aOutSuffix, [ref] $aOutFrom, [ref] $aOutTo)
{
        # The iqn attributes is of the form: block-bill-from-9-to-12

        if ($aInIqnRange -match "/block\-(.*)\-from-([0-9]{0,4})\-to\-([0-9]{0,4})")
        {
                $lFromStr = $matches[2] 
                $lToStr = $matches[3] 

                $aOutSuffix.Value = $matches[1] 
                $aOutFrom.Value = [System.Convert]::ToUInt64($lFromStr,10)
                $aOutTo.Value = [System.Convert]::ToUInt64($lToStr,10)
	        # debugPrint "parseIqnBlockRn (" $aInIqnRange ")(suffix=" $aOutSuffix.Value ")(from=" $aOutFrom.Value ")(to=" $aOutTo.Value ")"
                return
        }
        Write-Error "Error the iqn rn is not of the expected form : " $aInIqnRange
	Write-Error "     Exiting"
	exit
}



# 
# Get the mac attributes (64 bit integers) from a passed block dn or rn
#
function parseMacBlockRn([string] $aInMacRange, [ref] $aOutFrom, [ref] $aOutTo)
{
        # The mac attributes is of the form: block-00:22:B5:00:01:09-00:25:B5:00:01:11

        if ($aInMacRange -match "/block\-([A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2})\-([A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2})")
        {
                $lFromStr = $matches[1]
                $lToStr = $matches[2]
                $aOutFrom.Value = macToInt $lFromStr
                $aOutTo.Value = macToInt $lToStr
		debugPrint "parseMacBlockRn (" $aInMacRange ")(from=" $aOutFrom.Value ")(to=" $aOutTo.Value ")"
    		return
        }
	Write-Error "Error the mac rn is not of the expected form : "  $aInMacRange
	Write-Error "     Exiting"
	exit
}



# 
# Get the ip attributes (32 bit integers) from a passed block dn or rn
#
function parseIpBlockRn([string] $aInIpRange, [ref] $aOutFrom, [ref] $aOutTo)
{
        if ($aInIpRange -match "/block\-([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\-([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})")
        {
                $lFromStr = $matches[1]
                $lToStr = $matches[2]
                $aOutFrom.Value = ipToInt $lFromStr
                $aOutTo.Value = ipToInt $lToStr
		debugPrint "parseIpBlockRn (" $aInIpRange ")(from=" $aOutFrom.Value ")(to=" $aOutTo.Value ")"
		return 
        }
	Write-Error "Error the ip rn is not of the expected form : "  $aInIpRange
	Write-Error "     Exiting"
	exit
}



# 
# Get the wwn attributes (64 bit integers) from a passed block dn or rn
#
function parseWwnBlockRn([string] $aInWwnRange, [ref] $aOutFrom, [ref] $aOutTo)
{
        # The wwn rn is of the form: block-00:22:B5:00:01:09:01:02-00:25:B5:00:01:11:01:02

        if ($aInWwnRange -match "/block\-([A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2})\-([A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2}:[A-F0-9]{2})")
        {
                $lFromStr = $matches[1]
                $lToStr = $matches[2]
                $aOutFrom.Value = wwnToInt $lFromStr
                $aOutTo.Value = wwnToInt $lToStr
		debugPrint "parseWwnBlockRn (" $aInWwnRange " )(from=" $aOutFrom.Value ")(to=" $aOutTo.Value ")"
		return
        }
	Write-Error "Error the wwn rn is not of the expected form : "  $aInWwnRange
	Write-Error "     Exiting"
	exit
}



# 
# Update the block dn (fields "block" and "poolDn") contained in the passed hashtable that describes an id block.
# The "to","from", and "type" fields are used to construct the dn.
# 
function updateBlockId([hashtable] $aInIdMap)
{
	debugPrint "updateBlockId(from=" $aInIdMap["from"] ")(to=" $aInIdMap["to"] ")"

	$lBlockRn = ""
	$lType = $aInIdMap["type"]
	if ($lType -like "macpool")
	{
		$lBlockRn = getMacBlockRn $aInIdMap["from"] $aInIdMap["to"]
	}
	elseif ($lType -like "wwnnpnpool")
	{
		$lBlockRn = getWwnBlockRn $aInIdMap["from"] $aInIdMap["to"]
	}
	elseif ($lType -like "wwnnpool")
	{
		$lBlockRn = getWwnBlockRn $aInIdMap["from"] $aInIdMap["to"]
	}
	elseif ($lType -like "wwpnpool")
	{
		$lBlockRn = getWwnBlockRn $aInIdMap["from"] $aInIdMap["to"]
	}
	elseif ($lType -like "uuidpool")
	{
		$lBlockRn = getUuidBlockRn $aInIdMap["from"] $aInIdMap["to"] 
	}
	elseif ($lType -like "iqnpool")
	{
		$lBlockRn = getIqnBlockRn $aInIdMap["suffix"] $aInIdMap["from"] $aInIdMap["to"] 
	}
	elseif ($lType -like "ippool")
	{
		$lBlockRn = getIpBlockRn $aInIdMap["from"] $aInIdMap["to"] 
	}
	$lBlockDn = $aInIdMap["poolDn"] + "/" + $lBlockRn 

	$aInIdMap["block"] = $lBlockDn

	debugPrint "updateBlockId(" $aInIdMap["block"] ")" 
}



# 
# Construct a uuid block rn based on the passed attributes.
#
function getUuidBlockRn([uint64] $aInFrom, [uint64] $aInTo)
{
	$lFrom = uuidToString $aInFrom
	$lTo = uuidToString $aInTo
	$lBlockRn = "block-" + $lFrom + "-" + $lTo 

	# debugPrint "getUuidBlockRn (" $aInFrom ")(" $aInTo ")(" $lBlockRn ")"

	return $lBlockRn
}



# 
# Construct a iqn block rn based on the passed id attributes.
#
function getIqnBlockRn([string] $aInSuffix, [uint64] $aInFrom, [uint64] $aInTo)
{
	$lBlockRn = "block-" + $aInSuffix + "-from-" + $aInFrom + "-to-" + $aInTo 
	# debugPrint "getIqnBlockRn (" $aInSuffix ")(" $aInFrom ")(" $aInTo ")(" $lBlockRn ")"
	return $lBlockRn
}



# 
# Construct a mac block rn based on the passed id attributes.
#
function getMacBlockRn([uint64] $aInFrom, [uint64] $aInTo)
{
        # The mac rn is of the form: block-00:22:B5:00:01:09-00:25:B5:00:01:11
	$lFrom = macToString $aInFrom
	$lTo = macToString $aInTo
	$lBlockRn = "block-" + $lFrom + "-" + $lTo 

	# debugPrint "getMacBlockRn (" $aInFrom ")(" $aInTo ")(" $lBlockRn ")"

	return $lBlockRn
}




# 
# Construct an ip block rn based on the passed id attributes.
#
function getIpBlockRn([uint32] $aInFrom, [uint32] $aInTo)
{
        # The ip rn is of the form: block-128.129.141.5-128.129.141.6
	$lFrom = ipToString $aInFrom
	$lTo = ipToString $aInTo
	$lBlockRn = "block-" + $lFrom + "-" + $lTo 

	# debugPrint "getIpBlockRn (" $aInFrom ")(" $aInTo ")(" $lBlockRn ")"

	return $lBlockRn
}



# 
# Construct a wwn block rn based on the passed id attributes.
#
function getWwnBlockRn([uint64] $aInFrom, [uint64] $aInTo)
{
        # The wwn rn is of the form: block-00:22:B5:00:01:09:01:02-00:25:B5:00:01:11:01:02
	$lFrom = wwnToString $aInFrom
	$lTo = wwnToString $aInTo
	$lBlockRn = "block-" + $lFrom + "-" + $lTo 

	debugPrint "getWwnBlockRn (" $aInFrom ")(" $aInTo ")(" $lBlockRn ")"

	return $lBlockRn
}



# 
# Parse wwn block dn and return properties in a hashtable.
#
function parseWwnBlockDn([string] $aInBlockDn)
{
	$lFrom = [uint64] 0
	$lTo = [uint64] 0
	parseWwnBlockRn $aInBlockDn ([ref]$lFrom) ([ref] $lTo)

	$lDnArray = getDns $aInBlockDn
	$lOrgDn = $lDnArray[$lDnArray.length-3]
	$lPoolDn = $lDnArray[$lOrgArray.length-2]

	$lRnArray = $aInBlockDn.split("/")
	$lPoolRn = $lRnArray[$lRns.length-2]
	$lOrgRn = $lRnArray[$lRns.length-3]

	$lMatch = $lOrgRn -match "org-(.*)$"
	$lOrgName = $matches[1]

	$lMatch = $lPoolRn -match "wwn-pool-(.*)$"
	$lPoolName = $matches[1]

	$lOutBlockHash = @{ 
		"block" = $aInBlockDn;
		"orgName" = $lOrgName;
		"orgDn" = $lOrgDn;
		"from" = $lFrom; 
		"to" = $lTo;
		"poolDn" = $lPoolDn;
		"poolName" = $lPoolName
	}
	# For debug only
	# printIdMap "parsed wwn block" $lOutBlockHash
 
    return $lOutBlockHash
}




# 
# Parse mac block dn and return properties in a hashtable.
#
function parseMacBlockDn([string] $aInBlockDn)
{
	$lFrom = [uint64] 0
	$lTo = [uint64] 0
	parseMacBlockRn $aInBlockDn ([ref]$lFrom) ([ref] $lTo)

	$lDnArray = getDns $aInBlockDn

	$lOrgDn = $lDnArray[$lDnArray.length-3]
	$lPoolDn = $lDnArray[$lOrgArray.length-2]
	$lOrgDn = $lDnArray[$lDnArray.length-3]

	$lRnArray = $aInBlockDn.split("/")
	$lPoolRn = $lRnArray[$lRns.length-2]
	$lOrgRn = $lRnArray[$lRns.length-3]

	$lMatch = $lOrgRn -match "org-(.*)$"
	$lOrgName = $matches[1]

	$lMatch = $lPoolRn -match "mac-pool-(.*)$"
	$lPoolName = $matches[1]

	$lOutBlockHash = @{ 
	        "block" = $aInBlockDn;
        	"orgName" = $lOrgName;
		"orgDn" = $lOrgDn;
		"from" = $lFrom; 
		"to" = $lTo;
		"poolDn" = $lPoolDn;
		"poolName" = $lPoolName
	}

	# For debug only
	# printIdMap "parsed mac block" $lOutBlockHash
 
	return $lOutBlockHash
}



# 
# Parse uuid block dne and return properties in a hashtable.
#
function parseUuidBlockDn([string] $aInBlockDn)
{
	$lFrom = [uint64] 0
	$lTo = [uint64] 0

	parseUuidBlockRn $aInBlockDn ([ref]$lFrom) ([ref] $lTo)

	$lDnArray = getDns $aInBlockDn

	$lOrgDn = $lDnArray[$lDnArray.length-3]
	$lPoolDn = $lDnArray[$lOrgArray.length-2]
	$lOrgDn = $lDnArray[$lDnArray.length-3]

	$lRnArray = $aInBlockDn.split("/")
	$lPoolRn = $lRnArray[$lRns.length-2]
	$lOrgRn = $lRnArray[$lRns.length-3]

	$lMatch = $lOrgRn -match "org-(.*)$"
	$lOrgName = $matches[1]

	$lMatch = $lPoolRn -match "uuid-pool-(.*)$"
	$lPoolName = $matches[1]

	$lOutBlockHash = @{ 
	        "block" = $aInBlockDn;
       		"orgName" = $lOrgName;
		"orgDn" = $lOrgDn;
		"from" = $lFrom; 
		"to" = $lTo;
		"poolDn" = $lPoolDn;
		"poolName" = $lPoolName
	}

	# For debug only
	# printIdMap "parsed uuid block" $lOutBlockHash
    return $lOutBlockHash
}



# 
# Parse iqn block dne and return properties in a hashtable.
#
function parseIqnBlockDn([string] $aInBlockDn)
{
	$lFrom = [uint64] 0
	$lTo = [uint64] 0
	$lSuffix = ""

	parseIqnBlockRn $aInBlockDn ([ref] $lSuffix) ([ref]$lFrom) ([ref] $lTo)

	$lDnArray = getDns $aInBlockDn

	$lOrgDn = $lDnArray[$lDnArray.length-3]
	$lPoolDn = $lDnArray[$lOrgArray.length-2]
	$lOrgDn = $lDnArray[$lDnArray.length-3]

	$lRnArray = $aInBlockDn.split("/")
	$lPoolRn = $lRnArray[$lRns.length-2]
	$lOrgRn = $lRnArray[$lRns.length-3]

	$lMatch = $lOrgRn -match "org-(.*)$"
	$lOrgName = $matches[1]

	$lMatch = $lPoolRn -match "iqn-pool-(.*)$"
	$lPoolName = $matches[1]

	$lOutBlockHash = @{ 
	        "block" = $aInBlockDn;
       		"suffix" = $lSuffix;
       		"orgName" = $lOrgName;
		"orgDn" = $lOrgDn;
		"from" = $lFrom; 
		"to" = $lTo;
		"poolDn" = $lPoolDn;
		"poolName" = $lPoolName
	}

	# For debug only
	# printIdMap "parsed iqn block" $lOutBlockHash
    return $lOutBlockHash
}



# 
# Parse ip block dn and return properties in a hashtable.
#
function parseIpBlockDn([string] $aInBlockDn)
{
	$lFrom = [uint32] 0
	$lTo = [uint32] 0

	parseIpBlockRn $aInBlockDn ([ref]$lFrom) ([ref] $lTo)

	$lDnArray = getDns $aInBlockDn

	$lOrgDn = $lDnArray[$lDnArray.length-3]
	$lPoolDn = $lDnArray[$lOrgArray.length-2]
	$lOrgDn = $lDnArray[$lDnArray.length-3]

	$lRnArray = $aInBlockDn.split("/")
	$lPoolRn = $lRnArray[$lRns.length-2]
	$lOrgRn = $lRnArray[$lRns.length-3]

	$lMatch = $lOrgRn -match "org-(.*)$"
	$lOrgName = $matches[1]

	$lMatch = $lPoolRn -match "ip-pool-(.*)$"
	$lPoolName = $matches[1]

	$lOutBlockHash = @{ 
		"block" = $aInBlockDn;
		"orgName" = $lOrgName;
		"orgDn" = $lOrgDn;
		"from" = $lFrom; 
		"to" = $lTo;
		"poolDn" = $lPoolDn;
		"poolName" = $lPoolName
    	}

	# For debug only
	# printIdMap "parsed ip block" $lOutBlockHash
 
 
	return $lOutBlockHash
}



#
# Generate configuration xml for the passed identity map.
#
function generateCommands([hashtable] $aInIdMap, [string] $aInFilename)
{
	$lReqOrgs = @()
        $lPoolXml = "";
	$lIndent = 6

        # Sort by org count then name
	foreach ($lPoolItem in $aInIdMap.GetEnumerator() | Sort-Object -caseSensitive { [regex]::matches($_.Name, "org-").count},{ $_.Name })
	{
		$lPoolDn = $lPoolItem.Key
		$lReqOrgs += getOrgs $lPoolDn
 		foreach ($lTypeItem in $aInIdMap[$lPoolDn].GetEnumerator() | Sort-Object Name )
		{
			$lType = $lTypeItem.Key
			$lIndentStr = ' ' * $lIndent
			$lIdArray = $aInIdMap[$lPoolDn][$lType]
			
			if ($lType -like "uuidpool")
			{
				$lPoolXml += $lIndentStr + '<pair key="' + $lPoolDn  + '"' + ">" + "`n"
				$lPoolXml += getCreateUuidPoolXml ($lIndent+3) $lIdArray
				$lPoolXml += $lIndentStr + '</pair>' + "`n"
			} 
			elseif ($lType -like "iqnpool")
			{
				$lPoolXml += $lIndentStr + '<pair key="' + $lPoolDn  + '"' + ">" + "`n"
				$lPoolXml += getCreateIqnPoolXml ($lIndent+3) $lIdArray
				$lPoolXml += $lIndentStr + '</pair>' + "`n"
			}
			elseif ($lType -like "macpool")
			{
				$lPoolXml += $lIndentStr + '<pair key="' + $lPoolDn  + '"' + ">" + "`n"
				$lPoolXml += getCreateMacPoolXml ($lIndent+3) $lIdArray
				$lPoolXml += $lIndentStr + '</pair>' + "`n"
			}
			elseif ($lType -like "ippool")
			{
				$lPoolXml += $lIndentStr + '<pair key="' + $lPoolDn  + '"' + ">" + "`n"
				$lPoolXml += getCreateIpPoolXml ($lIndent+3) $lIdArray
				$lPoolXml += $lIndentStr + '</pair>' + "`n"
			}
			elseif ($lType -like "wwnnpnpool")
			{
				$lPoolXml += $lIndentStr + '<pair key="' + $lPoolDn  + '"' + ">" + "`n"
				$lPoolXml += getCreateWwnPoolXml ($lIndent+3) $lIdArray
				$lPoolXml += $lIndentStr + '</pair>' + "`n"
			}
			elseif ($lType -like "wwpnpool")
			{
				$lPoolXml += $lIndentStr + '<pair key="' + $lPoolDn  + '"' + ">" + "`n"
				$lPoolXml += getCreateWwnPoolXml ($lIndent+3) $lIdArray
				$lPoolXml += $lIndentStr + '</pair>' + "`n"
			}
			elseif ($lType -like "wwnnpool")
			{
				$lPoolXml += $lIndentStr + '<pair key="' + $lPoolDn  + '"' + ">" + "`n"
				$lPoolXml += getCreateWwnPoolXml ($lIndent+3) $lIdArray
				$lPoolXml += $lIndentStr + '</pair>' + "`n"
			}
		}
	}

	$lMethodXml += '<configConfMos cookie="REPLACE_COOKIE">' + "`n"
	$lMethodXml += '   <inConfigs>' + "`n"


        $lOrgXml = "";
	$lReqOrgs = $lReqOrgs | select -uniq | sort
	foreach ($lOrgDn in $lReqOrgs)
	{
		if ("org-root".compareTo($lOrgDn) -ne 0)
		{
			$lIndentStr = ' ' * $lIndent
			$lOrgXml += $lIndentStr + '<pair key="' + $lOrgDn  + '"' + ">" + "`n"
			$lOrgXml += getCreateOrgXml ($lIndent+3) $lOrgDn 
			$lOrgXml += $lIndentStr + '</pair>' + "`n"
		}
        }


	$lMethodXml += $lOrgXml + $lPoolXml

	$lMethodXml += '   </inConfigs>' + "`n"
	$lMethodXml += '</configConfMos>' + "`n"

	$lMethodXml | out-File -encoding ASCII $aInFilename
}


#
# Generate configuration xml for org 
#
function getCreateOrgXml([int] $aInIndent, [string] $aInOrgDn)
{
	$lRnArray = $lOrgDn.split("/")
	$lLastRn = $lRnArray[$lRns.length-1]
	$lMatch = $lLastRn -match "org-(.*)$"
	$lOrgName = $matches[1]

	$lXml = ""
	$lIndentStr = ' ' * $aInIndent
	$lStatus = 'created,modified'
	$lXml += $lIndentStr + '<orgOrg ' 
	$lXml += 'dn="' + $aInOrgDn + '" ' + 'name="' + $lOrgName + '"' + ' status="' + $lStatus + '"'
	$lXml += '/>' + "`n"
	return $lXml
}



#
# Generate configuration xml for an uuid pool.  
# Blocks of the uuid pool are described by the passed array of block hashtables.
#
function getCreateUuidPoolXml([int] $aInIndent, [array] $aInIdArray)
{
	$lXml = ""
	$lFirstBlock = $true

	foreach ($lBlockMap in $aInIdArray | Sort-Object { ([uint64] $_.from )})
	{
		if ($lFirstBlock)	
		{
			$lFirstBlock = $false
			$lIndentStr = ' ' * $aInIndent
			$lXml += $lIndentStr + '<uuidpoolPool ' 
			$lAttrMap = @{"poolDn" = "dn" ; "poolName" = "name";  "assignmentOrder" = "assignmentOrder" }
			$lPrefix= $lBlockMap["prefix"]
			foreach ($lKey in $lAttrMap.keys)
			{
				$lXml += ' ' + $lAttrMap[$lKey] + '=' + '"' + $lBlockMap[$lKey] +  '"'
			}
			$lXml += ' prefix="' + $lPrefix + '"'
			$lXml += '>' + "`n"
		}
		$lIndentStr = ' ' * ($aInIndent +3)
		$lFrom = uuidToString $lBlockMap["from"] 
		$lTo = uuidToString $lBlockMap["to"] 
		$lXml += $lIndentStr + '<uuidpoolBlock '
		$lXml += ' from="' + $lFrom + '" to="' + $lTo + '"'
		$lXml += '/>' + "`n"
	}

	if (!$lFirstBlock)
	{
		$lIndentStr = ' ' * $aInIndent 
		$lXml += $lIndentStr +  '</uuidpoolPool>' + "`n"
	}
	return $lXml
}




#
# Generate configuration xml for an iqn pool.  
# Blocks of the iqn pool are described by the passed array of block hashtables.
#
function getCreateIqnPoolXml([int] $aInIndent, [array] $aInIdArray)
{
	$lXml = ""
	$lFirstBlock = $true

	foreach ($lBlockMap in $aInIdArray | Sort-Object { ([uint64] $_.from )})
	{
		if ($lFirstBlock)	
		{
			$lFirstBlock = $false
			$lIndentStr = ' ' * $aInIndent
			$lXml += $lIndentStr + '<iqnpoolPool ' 
			$lAttrMap = @{"poolDn" = "dn" ; "poolName" = "name";  "assignmentOrder" = "assignmentOrder" }
			$lPrefix= $lBlockMap["prefix"]
			foreach ($lKey in $lAttrMap.keys)
			{
				$lXml += ' ' + $lAttrMap[$lKey] + '=' + '"' + $lBlockMap[$lKey] +  '"'
			}
			$lXml += ' prefix="' + $lPrefix + '"'
			$lXml += '>' + "`n"
		}
		$lIndentStr = ' ' * ($aInIndent +3)
		$lFrom = $lBlockMap["from"] 
		$lTo = $lBlockMap["to"] 
		$lSuffix = $lBlockMap["suffix"] 
		$lXml += $lIndentStr + '<iqnpoolBlock '
		$lXml += ' from="' + $lFrom + '" to="' + $lTo + '"'
		$lXml += ' suffix="' + $lSuffix + '"'
		$lXml += '/>' + "`n"
	}

	if (!$lFirstBlock)
	{
		$lIndentStr = ' ' * $aInIndent 
		$lXml += $lIndentStr +  '</iqnpoolPool>' + "`n"
	}
	return $lXml
}


#
# Generate configuration xml for an mac pool.  
# Blocks of the mac pool are described by the passed array of block hashtables.
#
function getCreateMacPoolXml([int] $aInIndent, [array] $aInIdArray)
{
	$lXml = ""
	$lFirstBlock = $true
	foreach ($lBlockMap in $aInIdArray | Sort-Object {([uint64]$_.from) })
	{
		if ($lFirstBlock)	
		{
			$lFirstBlock = $false
			$lIndentStr = ' ' * $aInIndent
			$lXml += $lIndentStr + '<macpoolPool ' 
			$lAttrMap = @{"poolDn" = "dn" ; "poolName" = "name"; "assignmentOrder" = "assignmentOrder" }
			foreach ($lKey in $lAttrMap.keys)
			{
				$lXml += ' ' + $lAttrMap[$lKey] + '=' + '"' + $lBlockMap[$lKey] +  '"'
			}
			$lXml += '>' + "`n"
		}
		$lIndentStr = ' ' * ($aInIndent +3)
		$lFrom = macToString $lBlockMap["from"] 
		$lTo = macToString $lBlockMap["to"] 
		$lXml += $lIndentStr + '<macpoolBlock '
		$lXml += ' from="' + $lFrom + '" to="' + $lTo + '"'
		$lXml += '/>' + "`n"
	}
	if (!$lFirstBlock)
	{
		$lIndentStr = ' ' * $aInIndent 
		$lXml += $lIndentStr + '</macpoolPool>' + "`n"
	}
	return $lXml
}



#
# Generate configuration xml for an ip pool.  
# Blocks of the ip pool are described by the passed array of block hashtables.
#
function getCreateIpPoolXml([int] $aInIndent, [array] $aInIdArray)
{
	$lXml = ""
	$lFirstBlock = $true
	foreach ($lBlockMap in $aInIdArray | Sort-Object {([uint64]$_.from) })
	{
		if ($lFirstBlock)	
		{
			$lFirstBlock = $false
			$lIndentStr = ' ' * $aInIndent
			$lXml += $lIndentStr + '<ippoolPool ' 
			$lAttrMap = @{"poolDn" = "dn"; "poolName" = "name"; "assignmentOrder" = "assignmentOrder" }
			foreach ($lKey in $lAttrMap.keys)
			{
				$lXml += ' ' + $lAttrMap[$lKey] + '=' + '"' + $lBlockMap[$lKey] +  '"'
			}
			$lXml += '>' + "`n"
		}
		$lIndentStr = ' ' * ($aInIndent +3)
		$lFrom = ipToString $lBlockMap["from"] 
		$lTo = ipToString $lBlockMap["to"] 
		$lPrimDns = ipToString $lBlockMap["primDns"] 
		$lSubnet = ipToString $lBlockMap["subnet"] 
		$lDefGw = ipToString $lBlockMap["defGw"] 
		$lSecDns = ipToString $lBlockMap["secDns"] 
		$lXml += $lIndentStr + '<ippoolBlock '
		$lXml += ' from="' + $lFrom + '" to="' + $lTo + '"'
		$lXml += ' primDns="' + $lPrimDns + '" secDns="' + $lSecDns + '"'; 
		$lXml += ' subnet="' + $lSubnet + '" defGw="' + $lDefGw + '"'; 
		$lXml += '/>' + "`n"
	}

	if (!$lFirstBlock)
	{
		$lIndentStr = ' ' * $aInIndent 
		$lXml += $lIndentStr + '</ippoolPool>' + "`n"
	}
	return $lXml
}



#
# Generate configuration xml for an wwn pool.  
# Blocks of the wwn pool are described by the passed array of block hashtables.
#
function getCreateWwnPoolXml([int] $aInIndent, [array] $aInIdArray)
{
	$lXml = ""
	$lFirstBlock = $true
	foreach ($lBlockMap in $aInIdArray | Sort-Object {([uint64] $_.from)})
	{
		if ($lFirstBlock)	
		{
			$lFirstBlock = $false
			$lIndentStr = ' ' * $aInIndent
			$lPoolName = $lBlockMap["poolName"]
			$lPoolDn = $lBlockMap["poolDn"]
			$lPurpose = $lBlockMap["purpose"] 
			$lXml += $lIndentStr + '<fcpoolInitiators name="' + $lPoolName + '" dn="' + $lPoolDn + '"' + ' purpose="' + $lPurpose + '">' + "`n"
		}
		$lIndentStr = ' ' * ($aInIndent +3)
		$lFrom = wwnToString $lBlockMap["from"] 
		$lTo = wwnToString $lBlockMap["to"] 
		$lXml += $lIndentStr + '<fcpoolBlock from="' + $lFrom + '" to="' + $lTo + '"'
		$lXml += '/>' + "`n"
	}
	if (!$lFirstBlock)
	{
		$lIndentStr = ' ' * $aInIndent 
		$lXml += $lIndentStr + '</fcpoolInitiators>' + "`n"
	}
	return $lXml
}


# 
# Write the contents of the passed IdMap to a csv file.
# IdMap[poolDn][type] = array of hashtables that describe an identity block.
# 
function toCsv ([hashtable] $aInIdMap, [string] $aInDestFileName)
{
	# Write-Host "Exporting id table to: "  $aInDestFileName

	# Sort blocks by orgDn, blockDn
        $lObjArray = @()

	foreach ($lPoolItem in $aInIdMap.GetEnumerator() | Sort-Object -caseSensitive { [regex]::matches($_.Name, "org-").count},{ $_.Name })
	{
		$lPoolDn = $lPoolItem.Key
 		foreach ($lType in $aInIdMap[$lPoolDn].keys)
		{
			foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType] | Sort-Object {([uint64] $_.from)}, {([uint64] $_.to)})
			{
				$lType = $lBlockMap["type"]
       				$lPurpose = ""
				$lPrefix = ""
				$lPrimDns = ""
				$lSecDns = ""
				$lSubnet = ""
				$lDefGw = ""
				$lSuffix = ""
				if (($lType -like "wwnnpool") -or ($lType -like "wwpnpool") -or ($lType -like "wwnnpnpool"))
				{
					$lPurpose = $lBlockMap["purpose"];
				} 
				elseif ($lType -like "ippool")
				{
					$lPrimDns = ipToString $lBlockMap["primDns"] 
					$lSecDns = ipToString $lBlockMap["secDns"] 
					$lSubnet = ipToString $lBlockMap["subnet"]
					$lDefGw = ipToString $lBlockMap["defGw"]
				}
				elseif ($lType -like "uuidpool")
				{
					$lPrefix = $lBlockMap["prefix"];
				}
				elseif ($lType -like "iqnpool")
				{
					$lPrefix = $lBlockMap["prefix"];
					$lSuffix = $lBlockMap["suffix"];
				}

				$lObjArray += New-Object PSObject -Property @{
					"type" = $lType;
					"block" = $lBlockMap["block"];
					"poolDesc" = $lBlockMap["poolDesc"];
					"assignmentOrder" = $lBlockMap["assignmentOrder"];
					"purpose" = $lPurpose;
					"prefix" = $lPrefix;
					"primDns" = $lPrimDns;
					"secDns" = $lSecDns;
					"subnet" = $lSubnet;
					"defGw" = $lDefGw;
					"suffix" = $lSuffix;
	     			}
			}
		}
	}
	$lObjArray | Export-Csv  -NoTypeInformation -Path $aInDestFileName
}



#
# Combine the contents of two IdMaps.
# IdMap[poolDn][type] = array of hashtables that describe an identity block.
#
function combineIdMaps([hashtable] $aInDestMap, [hashtable] $aInSrcMap)
{
	foreach ($lPoolDn in $aInSrcMap.keys)
	{
 		foreach ($lType in $aInSrcMap[$lPoolDn].keys)
		{
			foreach ($lBlockMap in $aInSrcMap[$lPoolDn][$lType]) 
			{
                                addIdToMap $aInDestMap $lBlockMap
			} 
		}
	}
}



#
# Merge the contents of two IdMaps.
# IdMap[poolDn][type] = array of hashtables that describe an identity block.
#
# This is necessary because it takes care of over-lapping blocks and duplicate pool
# names that may occur when two IdMaps are combined.
#
function merge ([hashtable] $aInIdMap)
{
	# debugPrint "merging duplicate ids"

	# Combine the passed ids into a single map
	$lOutIdMap = New-CHashtable
	foreach ($lPoolDn in $aInIdMap.keys)
	{
 		foreach ($lType in $aInIdMap[$lPoolDn].keys)
		{
			debugPrint "merge (pool=" $lPoolDn ")(type=" $lType ")"
			$lIdArray = $aInIdMap[$lPoolDn][$lType]
			$lMergedIdArray = @()

			if ($lType -like "uuidpool")
			{
				$lMergedIdArray = uuidBlockMerge $lPoolDn $lIdArray
			}
			elseif ($lType -like "iqnpool")
			{
				$lMergedIdArray = iqnBlockMerge $lPoolDn $lIdArray
			}
			else
			{
				$lMergedIdArray = genericBlockMerge $lPoolDn $lIdArray
			}

			# Map of indexed by 1) poolDn; 2) type
			if (!$lOutIdMap.containsKey($lPoolDn))
			{
				$lOutIdMap[$lPoolDn] = New-CHashtable
			}
			$lOutIdMap[$lPoolDn][$lType] = $lMergedIdArray
	        }
	}
	return $lOutIdMap
}



#
# Breaks up any blocks that are larger than the passed maximum block size
#
# Limit blocks to the passed size (creates new blocks where necessary)
# IdMap[poolDn][type] = array of hashtables that describe an identity block.
#
function limitBlockSize ([hashtable] $aInIdMap, [uint32] $aInMaxBlockSize)
{
	$lOutIdMap =New-CHashtable 
	printIdTable "limitBlockSize" $aInIdMap
	debugPrint "limitBlockSize" 

	foreach ($lPoolDn in $aInIdMap.keys)
	{
 		foreach ($lType in $aInIdMap[$lPoolDn].keys)
		{
			foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType]) 
			{
				debugPrint "check block size (" $lType ")(" $lPoolDn ")"

				$lIdArray = @()	
				$lType = $lBlockMap["type"] 
				$lBlock = $lBlockMap["block"] 
	
				$lFrom = $lBlockMap["from"]
				$lTo = $lBlockMap["to"]
				$lSize = $lTo - $lFrom + 1
				debugPrint "check block size (" $lType ")(" $lBlock ")(from=" $lFrom ")(to=" $lTo ")(" $lSize ")"

				if ($lSize -gt $aInMaxBlockSize)
				{
					$lNewIdArray = @()
					$lNumBlocks = [Math]::Truncate($lSize / $aInMaxBlockSize)
					$lMod = $lSize % $aInMaxBlockSize
					if ($lMod -gt 0)
					{
						$lNumBlocks += 1
					}
					debugPrint "create blocks (numBlocks=" $lNumBlocks ")(size=" $lSize ")(maxBlockSize=" $aInMaxBlockSize ")"
			        	
					for ($i=0; $i -lt $lNumBlocks; $i++)
					{
						$lCurrFrom = $lFrom + ($i * $aInMaxBlockSize)
						$lCurrTo = $lCurrFrom + ($aInMaxBlockSize -1)
						if ($lCurrTo -gt $lTo)
						{
							$lCurrTo = $lTo
						}
						$lNewIdHash = $lBlockMap.clone()
						$lNewIdHash["from"] = $lCurrFrom
						$lNewIdHash["to"] = $lCurrTo
						updateBlockId $lNewIdHash
                                	        addIdToMap $lOutIdMap $lNewIdHash
					}
				}
				else
				{
                                	addIdToMap $lOutIdMap $lBlockMap
				}
			}
		}
       	 }

	return $lOutIdMap
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
# Raise necessary warning  messages when two ip address blocks are merged.
#
function checkIpMerge ([string] $aInPoolDn, [hashtable] $aInIdOne, [hashtable] $aInIdTwo)
{
	if ($aInIdOne["primDns"] -ne $aInIdTwo["primDns"])
	{
                $lAddr1 = ipToString $aInIdOne["defGw"]
                $lAddr2 = ipToString $aInIdTwo["defGw"]
                addWarning $aInPoolDn "Merged blocks with different primary dns in pool ($lAddr1)($lAddr2)";
	}
	if ($aInIdOne["secDns"] -ne $aInIdTwo["secDns"])
	{
                $lAddr1 = ipToString $aInIdOne["secDns"]
                $lAddr2 = ipToString $aInIdTwo["secDns"]
                addWarning $aInPoolDn "Merged blocks with different secondary dns in pool ($lAddr1)($lAddr2)";
	}
	if ($aInIdOne["subnet"] -ne $aInIdTwo["subnet"])
	{
                $lAddr1 = ipToString $aInIdOne["subnet"]
                $lAddr2 = ipToString $aInIdTwo["subnet"]
                addWarning $aInPoolDn "Merged blocks with different subnet mask in pool ($lAddr1)($lAddr2)";
	}
	if ($aInIdOne["defGw"] -ne $aInIdTwo["defGw"])
	{
                $lAddr1 = ipToString $aInIdOne["defGw"]
                $lAddr2 = ipToString $aInIdTwo["defGw"]
                addWarning $aInPoolDn "Merged blocks with different default gateway in pool ($lAddr1)($lAddr2)";
	}
}


#
# Merge the passed array of hashtables (that describe an identity block.
# Over-lapping blocks will be combined.
# Returns the merged array of hashtables.
#
function genericBlockMerge ([string] $aInPoolDn, [array] $aInIdArray)
{

	debugPrint "genericBlockMerge : (" $aInPoolDn ")(" $aInIdArray ")"

	# Sort the ids by "from", "to"
	$lSortedArray = @()
	$aInIdArray.getEnumerator() | sort-Object {([uint64] $_.from)}, {([uint64] $_.to)} | ForEach-Object {  $lSortedArray += $_ }

        # For debuging - algorithm assumes sorted order!
	# foreach ($lBlockMap in $lSortedArray) { debugPrint "`generic merge order " $lBlockMap["block"]  " (from= "$lBlockMap["from"] ")(to=" $lBlockMap["to"] ")" } 

	$lDelIdx = @()
	$lAssignmentOrder = ""
	for ($i=1; $i -lt $lSortedArray.length; $i++)
	{
		# Warn user if assignment order differs across blocks
		if ($i -eq 1)
		{
			$lAssignmentOrder = $lSortedArray[$i-1]["assignmentOrder"]
			debugPrint "Assignment order " $lAssignmentOrder
		}
		debugPrint "Current :" $lSortedArray[$i]["assignmentOrder"]
		if ($lSortedArray[$i]["assignmentOrder"].compareTo($lAssignmentOrder) -ne 0)
		{
			addWarning $aInPoolDn "Pool contains blocks with different assignment orders"
		}

		$lPurpose = ""
		debugPrint "`tcomparing: (" $lSortedArray[$i-1].block ")(" $lSortedArray[$i].block ")"
		debugPrint "`tcomparing: from=(" $lSortedArray[$i-1].from ")(to=" $lSortedArray[$i-1].to ")(from=" $lSortedArray[$i].from ")(to=" $lSortedArray[$i].to ")"
		if ($lSortedArray[$i].from -le $lSortedArray[$i-1].to)
		{
			# Over-lapping blocks - combine the blocks
			$lFrom = $lSortedArray[$i-1].from
			$lTo = $lSortedArray[$i].to
			if ($lSortedArray[$i-1].to -ge $lSortedArray[$i].to)
			{ 
				$lTo =  $lSortedArray[$i-1].to 
			}
			$lSortedArray[$i].from = $lFrom
			$lSortedArray[$i].to = $lTo
			$lDelIdx += $i-1
			debugPrint "`tmerge : " $i ")(" $lSortedArray[$i].from ")(" $lSortedArray[$i].to ")"

			# For ip pools, we want to print a warning if the primDns, secDns, defGw, subnets do not match
			# when we are merging blocks
			$lType = $lSortedArray[$i-1].type
			if ($lType -like "ippool")
			{
				checkIpMerge $lPoolDn $lSortedArray[$i-1] $lSortedArray[$i]
			}
		}
	}

	# Construct the result set
	$lOutIdArray = @()
	for ($i=0; $i -lt $lSortedArray.length ; $i++)
        {
		if ($lDelIdx -notcontains $i)
		{
			# Update our block rn
			updateBlockId $lSortedArray[$i]
			$lOutIdArray += $lSortedArray[$i]
		}
		else
		{
			debugPrint "SKIPPING $i";
		}
	}

	return ,$lOutIdArray
}



#
# Merge the passed array of hashtables (that describe an identity block).
# For uuid's (prefix aware)
# Over-lapping blocks will be combined.
# Returns the merged array of hashtables.
#
function uuidBlockMerge ([string] $aInPoolDn, [array] $aInIdArray)
{
	# Sort the ids by "from", "to" taking into account uuids are composed of prefix and suffix
	$lSortedArray = @()
	$lIdArray.getEnumerator() | sort-Object {$_.prefix},{([uint64] $_.from)},{([uint64] $_.to)} | ForEach-Object {  $lSortedArray += $_ }

        # For debuging - algorithm assumes sorted order!
	# foreach ($lBlockMap in $lSortedArray) { debugPrint "CHECK merge order " $lBlockMap["prefix"] " : " $lBlockMap["block"]  "(" $lBlockMap["from"] ")(" $lBlockMap["to"] ")" }

	$lDelIdx = @()
	for ($i=1; $i -lt  $lSortedArray.length; $i++)
	{
		debugPrint "`tcomparing uuid: (" $lSortedArray[$i-1].block ")(" $lSortedArray[$i].block ")"
		debugPrint "`tcomparing: from=(" $lSortedArray[$i-1].from ")(to=" $lSortedArray[$i-1].to ")(from=" $lSortedArray[$i].from ")(to=" $lSortedArray[$i].to ")"

		# We only merge blocks if the pool has the same prefix
		if ($lSortedArray[$i-1].prefix -like $lSortedArray[$i].prefix)
		{
			# Warn user if assignment order differs across blocks in pool
			if ($lSortedArray[$i-1]["assignmentOrder"].compareTo($lSortedArray[$i]["assignmentOrder"]) -ne 0)
			{
				addWarning $aInPoolDn "Pool contains blocks with different assignment orders"
			}

			# DEBUG ONLY
			debugPrint "`tcheck (" (uuidToString $lSortedArray[$i].from) " to "  (uuidToString $lSortedArray[$i].to)  ") and (" uuidToString $lSortedArray[$i-1].from " to " uuidToString $lSortedArray[$i-1].to ")"
			if ($lSortedArray[$i].from -le $lSortedArray[$i-1].to)
			{
				# Over-lapping blocks - combine the blocks 
				$lTo = $lSortedArray[$i].to
				$lFrom = $lSortedArray[$i-1].from
				if ($lSortedArray[$i-1].to -ge $lSortedArray[$i].to)
				{
					$lTo =  $lSortedArray[$i-1].to
				}
				$lSortedArray[$i].from = $lFrom
				$lSortedArray[$i].to = $lTo
				$lDelIdx += $i-1
			}
		}
	}

	# Construct the result set
	$lOutIdArray = @()
	for ($i=0; $i -lt $lSortedArray.length ; $i++)
        {
		if ($lDelIdx -notcontains $i)
		{
			$lOutIdArray += $lSortedArray[$i]
		}
	}

	return ,$lOutIdArray
}



#
# Merge the passed array of hashtables (that describe an identity block).
# For iqn's (prefix and suffix aware)
# Over-lapping blocks will be combined.
# Returns the merged array of hashtables.
#
function iqnBlockMerge ([string] $aInPoolDn, [array] $aInIdArray)
{
	# Sort the ids by "from", "to" taking into account uuids are composed of prefix and suffix
	$lSortedArray = @()
	$lIdArray.getEnumerator() | sort-Object {$_.prefix},{$_.suffix},{([uint64] $_.from)},{([uint64] $_.to)} | ForEach-Object {  $lSortedArray += $_ }

        # For debuging - algorithm assumes sorted order!
	# foreach ($lBlockMap in $lSortedArray) { debugPrint "CHECK merge order (prefix=" $lBlockMap["prefix"] ")(" $lBlockMap["suffix"]  ")(" $lBlockMap["from"] ")(" $lBlockMap["to"] ")" }

	$lDelIdx = @()
	for ($i=1; $i -lt  $lSortedArray.length; $i++)
	{
		debugPrint "`tcomparing iqn: (" $lSortedArray[$i-1].block ")(" $lSortedArray[$i].block ")"

		# We only merge blocks if the pool has the same prefix
		if (($lSortedArray[$i-1].prefix -like $lSortedArray[$i].prefix) -and 
             	    ($lSortedArray[$i-1].suffix -like $lSortedArray[$i].suffix))
		{
			# DEBUG ONLY
			debugPrint "`tcheck (" ($lSortedArray[$i-1].from) " to "  ($lSortedArray[$i-1].to)  ") and (" $lSortedArray[$i].from " to " $lSortedArray[$i].to ")"

			# Warn user if assignment order differs across blocks in pool
			if ($lSortedArray[$i-1]["assignmentOrder"].compareTo($lSortedArray[$i]["assignmentOrder"]) -ne 0)
			{
				addWarning $aInPoolDn "Pool contains blocks with different assignment orders"
			}

			if ($lSortedArray[$i].from -le $lSortedArray[$i-1].to)
			{
				# Over-lapping blocks - combine the blocks 
				$lTo = $lSortedArray[$i].to
				$lFrom = $lSortedArray[$i-1].from
				if ($lSortedArray[$i-1].to -ge $lSortedArray[$i].to)
				{
					$lTo =  $lSortedArray[$i-1].to
				}
				$lSortedArray[$i].from = $lFrom
				$lSortedArray[$i].to = $lTo
				$lDelIdx += $i-1
			}
		}
	}

	# Construct the result set
	$lOutIdArray = @()
	for ($i=0; $i -lt $lSortedArray.length ; $i++)
        {
		if ($lDelIdx -notcontains $i)
		{
			$lOutIdArray += $lSortedArray[$i]
		}
	}

	return ,$lOutIdArray
}



#
# Change the name of the pool in the passed id hashtable
#
function renamePool([hashtable] $aInIdMap, [string] $aInPoolName)
{ 
	$lType =  $aInIdMap["type"] 
        $lPrefix = $global:POOL_RN_PREFIX_MAP[$lType]
	$lPoolDn =  $aInIdMap["orgDn"] + "/" + $lPrefix + $lPoolName
	$aInIdMap["poolName"] = $lPoolName
	$aInIdMap["poolDn"] = $lPoolDn
	updateBlockId $aInIdMap
        debugPrint "renamed pool (" $aInIdMap["poolName"] ")(" $lPoolName ")"
	return $aInIdMap
}



#
# WWN pools cn hold identities for port, node or port-and-node.  The pool names for the different
# types are not unique.  Thus, if the merging of identities creates pools that contain different
# types of wwns in a pool of the same dn - we resolve the conflict by renaming the pool.
#
# $aInIdMap - hashtable keyed by org;  Values are arrays of hashtables (that describe an identity block)
#
# Return: a  hashtable keyed by org;  Values are arrays of hashtables (that describe an identity block)
#
function massagePoolNames ([hashtable] $aInIdMap)
{
	debugPrint "massagePoolNames "  

        $lOutIdMap = New-CHashtable
	foreach ($lPoolDn in $aInIdMap.keys)
	{
 		foreach ($lType in $aInIdMap[$lPoolDn].keys)
		{

                        if ($lType -like "uuidpool")
			{
				# For uuid pools, if the prefixes are not unique we create new pool 
				# with the uuid-prefix appended to the pool name
				debugPrint "checking uuid prefix uniqueness : (" $lPoolDn ")"
				$lPrefix = $null
				$lDiffPrefix = $false
				foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType])
				{
					if ($lPrefix -like $null)
					{
						$lPrefix = $lBlockMap["prefix"]
					}
					else
					{
						if ($lPrefix.compareTo($lBlockMap["prefix"]))
						{
							debugPrint "Found differing prefixes for pool : (" $lBlockMap["poolDn"] ")"
							$lDiffPrefix = $true
							break	
						}
					}
				}
				# Copy pool to the out map (renaming pool if necessary)
				foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType])
				{
					if ($lDiffPrefix)
					{
                                                $lNewDn = $lBlockMap["poolDn"]
						$lPrefix =  $lBlockMap["prefix"];
                                                addWarning $lNewDn  "Renamed uuid pool because of prefix conflict"
						$lPoolName =  $lBlockMap["poolName"] + "-" + $lPrefix + "-RENAME"
						$lBlockMap = renamePool $lBlockMap $lPoolName
					}
					addIdToMap $lOutIdMap $lBlockMap
				}
			}
                        elseif ($lType -like "iqnpool")
			{
				# For iqn pools, if the prefixes are not unique we create new pool 
				# with the iqn-prefix appended to the pool name
				debugPrint "checking iqn prefix uniqueness : (" $lPoolDn ")"
				$lPrefix = $null
				$lDiffPrefix = $false
				foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType])
				{
					if ($lPrefix -eq $null)
					{
						$lPrefix = $lBlockMap["prefix"]
					}
					else
					{
						if ($lPrefix.compareTo($lBlockMap["prefix"]))
						{
							debugPrint "Found differing prefixes for pool : (" $lBlockMap["poolDn"] ")"
							$lDiffPrefix = $true
							break	
						}
					}
				}
				# Copy pool to the out map (renaming pool if necessary)
				foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType])
				{
					if ($lDiffPrefix)
					{
						$lPrefix =  $lBlockMap["prefix"];
                                                $lNewDn = $lBlockMap["poolDn"]
                                                addWarning $lNewDn  "Renamed iqn pool because of prefix conflict"
						$lPoolName =  $lBlockMap["poolName"] + "-" + $lPrefix + "-RENAME" 
						$lBlockMap = renamePool $lBlockMap $lPoolName
					}
					addIdToMap $lOutIdMap $lBlockMap
				}
			}
			elseif ($lType -like "wwnnpnpool")
			{
				debugPrint "checking wwnnpnpool name uniqueness : (" $lPoolDn ")"
				if ($aInIdMap[$lPoolDn].containsKey("wwnnpool"))
				{ 
					debugPrint "Shared name with wwnnpool "
				}
				if ($aInIdMap[$lPoolDn].containsKey("wwpnpool"))
				{ 
					debugPrint "Shared name with wwpnpool "
				}

				$lRenamePool = ($aInIdMap[$lPoolDn].containsKey("wwnnpool") -or ($aInIdMap[$lPoolDn].containsKey("wwpnpool")))
				# Copy pool to the out map (renaming pool if necessary)
				foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType])
				{
					if ($lRenamePool)
					{	
						# Add a prefix to the pool name to make it unique for this type
                                                $lNewDn = $lBlockMap["poolDn"]
                                                addWarning $lNewDn  "Renamed wwn (node and port) pool because of name conflict"
						$lPoolName = $lBlockMap["poolName"] + "-RENAME_NP"
						$lBlockMap = renamePool $lBlockMap $lPoolName
					}
					addIdToMap $lOutIdMap $lBlockMap
				}
			}
			elseif ($lType -like "wwnnpool")
			{	
				debugPrint "checking wwnnpool name uniqueness : (" $lPoolDn ")"
				$lRenamePool = $aInIdMap[$lPoolDn].containsKey("wwpnpool")
				foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType])
				{
					if ($lRenamePool)
					{
						# Add a prefix to the pool name to make it unique for this type
                                                $lNewDn = $lBlockMap["poolDn"]
                                                addWarning $lNewDn  "Renamed wwn (node) pool because of name conflict"
						$lPoolName = $lBlockMap["poolName"] + "-RENAME_NODE"
						$lBlockMap = renamePool $lBlockMap $lPoolName
					}
					addIdToMap $lOutIdMap $lBlockMap
				}
			}
			else
			{
				debugPrint "not checking pool name uniqueness : (" $lPoolDn ")"
				foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType])
				{
					addIdToMap $lOutIdMap $lBlockMap
				}
			}
		}
	}

	return $lOutIdMap
}



#
# Add the passed block IdMap to our master IdMap
#
function addIdToMap([hashtable] $aInOutIdMap, [hashtable] $aInBlockMap)
{
	$lPoolDn = $aInBlockMap["poolDn"];
	$lType = $aInBlockMap["type"];
	if (!$aInOutIdMap.containsKey($lPoolDn))
	{
		$aInOutIdMap[$lPoolDn] = New-CHashtable
	}
	if (!$aInOutIdMap[$lPoolDn].containsKey($lType))
	{
		$aInOutIdMap[$lPoolDn][$lType] = @()
	}
	$aInOutIdMap[$lPoolDn][$lType] += $aInBlockMap
}



#
# Read identity information from the passed filename.
# Results are stored in an IdMap.
# (IdMap[poolDn][type] = array of id hashtables that describe a block of ids)
#
function fromCsv([string] $aInSrcFileName)
{
	$aOutIdMap = New-CHashtable
	debugPrint "Importing id table from: "  $aInSrcFileName
        $lObjs = Import-CSV $aInSrcFileName

        foreach ($lObj in $lObjs)
        {
		$lBlockDn = $lObj.block
		$lDesc = $lObj.poolDesc
		$lType = $lObj.type
		$lDnArray = getDns $lBlockDn
		$lPoolDn = $lDnArray[$lOrgArray.length-2]

		# debugPrint "Processing line: (" $lBlockDn ")(" $lDesc ")(" $lType ")"
		$lBlockMap = $null
		if ($lType -like "macpool")
		{
			$lBlockMap = parseMacBlockDn $lBlockDn
		}
		elseif ($lType -like "uuidpool")
		{
			$lBlockMap = parseUuidBlockDn $lBlockDn
			$lBlockMap["prefix"] = $lObj.prefix
		}
		elseif (($lType -like "wwnnpool") -or ($lType -like "wwpnpool") -or ($lType -like "wwnnpnpool"))
		{
			$lBlockMap = parseWwnBlockDn $lBlockDn
			$lBlockMap["purpose"] = $lObj.purpose
		}
		elseif ($lType -like "ippool")
		{
			$lBlockMap = parseIpBlockDn $lBlockDn
			$lBlockMap["primDns"] = ipToInt $lObj.primDns
			$lBlockMap["secDns"] = ipToInt $lObj.secDns
			$lBlockMap["subnet"] = ipToInt $lObj.subnet
			$lBlockMap["defGw"] = ipToInt $lObj.defGw
		}

		if ($lBlockMap -ne $null)
		{
			$lOrgDn = $lBlockMap["orgDn"]
			$lBlockMap["assignmentOrder"] = $lObj.assignmentOrder
			$lBlockMap["type"] = $lType
			$lBlockMap["poolDesc"] = $lDesc
                        addIdToMap $aOutIdMap $lBlockMap
		}
        }
	return $aOutIdMap
}



# 
# Clear uuid prefix
#
function clearUuidPrefix([hashtable] $aInIdMap)
{
	debugPrint "clearUuidPrefix"

	foreach ($lPoolDn in $aInIdMap.keys)
	{
 		foreach ($lType in $aInIdMap[$lPoolDn].keys)
		{
			foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType]) 
			{
				if ($lBlockMap["type"] -like "uuidpool")
				{
					$lBlockMap["prefix"] = "00000000-0000-0000"
					# debugPrint "clearing prefix on " $lBlockMap["block"] 
				}
			}
		}
	}
}



# 
# For debug purposes only
#
function printIdMap ([string] $aInMsg, [hashtable] $aInIdMap)
{
	debugPrint $aInMsg
	foreach ($lKey in $aInIdMap.keys)
	{
		debugPrint "`t" $lKey " : " $aInIdMap[$lKey]
	}
}



# 
# For debug purposes only
#
function printIdTable ([string] $aInMsg, [hashtable] $aInIdMap)
{
	debugPrint ""
	debugPrint $aInMsg
	foreach ($lPoolDn in $aInIdMap.keys)
	{
		debugPrint ""
		debugPrint "Pool: (" $lPoolDn ")"
 		foreach ($lType in $aInIdMap[$lPoolDn].keys)
		{
			$lFirst = $true;
			foreach ($lBlockMap in $aInIdMap[$lPoolDn][$lType]) 
			{
 				if ($lFirst)
				{
					debugPrint "type: (" $lType ")"
					$lFirst = $false;
				}	
				foreach ($lKey in $lBlockMap.keys)
		 		{
		 			debugPrint $lKey ":" $lBlockMap[$lKey]
		 		}
		 	}
		}
	}
}



# 
# Query the ucs for identity related information.
# Results are stored in an IdMap.
# (IdMap[poolDn][type] = array of id hashtables that describe a block of ids)
#
function getUcsPools 
{
        $lOutIdMap = New-CHashtable
	$lPoolTypes = @("macpoolPool", "uuidpoolPool", "fcpoolInitiators", "ippoolPool", "iqnpoolPool")
	foreach ($lPoolType in $lPoolTypes)
	{
		debugPrint "Querying for pools of type : " $lPoolType
		$lPools = (Get-UcsManagedObject -class $lPoolType)
		foreach ($lPool in $lPools) 
		{
			$lPoolDn = $lPool.dn
			$lPoolDesc = $lPool.desc
			$lAssign = $lPool.assignmentOrder
			debugPrint "pool (DN=" $lPool.dn ")(DESC=" $lPool.desc ")("order= $lAssign ")"
	
			$lDnArray = getDns $lPool.dn
			$lOrgDn = $lDnArray[$lDnArray.length-2]
	
			# Find all of the blocks (contained by the pool)
			$lChildren = $lPool | Get-UcsChild
			foreach ($lChild in $lChildren)
			{
				$lBlockMap = $null
                                $Type = $null;
				if ($lChild -like "Cisco.Ucs.macpoolBlock")
       				{
					$lBlockMap = parseMacBlockDn $lChild.dn
					$lType = "macpool"
				}
				elseif ($lChild -like "Cisco.Ucs.uuidpoolBlock")
				{
					$lBlockMap = parseUuidBlockDn $lChild.dn
					$lType = "uuidpool"
					$lBlockMap["prefix"] = $lPool.prefix
				}
				elseif ($lChild -like "Cisco.Ucs.iqnpoolBlock")
				{
					$lBlockMap = parseIqnBlockDn $lChild.dn
					$lType = "iqnpool"
					$lBlockMap["prefix"] = $lPool.prefix
				}
				elseif ($lChild -like "Cisco.Ucs.ippoolBlock")
				{
					$lBlockMap = parseIpBlockDn $lChild.dn
					$lType = "ippool"
					$lBlockMap["from"] = ipToInt $lChild.from
					$lBlockMap["to"] = ipToInt $lChild.to
					$lBlockMap["primDns"] = ipToInt $lChild.primDns
					$lBlockMap["secDns"] = ipToInt $lChild.secDns
					$lBlockMap["defGw"] = ipToInt $lChild.defGw
					$lBlockMap["subnet"] = ipToInt $lChild.subnet
				}
       				elseif ($lChild -like "Cisco.Ucs.fcpoolBlock")
				{
					$lBlockMap = parseWwnBlockDn $lChild.dn
					$lPurpose= $lPool.purpose
					if ($lPurpose -like "port-wwn-assignment")
					{
						$lType = "wwpnpool"
					}
					elseif ($lPurpose -like "node-wwn-assignment")
					{
						 $lType= "wwnnpool"
					}
					elseif ($lPurpose -like "node-and-port-wwn-assignment")
					{
						 $lType= "wwnnpnpool"
					}
					$lBlockMap["purpose"] = $lPurpose
				}
				if ($lBlockMap -ne $null)
				{
					$lBlockMap["type"] = $lType
					$lBlockMap["poolDesc"] = $lDesc
					$lBlockMap["assignmentOrder"] = $lAssign
                                        addIdToMap $lOutIdMap $lBlockMap
				}
			}
		}
	}
	return $lOutIdMap
}


#
# Query the passed UCS system for identity related information.
# This information is returned in an identity map
# (IdMap[poolDn][type] = array of IdMaps that describe a block of ids)
#
function getUcsIds([string] $aInUcs)
{
	$lUcsUser = "admin"
	$lUcsPass = "Nbv12345"

	# Login to UCS
	if ($lUcsUser -eq "admin")
	{
		Write-Host "UCS: Logging into UCS Domain: $aInUcs"
		$lUcsPasswd = ConvertTo-SecureString $lUcsPass -AsPlainText -Force
		$lUcsCreds = New-Object System.Management.Automation.PSCredential ($lUcsUser, $lUcsPasswd)
		${myCon} = $ucslogin = Connect-Ucs -Credential $lUcsCreds $aInUcs
	}
	else 
	{
		# Login into UCS
		Write-Host  "Enter UCS Credentials: '"
		${lUcsCred} = Get-Credential
		Write-Host ""

		Write-Host "Logging into UCS Domain: '$($ucs)'"
		Write-Host ""  
		${myCon} = Connect-Ucs -Name $aInUcs -Credential ${lUcsCred} -ErrorAction SilentlyContinue
	}
 
	if (${Error}) 
	{
		Write-Error "Error creating a session to UCS Manager Domain: '$($ucs)'"
		Write-Error "     Error equals: ${Error}"
		Write-Error "     Exiting"
		exit
	}

	# Get id information for each of the pools
	Write-Host "Calling to get pools"
        $lIdMap = getUcsPools

        # Logout of UCS
	Write-Host "UCS: Logging out of UCS: $lUcs"
	$ucslogout = Disconnect-Ucs 

	return $lIdMap
}



$output = Set-UcsPowerToolConfiguration -SupportMultipleDefaultUcs $false

$lReqOrgMap = New-CHashtable 
$lMasterIdMap = New-CHashtable

$global:poolWarnings = New-CHashtable
$global:gDebug = $false
$global:gLogInit = $false
$global:gLogfile=""
$genFiles = @()

$global:POOL_RN_PREFIX_MAP = @{
	"ippool" = "ip-pool-"; 
	"wwpnpool" = "wwn-pool-";
	"wwnnpnpool" = "wwn-pool-";
	"wwnnpool" = "wwn-pool-";
	"uuidpool" = "uuid-pool-";
	"iqnpool" = "iqn-pool-";
	"macpool" = "mac-pool-";
}

if ($disallowunnamed)
{
	printUsage "You have extraneous command line options"
}

$lNumDataSources = $ucsips.length + $inIdFiles.length + 0
if ($lNumDataSources -eq 0)
{
	printUsage "No data sources provided" 
}

# Setup our output file names
if ("".compareTo($logFile) -eq 0)
{
	$logFile = "migrate.log"
}
if ("".compareTo($outIdFile) -eq 0)
{
	$outIdFile = "migrate.csv"
}
if ("".compareTo($commandFile) -eq 0)
{
	$commandFile = "migrate.xml"
}

$global:gLogfile = $logFile


# Respect over-write flag
if (!$overWrite)
{
	if (Test-Path $logFile)
	{ 
		Write-Error "Error, logfile `"$logFile`" already exists"
		Write-Error "Remove file or specify `"overwrite`" option"
		exit
	}
	if (Test-Path $outIdFile)
	{ 
		Write-Error "Error, id file `"$outIdFile`" already exists"
		Write-Error "Remove file or specify `"overwrite`" option"
		exit
	}
	if (Test-Path $commandFile)
	{ 
		Write-Error "Error, command file `"$commandFile`" already exists"
		Write-Error "Remove file or specify `"overwrite`" option"
		exit
	}
}

$genFiles += "Log file (for debuging only)                 : " + $logFile
$genFiles += "CSV file that contains merged ids            : " + $outIdFile
$genFiles += "XML file that contains UCS central commands  : " + $commandFile


try 
{
        ${Error}.Clear()

        for ($lSrcNum=0; $lSrcNum -lt $lNumDataSources; $lSrcNum++)
        {   
		$lIdMap = New-CHashtable
		if ($lSrcNum -lt $inIdFiles.length)
		{ 
			$lIdFile = $inIdFiles[$lSrcNum]
			if (!(Test-Path $lIdFile))
			{ 
				Write-Error "Error, input csv file `"$lIdFile`" does not exist"
				exit
			}
			$lIdMap = fromCsv $lIdFile
		}
		else
		{
			$lSysNum = $lSrcNum - $inIdFiles.length;
			$lUcs = $ucsips[$lSysNum]
			$lIdMap = getUcsIds $lUcs

			if ($csvperucs)
			{
				$lUcsFilename = $lUcs + "-ids.csv"
				if ((!$overWrite) -and (Test-Path $commandFile))
				{
					Write-Error "Error, ucs csv file `"$lUcsFilename`" already exists"
					Write-Error "Remove file or specify `"overwrite`" option"
					exit
				}
				$genFiles += "CSV id file for ucs system " + $lUcs + " :       " + $lUcsFileName
				toCsv $lIdMap $lUcsFilename
			}
		}

		# For debuging (Print our id table)
		printIdTable  "Current id table " $lIdMap 

		# Clear the uuid prefix if requested (based on command line options)
		if (!$keepUuidPrefix)
		{
			clearUuidPrefix $lIdMap
		}

		# Merge the duplicate ids 
		Write-Host "Combining id maps"
		combineIdMaps $lMasterIdMap $lIdMap
		printIdTable  "Combined id table " $lMasterIdMap

		Write-Host "Merging duplicate ids"
		$lMasterIdMap = merge $lMasterIdMap 
		printIdTable  "Merged id table " $lMasterIdMap
	}

        Write-Host "Renaming pools"
	$lMasterIdMap = massagePoolNames $lMasterIdMap 
        Write-Host "Limiting block sizes"
	$lMasterIdMap = limitBlockSize $lMasterIdMap 1000

	toCsv $lMasterIdMap $outIdFile

        Write-Host "Generating command file"
	generateCommands $lMasterIdMap $commandFile

	Write-Host ""
	foreach ($lPoolDn in $global:poolWarnings.keys)
	{
	        $lWarnings = $global:poolWarnings[$lPoolDn] | select -uniq | sort
		foreach ($lWarning in $lWarnings)
		{
			Write-Warning "$lPoolDn : $lWarning"
		}
	}

	Write-Host ""
	Write-Host "Output Files:"
	foreach ($lGenFile in $genFiles)
	{
		Write-Host $lGenFile
	}
	Write-Host ""


}
catch
{
	Write-Error "Error occurred in script"
	Write-Error ([String] ${Error})
	exit
}
finally
{
	$ucslogout = Disconnect-Ucs 
}




