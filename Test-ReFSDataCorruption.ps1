# Test ReFS data corruption detection (Test-ReFSDataCorruption.ps1) version 1.7

# Public domain. You may copy, modify, distribute and perform any parts of this work not covered under the sources below without asking permission under CC0 1.0 Universal (https://creativecommons.org/publicdomain/zero/1.0/)
# Based on an original script by kjo at deif dot com - https://forums.veeam.com/veeam-backup-replication-f2/refs-data-corruption-detection-t53098.html#p345182
# Seeking to test issues first raised by MyAccount42 by https://www.reddit.com/r/DataHoarder/comments/iow60w/testing_windows_refs_data_integrity_bit_rot/
# The post above was based on the ZFS testing methodology proposed by Graham at http://www.zfsnas.com/2015/05/24/testing-bit-rot/
# Finding and replacing in a binary file based on code by Mikhail Tumashenko at https://stackoverflow.com/questions/32758807/how-to-find-and-replace-within-a-large-binary-file-with-powershell/32759743#32759743

# Number of drives to test with - see limits here: https://social.technet.microsoft.com/wiki/contents/articles/11382.storage-spaces-frequently-asked-questions-faq.aspx#What_are_the_recommended_configuration_limits
    # Different numbers required for different resiliency / redundancy options - see https://support.microsoft.com/en-us/windows/storage-spaces-in-windows-b6c8b540-b8d8-fb8a-e7ab-4a75ba11f9f2
    # Simple - requires at least 1 physical disk
    # Two-way mirror - requires at least 2 physical disks (although 3 disks may be required to recover from every kind of metadata corruption) - see https://arstechnica.com/civis/viewtopic.php?p=29655295&sid=91dbc0df788c23de84558941e3fd2ede#p29655295, https://docs.microsoft.com/en-gb/archive/blogs/tip_of_the_day/tip-of-the-day-3-way-mirrors
    # Three-way mirror - requires at least 5 physical disks
    # Single parity - requires at least 3 physical disks
    # Dual parity - requires at least 7 physical disks (5 does work but may be unsupported - https://mozzism.ch/post/643019176393523200/windows-10-storage-spaces-dual-parity-with-only)
$numdrives = 3

# Arguments to use with New-Volume when creating the Storage Pool - see https://docs.microsoft.com/en-us/powershell/module/storage/new-volume?view=windowsserver2022-ps
$newvolumearguments = @{
    # Resiliency Option
        # 'Simple'
        # 'Mirror'
        # 'Parity'
    ResiliencySettingName = "Mirror"
    # Number of failed physical disks the volume can tolerate without data loss - https://docs.microsoft.com/en-us/powershell/module/storage/new-volume?view=windowsserver2022-ps
        # Two-way mirror / Single parity space - 1
        # Three-way mirror / Dual parity space - 2
    PhysicalDiskRedundancy = 1
    # Number of columns to use when creating the volume - NB read before configuring:
        # https://social.technet.microsoft.com/wiki/contents/articles/11382.storage-spaces-frequently-asked-questions-faq.aspx#Controlling_the_Number_of_Columns
        # https://docs.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn782852(v=ws.11)#plan-for-fault-tolerance
    #NumberOfColumns = 1
    # Create a virtual disk with the maximum size possible - not recommended when wanting auto repair in production use, see https://docs.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2012-r2-and-2012/dn782852(v=ws.11)#plan-for-fault-tolerance
    UseMaximumSize = $true
}

# Specify the number of drives to corrupt - supports 1 to 9 (although more than 2 is probably going beyond Storage Spaces capabilities in terms of resilience)
$numdrivestocorrupt = 1

# Specify whether to create file set 0, and create corruption for this set on every disk - test behaviour of Set-FileIntegrity -Enforce $false functionality - either 0 (create set 0 and test behaviour) or 1 (don't create set 0 or test behaviour)
$skipfilesetzero = 1

# Number of data files to create per set - supports 1 to 9999
$numcorruptfiles = 3

# Corrupt the drives in descending instead of ascending order (e.g. to test corrupting drive 2 instead of drive 1 in a two-way, two disk mirror). Important to check ReFS behaviour whether or not the corrupt data is on the first drive that is initially accessed or a different redundant drive
$sortdescending = $true

# Create a warning if you are corrupting more drives than the storage pool is configured for - you might want to do this, but not really a fair test!
If ($numdrivestocorrupt -gt $newvolumearguments["PhysicalDiskRedundancy"]) {
    Write-Warning "[$(Get-Date)] You are trying to corrupt more drives than the tolerated configuration for the current storage pool - you should expect data loss to occur"
}

# Enable Hyper-V role on this device if not already installed - required to manage virtual hard disks
#DISM.exe /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V

# Make a note of when the script starts for event log monitoring later
$scriptstarttime = Get-Date

# Write out the OS build number etc for reference
Write-Host "[$(Get-Date)] Starting script on $((Get-CimInstance -class Win32_OperatingSystem).Caption) $((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').DisplayVersion) (OS Build $((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').CurrentBuildNumber).$((Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\').UBR))..."

# Clean up old VHDs if they exist
1..$numdrives |%{ If (Test-Path C:\$_.vhdx) { Remove-Item C:\$_.vhdx } }

# START CREATING STORAGE POOL
Write-Host "[$(Get-Date)] Creating $($newvolumearguments["ResiliencySettingName"]) ReFS volume with $numdrives VHDs and $($newvolumearguments["PhysicalDiskRedundancy"]) Disk Redundancy in Windows Storage Spaces..."

# Create new VHDs and mount them - 5GB is the rough minimum for storage spaces
1..$numdrives |%{ New-VHD -Path C:\$_.vhdx -SizeBytes 5GB } | Mount-VHD

# Create a storage pool with them
$storagepool = New-StoragePool -FriendlyName Test -PhysicalDisks (Get-PhysicalDisk |? Size -eq 5GB) -StorageSubsystemFriendlyName "Windows Storage*"

# Create ReFS volume
$refsvolume = New-Volume -FriendlyName Test -DriveLetter T -FileSystem ReFS -StoragePoolFriendlyName Test @newvolumearguments

Write-Host "[$(Get-Date)] Enabling ReFS Integrity Streams on ReFS volume with Storage Spaces..."

# Enable file integrity
Set-FileIntegrity T: -Enable $true

# Write out the created version and settings of the ReFS volume
Write-Host "[$(Get-Date)] Displaying refsinfo for newly created volume..."
fsutil fsinfo refsinfo T:

# Create a number of files on the ReFS volume to test for corruption, named by set and file number
for ($i = $skipfilesetzero; $i -le $numdrivestocorrupt; $i++) {
    for ($j = 1; $j -le $numcorruptfiles; $j++) {
        $testfilename = "T:\test$i.$($j.ToString("0000")).txt"
        $testfiledata = "Corrupt_me_$i $($j.ToString("0000"))"
        Write-Host "[$(Get-Date)] Creating test file '$testfilename' with test file contents '$testfiledata'..."
        $data = [system.Text.Encoding]::Default.GetBytes($testfiledata)
        [io.file]::WriteAllBytes($testfilename, $data)
    }
}

# Give ReFS a few seconds to finish writing
Start-Sleep 5

# Write the volume cache?
#Write-VolumeCache -FileSystemLabel Test

# Dismount VHDs
1..$numdrives |%{ "[$(Get-Date)] Dismounting '$_.vhdx' to generate corruption..."
Dismount-VHD C:\$_.vhdx; Start-Sleep 5 }

# Create a hash table tracking how many drives we still need to corrupt based on remaining sets of files for corruption
$drivecorruptionset = @{}
for ($i = $skipfilesetzero; $i -le $numdrivestocorrupt; $i++) {
    $drivecorruptionset.Add($i, $null)
}

# Start introducting file corruption onto the drives you want to corrupt according to the drive search order
1..$numdrives | Sort-Object -Descending:$sortdescending |%{ $path = "C:\$_.vhdx"
    # Go through the remaining sets of files to create for corruption
    foreach ($drivekey in $drivecorruptionset.Keys | Sort) {
        $stringToSearch = "Corrupt_me_$drivekey"
        $enc = [system.Text.Encoding]::ASCII

        Write-Host "[$(Get-Date)] Searching '$_.vhdx' for '$stringToSearch'..."

        # Get the entire file contents as a byte array
        $byteArray = [System.IO.File]::ReadAllBytes($path)

        # look for string
        $m = [Regex]::Matches([Text.Encoding]::ASCII.GetString($byteArray), $stringToSearch)

        foreach ($match in $m) {
            # Corrupt the first binary bit of the character (e.g. converts ASCII space 00100000 to ASCII exclamation mark 00100001)
            [Byte]$bytetocorrupt = $byteArray[$match.Index + $match.length]
            [Byte]$corruptedbyte = $byteArray[$match.Index + $match.length] -bxor 1

            Write-Host "[$(Get-Date)] Found '$stringToSearch' at position $($match.Index) - corrupting following character from '$([System.Text.Encoding]::ASCII.GetString($bytetocorrupt))' to '$([System.Text.Encoding]::ASCII.GetString($corruptedbyte))'..."

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

# Verify the file corruption created on drives - match 'Corrupt' followed by any printable ASCII characters
1..$numdrives |%{ $data = "Corrupt[ -~]{10}"
Write-Host "[$(Get-Date)] Scanning '$_.vhdx' to verify uncorrupted or corrupted data before repair..."
Get-Content -Path c:\$_.vhdx -ReadCount 1000 | foreach { ($_ | Select-String $data -AllMatches).Matches.Value } }

# Mount VHDs
1..$numdrives |%{ Write-Host "[$(Get-Date)] Remounting '$_.vhdx' to test Integrity Streams corruption detection & repair..."
Mount-VHD C:\$_.vhdx; Start-Sleep 5 }

# Wait for the Storage Pool to return a Healthy status - see https://docs.microsoft.com/en-us/windows-server/storage/storage-spaces/storage-spaces-states#storage-pool-states
Do {
    Write-Host "[$(Get-Date)] Waiting for Storage Pool to reach Healthy status..."
    $StoragePoolStatus = Get-StoragePool -FriendlyName "Test"
} While ($StoragePoolStatus.HealthStatus -ne "Healthy")

# Write out current Storage Pool Status - should be Healthy
$StoragePoolStatus | Select-Object -Property HealthStatus, OperationalStatus, ReadOnlyReason | Format-Table

# See if we can now get the file contents (should always fail on drive set 0, but all other reads from drive sets should succeed and automatically repair if corrupted on the pool disk that Storage Spaces happens to try to access it from)
for ($i = $skipfilesetzero; $i -le $numdrivestocorrupt; $i++) {
    for ($j = 1; $j -le $numcorruptfiles; $j++) {
        if ($i -eq 0) { # Read from drive set 0. This is to check that remaining corrupted data can still be accessed when Set-FileIntegrity -Enforce $false is run on it and is not silently deleted 
            #Write-Host "[$(Get-Date)] Attempting to read 'T:\test$i.$($j.ToString("0000")).txt' with file integrity enforced (should fail since all files in this data set were deliberately corrupted)..."
            #try { Get-Content "T:\test$i.$($j.ToString("0000")).txt" -ErrorAction Stop }
            #catch {
            #    If ($Error[0].Exception.HResult -ne -2147024573) { # Expecting error 0x80070143 - ERROR_DATA_CHECKSUM_ERROR - 'A data integrity checksum error occurred. Data in the file stream is corrupt.'
            #        Write-Error $_ # If we get a different and unexpected error, display it!
            #    }
            #}

            # Disable blocking access to a file if integrity streams indicate data corruption - see https://docs.microsoft.com/en-us/powershell/module/storage/set-fileintegrity?view=windowsserver2022-ps
            Set-FileIntegrity -FileName "T:\test$i.$($j.ToString("0000")).txt" -Enforce $false

            Write-Host "[$(Get-Date)] Attempting to read 'T:\test$i.$($j.ToString("0000")).txt' with file integrity unenforced - should succeed in returning (corrupt) file contents..."
            Get-Content "T:\test$i.$($j.ToString("0000")).txt"
        } else {
            Write-Host "[$(Get-Date)] Attempting to read 'T:\test$i.$($j.ToString("0000")).txt' - should be able to read without errors..."
            Get-Content "T:\test$i.$($j.ToString("0000")).txt"

            # Run manual scrub/repair to ensure scan we have checked this file for corruption on every disk in the storage space
            Write-Host "[$(Get-Date)] Attempting manual scrub / repair on 'T:\test$i.$($j.ToString("0000")).txt'..."
            Repair-FileIntegrity "T:\test$i.$($j.ToString("0000")).txt"
        }
    }
}

# Give ReFS a few seconds to generate event logs
Start-Sleep 5

# Show ReFS events to see if repairs were reported
Write-Host "[$(Get-Date)] Reading event logs to verify corruption & any fixes are logged in System Event log..."
Get-WinEvent -FilterHashtable @{ StartTime=$scriptstarttime; LogName="System"; ProviderName="Microsoft-Windows-ReFS*"} | Format-Table

# Write the volume cache?
#Write-VolumeCache -FileSystemLabel Test

# Dismount VHDs
1..$numdrives |%{ Write-Host "[$(Get-Date)] Dismounting '$_.vhdx' to verify whether corruption was correctly detected & repaired on all drives..."
Dismount-VHD C:\$_.vhdx }

# Verify that it has been fixed - match 'Corrupt' followed by any printable ASCII characters
1..$numdrives |%{ $data = "Corrupt[ -~]{10}"
Write-Host "[$(Get-Date)] Scanning '$_.vhdx' for uncorrupted or corrupted data - all except set 0 should be uncorrupted..."
Get-Content -Path c:\$_.vhdx -ReadCount 1000 | foreach { ($_ | Select-String $data -AllMatches).Matches.Value } }
