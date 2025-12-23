# Refactored and modified from:
# Test ReFS data corruption detection (Test-ReFSDataCorruption.ps1) version 1.9

# Public domain. You may copy, modify, distribute and perform any parts of this work not covered under the sources below without asking permission under CC0 1.0 Universal (https://creativecommons.org/publicdomain/zero/1.0/)
# Based on an original script by kjo at deif dot com - https://forums.veeam.com/veeam-backup-replication-f2/refs-data-corruption-detection-t53098.html#p345182
# Seeking to test issues first raised by MyAccount42 by https://www.reddit.com/r/DataHoarder/comments/iow60w/testing_windows_refs_data_integrity_bit_rot/
# The post above was based on the ZFS testing methodology proposed by Graham at http://www.zfsnas.com/2015/05/24/testing-bit-rot/
# Finding and replacing in a binary file based on code by Mikhail Tumashenko at https://stackoverflow.com/questions/32758807/how-to-find-and-replace-within-a-large-binary-file-with-powershell/32759743#32759743

$testIterations = 1
$forceInitialVHDRemoval = $false

# periodically pause execution for user to manually inspect virtual disk/volume/files
$enableUserPauses = $false
# invoke (Dis)Connect-VirtualDisk (fixes parent script issues for mirrors)
$manualVirtualDiskConnection = $true
# Specify whether to create file set 0, and create corruption for this set on every disk - test behaviour of Set-FileIntegrity -Enforce $false functionality - either 0 (create set 0 and test behaviour) or 1 (don't create set 0 or test behaviour)
$forceUnrecoverableFile = $false

$sleepSeconds = 5

$mirrorVolumeArguments = @{
    NumDrives = 3
    PhysicalDiskRedundancy = 1
    NumDrivesToCorrupt = 1
    FileCount = 3
}

$parityVolumeArguments = @{
    NumDrives = 3
    PhysicalDiskRedundancy = 1
    NumDrivesToCorrupt = 1
    FileCount = 9
}

function Log-Timestamp
{
    Write-Host "[" -NoNewline -ForegroundColor DarkGray
    Write-Host $(Get-Date -Format "HH:mm:ss.fff") -NoNewline -ForegroundColor White
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
}

function Log-Info
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$ForegroundColor
    )

    if( $null -eq $ForegroundColor )
    {
        $ForegroundColor = (Get-Host).UI.RawUI.ForegroundColor
    }

    Log-Timestamp
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function _Sleep
{
    Write-Host "Sleeping for ${sleepSeconds}s..." -ForegroundColor DarkGray
    Start-Sleep $sleepSeconds
}

function Test-RefsIntegrityStreamRepair
{
    param(
        # pool/virtual disk/volume friendly name
        [string]$FriendlyName = "Test",
        # VHD directory
        [string]$WorkingDirPath = "C:\temp\Test-ReFSDatCorruption_Files",
        # drive letter for volume
        [string]$DriveLetter = "T",

        [Parameter(Mandatory = $true)]
        [string]$ResiliencySettingName,

        # Number of drives to test with - see limits here: https://social.technet.microsoft.com/wiki/contents/articles/11382.storage-spaces-frequently-asked-questions-faq.aspx#What_are_the_recommended_configuration_limits
        # Different numbers required for different resiliency / redundancy options - see https://support.microsoft.com/en-us/windows/storage-spaces-in-windows-b6c8b540-b8d8-fb8a-e7ab-4a75ba11f9f2
        # Simple - requires at least 1 physical disk
        # Two-way mirror - requires at least 2 physical disks (although 3 disks may be required to recover from every kind of metadata corruption) - see https://arstechnica.com/civis/viewtopic.php?p=29655295&sid=91dbc0df788c23de84558941e3fd2ede#p29655295, https://docs.microsoft.com/en-gb/archive/blogs/tip_of_the_day/tip-of-the-day-3-way-mirrors
        # Three-way mirror - requires at least 5 physical disks
        # Single parity - requires at least 3 physical disks
        # Dual parity - requires at least 7 physical disks (5 does work but may be unsupported - https://mozzism.ch/post/643019176393523200/windows-10-storage-spaces-dual-parity-with-only)
        [int]$NumDrives = 3,

        # Number of failed physical disks the volume can tolerate without data loss - https://docs.microsoft.com/en-us/powershell/module/storage/new-volume?view=windowsserver2022-ps
        # Two-way mirror / Single parity space - 1
        # Three-way mirror / Dual parity space - 2
        $PhysicalDiskRedundancy = 1,

        # Specify the number of drives to corrupt - supports 1 to 9 (although more than 2 is probably going beyond Storage Spaces capabilities in terms of resilience)
        [int]$NumDrivesToCorrupt = 1,

        # Number of data files to create per set - supports 1 to 9999
        [int]$FileCount = 3,

        # Corrupt the drives in descending instead of ascending order (e.g. to test corrupting drive 2 instead of drive 1 in a two-way, two disk mirror). Important to check ReFS behaviour whether or not the corrupt data is on the first drive that is initially accessed or a different redundant drive
        [switch]$CorruptFilesInDescendingOrder,
        
        # Specify whether to create file set 0, and create corruption for this set on every disk - test behaviour of Set-FileIntegrity -Enforce $false functionality - either 0 (create set 0 and test behaviour) or 1 (don't create set 0 or test behaviour)
        [switch]$ForceUnrecoverableFile,

        # invoke Disconnect-VirtualDisk when dismounting VHDs and then Connect-VirtualDisk when remounting VHDs
        # this seemsm to fix integrity stream issues from the base script as of 2025-12-13
        [switch]$ManualVirtualDiskConnection,

        # periodically wait for user to hit the enter key in the event the user wishes to inspect the pool/virtual disk/volume/files during execution
        [switch]$EnableUserPauses,

        # invoke Write-VolumeCache prior to dismounting VHDs
        [switch]$WriteVolumeCache
    )

    function Scan-Data
    {
        param(
            [string]$Message = $null
        )

        1..$numdrives |% { 
            $data = "Corrupt[ -~]{10}"

            if( "" -ne $Message )
            {
                $msg = $Message -f $_
                Log-Info $msg
            }

            Get-Content -Path $WorkingDirPath\$_.vhdx -ReadCount 1000 | foreach { ($_ | Select-String $data -AllMatches).Matches.Value } }
    }

    function Pause
    {
        if( $EnableUserPauses )
        {
            Read-Host -Prompt "Press enter to continue..."
        }
    }

    function Dismount-VHDs
    {
        param(
            [string]$Message = $null
        )

        if( $ManualVirtualDiskConnection )
        {
            Log-Info "Disconnecting virtual disk"
            Disconnect-VirtualDisk -FriendlyName $FriendlyName
        }

        1..$numdrives | ForEach-Object `
        { 
            if( "" -ne $Message )
            {
                $msg = $Message -f $_
                Log-Info $msg
            }

            Dismount-VHD $WorkingDirPath\$_.vhdx
        }
    }

    function Remount-VHDs
    {
        param(
            [string]$Message = $null
        )


        1..$numdrives | ForEach-Object `
        {
            if( "" -ne $Message )
            {
                $msg = $Message -f $_
                Log-Info $msg
            }

            Mount-VHD $WorkingDirPath\$_.vhdx;
        }
        
        _Sleep

        if( $ManualVirtualDiskConnection )
        {
            Log-Info "Connecting virtual disk"
            Connect-VirtualDisk -FriendlyName $FriendlyName
        }
    }

    function Write-VC
    {
        if( $WriteVolumeCache )
        {
            Write-Host "Writing Volume Cache"
            Write-VolumeCache -FileSystemLabel $FriendlyName
        }
    }

    function New-MirrorVolume
    {
        New-Volume `
            -FriendlyName $FriendlyName `
            -DriveLetter $DriveLetter `
            -FileSystem ReFS `
            -StoragePoolFriendlyName $FriendlyName `
            -ResiliencySettingName Mirror `
            -PhysicalDiskRedundancy $PhysicalDiskRedundancy `
            -AllocationUnitSize 4KB `
            -UseMaximumSize `
            | Out-Null
    }

    function New-ParityVolume
    {
        $vd = New-VirtualDisk `
            -StoragePoolFriendlyName $FriendlyName `
            -FriendlyName $FriendlyName `
            -ResiliencySettingName Parity `
            -NumberOfColumns $NumDrives `
            -PhysicalDiskRedundancy $PhysicalDiskRedundancy `
            -Interleave 16KB `
            -ProvisioningType Thin `
            -Size 10GB

        New-Volume `
            -DiskUniqueId $vd.UniqueId `
            -FriendlyName $FriendlyName `
            -DriveLetter $DriveLetter `
            -FileSystem ReFS `
            -AllocationUnitSize 4KB `
            | Out-Null
    }

    function Pad-Content
    {
        param(
            [string]$Content
        )

        $Content.PadRight( 1024 * 32, ';' )
    }

    function Unpad-Content
    {
        param(
            [string]$Content
        )

        $off = $content.IndexOf(';')

        if( 0 -lt $off )
        {
            $content.Substring(0, $off)
        }
        else
        {
            $content
        }
    }

    function New-FileContents
    {
        param(
            [int]$FileSet,
            [int]$FileNumber
        )

        Pad-Content "Corrupt_me_$FileSet $($FileNumber.ToString("0000"))"
    }

    function Get-UnpaddedContent
    {
        param(
            [string]$Path
        )

        Get-Content -Path $Path |% { `
            Unpad-Content $_
        }
    }

    # Create a warning if you are corrupting more drives than the storage pool is configured for - you might want to do this, but not really a fair test!
    If ($NumDrivesToCorrupt -gt $PhysicalDiskRedundancy) {
        Write-Warning "[$(Get-Date)] You are trying to corrupt more drives than the tolerated configuration for the current storage pool - you should expect data loss to occur"
    }

    # Enable Hyper-V role on this device if not already installed - required to manage virtual hard disks
    # For Windows Client:
    #DISM.exe /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V
    # For Windows Server:
    #Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart

    # Dismount VHDs if they already exist (assumption is previous run errored out so test volume may still exist)
    if( $forceInitialVHDRemoval )
    {
        Dismount-VHDs "Ensuring {0}.vhdx is dismounted..."
        _Sleep
    }

    # Make a note of when the script starts for event log monitoring later
    $scriptstarttime = Get-Date

    # Write out the OS build number etc for reference

    Log-Info "Starting script on $((Get-CimInstance -class Win32_OperatingSystem).Caption) $((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').DisplayVersion) (OS Build $((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').CurrentBuildNumber).$((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').UBR))..." `
        -ForegroundColor White

    # ensure working directory exists
    if (-not (Test-Path -Path $WorkingDirPath))
    {
        New-Item -Path $WorkingDirPath -ItemType Directory -Force | Out-Null
    }

    # Clean up old VHDs if they exist
    1..$NumDrives |%{ If (Test-Path $WorkingDirPath\$_.vhdx) { Remove-Item $WorkingDirPath\$_.vhdx | Out-Null } }

    # START CREATING STORAGE POOL
    Log-Info "Creating $ResiliencySettingName ReFS volume with $NumDrives VHDs and $PhysicalDiskRedundancy Disk Redundancy in Windows Storage Spaces..." -ForegroundColor Cyan

    # Create new VHDs and mount them - 5GB is the rough minimum for storage spaces
    1..$NumDrives |%{ New-VHD -Path $WorkingDirPath\$_.vhdx -SizeBytes 5GB } | Mount-VHD

    # Create a storage pool with them
    New-StoragePool -FriendlyName $FriendlyName -PhysicalDisks (Get-PhysicalDisk |? Size -eq 5GB) -StorageSubsystemFriendlyName "Windows Storage*" | Out-Null

    if( "Mirror" -eq $ResiliencySettingName )
    {
        New-MirrorVolume
    }
    elseif( "Parity" -eq $ResiliencySettingName )
    {
        New-ParityVolume
    }
    else {
        Write-Error "Resiliency setting $ResiliencySetting not implemented by this script"
        exit
    }

    if( $ManualVirtualDiskConnection )
    {
        Set-VirtualDisk -FriendlyName $FriendlyName -IsManualAttach $true
    }

    Log-Info "Enabling ReFS Integrity Streams on ReFS volume with Storage Spaces..."

    # Enable file integrity
    Set-FileIntegrity ${DriveLetter}: -Enable $true

    # Write out the created version and settings of the ReFS volume
    Log-Info "Displaying refsinfo for newly created volume..."
    fsutil fsinfo refsinfo ${DriveLetter}:

    $skipfilesetzero = $ForceUnrecoverableFile ? 0 : 1

    # Create a number of files on the ReFS volume to test for corruption, named by set and file number
    for ($i = $skipfilesetzero; $i -le $NumDrivesToCorrupt; $i++) {
        for ($j = 1; $j -le $FileCount; $j++) {
            $testfilename = "${DriveLetter}:\test$i.$($j.ToString("0000")).txt"
            $testfiledata = New-FileContents $i $j
            Log-Info "Creating text file '$testfilename' with test file contents '$(Unpad-Content $testfiledata)'..."
            $data = [system.Text.Encoding]::Default.GetBytes($testfiledata)
            [io.file]::WriteAllBytes($testfilename, $data)
        }
    }

    # Give ReFS a few seconds to finish writing
    _Sleep

    Scan-Data "Scanning uncorrupted data in {0}.vhdx before dismount"

    Write-VC

    Pause

    # Dismount VHDs
    Dismount-VHDs "Dismounting '{0}.vhdx' to generate corruption..."
    _Sleep

    # Create a hash table tracking how many drives we still need to corrupt based on remaining sets of files for corruption
    $drivecorruptionset = @{}
    for ($i = $skipfilesetzero; $i -le $NumDrivesToCorrupt; $i++) {
        $drivecorruptionset.Add($i, $null)
    }

    # Start introducting file corruption onto the drives you want to corrupt according to the drive search order
    1..$NumDrives | Sort-Object -Descending:$CorruptFilesInDescendingOrder |%{ $path = "$WorkingDirPath\$_.vhdx"
        # Go through the remaining sets of files to create for corruption
        foreach ($drivekey in $drivecorruptionset.Keys | Sort-Object) {
            $stringToSearch = "Corrupt_me_$drivekey"
            $enc = [system.Text.Encoding]::ASCII

            Log-Info "Searching '$_.vhdx' for '$stringToSearch'..."

            # Get the entire file contents as a byte array
            $byteArray = [System.IO.File]::ReadAllBytes($path)

            # look for string
            $m = [Regex]::Matches($enc.GetString($byteArray), $stringToSearch)

            foreach ($match in $m) {
                # Corrupt the first binary bit of the character (e.g. converts ASCII space 00100000 to ASCII exclamation mark 00100001)
                [Byte]$bytetocorrupt = $byteArray[$match.Index + $match.length]
                [Byte]$corruptedbyte = $byteArray[$match.Index + $match.length] -bxor 1

                Log-Info "Found '$stringToSearch' at position $($match.Index) - corrupting following character from '$($enc.GetString($bytetocorrupt))' to '$($enc.GetString($corruptedbyte))'..."

                # corrupt the data
                $fileStream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $binaryWriter = New-Object System.IO.BinaryWriter($fileStream)

                # set file position to the character after the found string and write the corrupt byte
                $binaryWriter.BaseStream.Position = $match.Index + $match.length;
                $binaryWriter.Write($corruptedbyte)

                $fileStream.Close()
            }

            # If we are not working on drive set 0 (where we test with corruption on every possible disk) and we managed to find some data to corrupt with this set, remove it from the hash and go on to the next disk
            if ($drivekey -ne 0 -and $m.Count -gt 0) {
                $drivecorruptionset.Remove($drivekey)
                break
            }
        }
    }

    _Sleep

    # Verify the file corruption created on drives - match 'Corrupt' followed by any printable ASCII characters
    Scan-Data "Scanning '{0}.vhdx' to verify uncorrupted or corrupted data before repair..."

    # Mount VHDs
    Remount-VHDs "Remounting '{0}.vhdx' to test Integrity Streams corruption detection & repair..."

    # Wait for the Storage Pool to return a Healthy status - see https://docs.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-states#storage-pool-states
    Do {
        Log-Info "Waiting for Storage Pool to reach Healthy status..."
        $StoragePoolStatus = Get-StoragePool -FriendlyName $friendlyName
    } While ($StoragePoolStatus.HealthStatus -ne "Healthy")

    # Write out current Storage Pool Status - should be Healthy
    $StoragePoolStatus | Select-Object -Property HealthStatus, OperationalStatus, ReadOnlyReason | Format-Table

    Pause
    _Sleep

    # See if we can now get the file contents (should always fail on drive set 0, but all other reads from drive sets should succeed and automatically repair if corrupted on the pool disk that Storage Spaces happens to try to access it from)
    for ($i = $skipfilesetzero; $i -le $NumDrivesToCorrupt; $i++) {
        for ($j = 1; $j -le $FileCount; $j++) {
            if ($i -eq 0) { # Read from drive set 0. This is to check that remaining corrupted data can still be accessed when Set-FileIntegrity -Enforce $false is run on it and is not silently deleted 
                #Log-Info "Attempting to read '${DriveLetter}:\test$i.$($j.ToString("0000")).txt' with file integrity enforced (should fail since all files in this data set were deliberately corrupted)..."
                #try { Get-Content "${DriveLetter}:\test$i.$($j.ToString("0000")).txt" -ErrorAction Stop }
                #catch {
                #    If ($Error[0].Exception.HResult -ne -2147024573) { # Expecting error 0x80070143 - ERROR_DATA_CHECKSUM_ERROR - 'A data integrity checksum error occurred. Data in the file stream is corrupt.'
                #        Write-Error $_ # If we get a different and unexpected error, display it!
                #    }
                #}

                # Disable blocking access to a file if integrity streams indicate data corruption - see https://docs.microsoft.com/en-us/powershell/module/storage/set-fileintegrity?view=windowsserver2022-ps
                Set-FileIntegrity -FileName "${DriveLetter}:\test$i.$($j.ToString("0000")).txt" -Enforce $false

                Log-Info "Attempting to read '${DriveLetter}:\test$i.$($j.ToString("0000")).txt' with file integrity unenforced - should succeed in returning (corrupt) file contents..."
                Get-UnpaddedContent "${DriveLetter}:\test$i.$($j.ToString("0000")).txt"
            } else {
                Log-Info "Attempting to read '${DriveLetter}:\test$i.$($j.ToString("0000")).txt' - should be able to read without errors..."
                Get-UnpaddedContent "${DriveLetter}:\test$i.$($j.ToString("0000")).txt"

                # Run manual scrub/repair to ensure scan we have checked this file for corruption on every disk in the storage space
                Log-Info "Attempting manual scrub / repair on '${DriveLetter}:\test$i.$($j.ToString("0000")).txt'..."
                Repair-FileIntegrity "${DriveLetter}:\test$i.$($j.ToString("0000")).txt"
            }
        }
    }

    # Give ReFS a few seconds to generate event logs
    _Sleep

    # Show ReFS events to see if repairs were reported
    Log-Info "Reading event logs to verify corruption & any fixes are logged in System Event log..."
    Get-WinEvent -FilterHashtable @{ StartTime=$scriptstarttime; LogName="System"; ProviderName="Microsoft-Windows-ReFS*"} | Format-Table

    Write-VC

    Pause

    Dismount-VHDs "Dismounting '{0}.vhdx' to verify whether corruption was correctly detected & repaired on all drives..."

    # Verify that it has been fixed - match 'Corrupt' followed by any printable ASCII characters
    Scan-Data "Scanning '{0}.vhdx' for uncorrupted or corrupted data - all except set 0 should be uncorrupted..."

    Write-Host
}


1..$testIterations | ForEach-Object {

    Write-Host "======== Test iteration $_ of $testIterations... ========"

    if( $mirrorVolumeArguments )
    {
        Test-RefsIntegrityStreamRepair -ResiliencySettingName Mirror `
            -ForceUnrecoverableFile:$forceUnrecoverable `
            -ManualVirtualDiskConnection:$manualVirtualDiskConnection `
            -EnableUserPauses:$enableUserPauses `
            -WriteVolumeCache `
            @mirrorVolumeArguments

        Test-RefsIntegrityStreamRepair -ResiliencySettingName Mirror `
            -ForceUnrecoverableFile:$forceUnrecoverable `
            -ManualVirtualDiskConnection:$manualVirtualDiskConnection `
            -EnableUserPauses:$enableUserPauses `
            -CorruptFilesInDescendingOrder `
            -WriteVolumeCache `
            @mirrorVolumeArguments
    }

    if( $parityVolumeArguments )
    {
        Test-RefsIntegrityStreamRepair -ResiliencySettingName Parity `
            -ForceUnrecoverableFile:$forceUnrecoverable `
            -ManualVirtualDiskConnection:$manualVirtualDiskConnection `
            -EnableUserPauses:$enableUserPauses `
            -WriteVolumeCache `
            @parityVolumeArguments

        Test-RefsIntegrityStreamRepair -ResiliencySettingName Parity `
            -ForceUnrecoverableFile:$forceUnrecoverable `
            -ManualVirtualDiskConnection:$manualVirtualDiskConnection `
            -EnableUserPauses:$enableUserPauses `
            -CorruptFilesInDescendingOrder `
            -WriteVolumeCache `
            @parityVolumeArguments
    }

}