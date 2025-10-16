Script for testing Microsoft ReFS's data integrity functionality, including automatic repair of corrupt data - see https://www.reddit.com/r/DataHoarder/comments/scdclm/testing_refs_data_integrity_streams_corrupt_data/ for detailed information

The above forum post is now closed, but the original is posted here. Free to raise any further concerns or feedback via GitHub issues :)

--

**Testing ReFS data integrity streams / corrupt data functionality automatically using PowerShell**

Does ReFS detect and protect data corruption from 'bit rot' if using Integrity Streams on a resiliency enabled Storage Space [as advertised](https://learn.microsoft.com/en-us/windows-server/storage/refs/integrity-streams#how-it-works)?

I wanted to follow up on the post '[Testing Windows ReFS Data Integrity / Bit Rot Handling — Results](https://www.reddit.com/r/DataHoarder/comments/iow60w/testing_windows_refs_data_integrity_bit_rot/?ref=share&ref_source=link)' by u/MyAccount42:

The original post discovered some concerning failures in ReFS error logging / reporting, data corruption and 'bit rot' detection & repair, and Storage Spaces in general. I found a [post in the Veeam forums](https://forums.veeam.com/veeam-backup-replication-f2/refs-data-corruption-detection-t53098.html#p345182) containing PowerShell which could be used to test if this was the case. I have taken that script and modified it, since Microsoft have been [working on ReFS recently](https://gist.github.com/0xbadfca11/da0598e47dd643d933dc), and I wanted to see if the bugs still remain.

The script below allows anyone to see if these issues still exist in current and future versions of Windows client and server.

[**https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/Test-ReFSDataCorruption.ps1**](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/Test-ReFSDataCorruption.ps1)

EDIT 10/10/2022: If you would like to see these issues resolved, please [upvote](https://aka.ms/AAice7g) the problem on the Windows Feedback Hub (if the link doesn't work, you may need to sign in to the Feedback Hub app **before** opening the above link, or [register for the Windows Insider program](https://www.microsoft.com/en-us/windowsinsider/register)).

EDIT 11/11/2022: In the last month I have managed to raise this issue with the relevant manager at Microsoft and the relevant engineering teams are now engaged, which is a good bit of progress from my point of view!

EDIT 11/07/2023: Issues remain in ReFS 3.10 ([two](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/WindowsServer22H2Preview-1.txt) [tests](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/WindowsServer22H2Preview-2.txt), performed using the 'Microsoft Server Operating Systems Preview' Marketplace entry in Microsoft Azure)

**EDIT 03/01/2025: Issues remain in ReFS 3.14 (**[**test**](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/WindowsServer2025.txt) **performed using Windows Server 2025 Datacenter Azure Edition 24H2 and** [**also**](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/Windows1124H2.txt) **using Windows 11 24H2). It seems that the 'Error Logging' issues may be resolved (so that all corruption is reported) but ReFS still fails to recover from single-bit corruption errors and can even intermittently corrupt 'good' data with 'bad' data. Do not trust ReFS integrity streams with data which you wish to recover.**

**EDIT 10/10/2025: This post will continue to be updated and monitored for as long as Reddit allow. If this post is ever locked for comments, please raise further comments or questions, or look for updates, at the Github repo here:** [**https://github.com/Borgquite/Test-ReFSDataCorruption/**](https://github.com/Borgquite/Test-ReFSDataCorruption/)

# Current script results

In the [original post](https://www.reddit.com/r/DataHoarder/comments/iow60w/testing_windows_refs_data_integrity_bit_rot/?ref=share&ref_source=link), u/MyAccount42 reported a number of errors. In running this script, my results as of 10th October 2022 on the latest build of Windows 11 Enterprise 22H2 (OS Build 22621.525) using ReFS 3.9, and on Windows Server 2022 Datacenter 21H2 (OS Build 20348.524) using ReFS 3.7, are as follows:

|Scenario|Verdict|Notes|
|:-|:-|:-|
|Single ReFS Drive - Data Integrity Checksumming / Problem Detection|Working as advertised|Working as advertised (with some variation in how programs display errors)|
|Single ReFS Drive - Corrupted File Handling|Working as advertised|[Similar to ZFS](https://www.truenas.com/community/threads/single-drive-zfs.35515/), [ReFS can only repair corruption if it is hosted on a resilient mirror or parity space](https://docs.microsoft.com/en-us/windows-server/storage/refs/integrity-streams#how-it-works) and simply returns an error if a file is corrupted. I was able to regain access to the (corrupted) file contents using Set-FileIntegrity -Enforce $False. *I was not able to replicate the ReFS* [*Event ID 513*](https://social.technet.microsoft.com/Forums/lync/en-US/17c879b2-8b4b-4692-8c8d-201a062d1ec8/recovery-after-refs-events-133-513-apparent-data-loss-on-dual-parity?forum=winserverfiles) *errors reported elsewhere where if all copies of a file are corrupted the files are permanently inaccessible and are 'removed from the file system namespace' with this script but since this behaviour is shared with other resilient filesystems* [*such as ZFS*](https://muc.lists.freebsd.fs.narkive.com/TuQkCunv/reading-a-corrupted-file-on-zfs) *it does not seem to be a bug.*|
|Single ReFS Drive - Error Logging / Reporting - Repairable Corruption|**Bad**|When ReFS encounters a first corrupted file, it creates a ReFS event in the System Event log - but for some reason it is duplicated 5 times for the same file ([see sample log](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/Windows1122H2.txt)). Subsequent ReFS errors related to other corrupted files (within one or two hours of the first error) appear to be completely dropped and never show up in Event Viewer. The ReFS documentation states the intended behaviour should be that '[ReFS will record all corruptions in the System Event Log](https://docs.microsoft.com/en-us/windows-server/storage/refs/integrity-streams#how-it-works)' but this is not happening. Since the detection of errors on a disk is a critical part of monitoring and replacing disks in any redundant disk setup, this is a **serious bug**.|
|Single ReFS Drive - Error Logging / Reporting - Unrepairable Corruption|**Bad**|I also saw the incorrect behaviour where the ReFS event log reports that it "was able to correct" an error if you turn the -Enforce flag off and access a completely corrupted file despite the fact that that is impossible ([see second sample log](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/Windows10Enterprise21H2-SampleLog-2) \- need to enable file set 0 to replicate).|
|ReFS + Mirrored Storage Space - File corrupted on both disks - uncorrectable error|Working as advertised|I also found that if a file is corrupt on both disks, ReFS can detect and allow the file to be accessed if -Enforce is off (with the same quirks about error reporting described above).|
|ReFS + Mirrored Storage Space - Self-healing - automatic repair|**Bad**|If ReFS is hosted on a resilient Storage Space, ReFS should be able to automatically repair the corrupted file. I found that this worked some of the time, but occasionally it still failed for no apparent reason. The original poster found that this depended on which drive was corrupted, and I have found the same behaviour. The behaviour does not occur consistently and some of the time it works fine, but there are other occasions when the error persists (see the same [sample log](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/Windows1122H2.txt) above). I did not manage to identify a pattern to these failures since unfortunately they occcured randomly, sometimes days between testing attempts, sometimes every time I tested - and seemed to depend on random factors like when the system last rebooted, but I have done my best to modify the script behaviour to reliably reproduce the error as much as possible. This is obviously a **serious bug**.|
|ReFS + Mirrored Storage Space - Self-healing - retention of good data|**Bad**|I also found that sometimes after Repair-FileIntegrity is run on a set of files to repair them, instead of copying the 'good' data onto the 'bad' disk, it can overwrite the 'good' data with the 'bad' data from the other drive (see the same [sample log](https://github.com/Borgquite/Test-ReFSDataCorruption/blob/main/Windows1122H2.txtg) above for example) - the script ends with both copies of the data showing 'Corrupt\_me\_x!xxxx' (bad) rather than 'Corrupt\_me\_x xxxx' (good) - even though when the script corrupted the VHDs it only affected one! Because the files are relatively small, it could be a peculiarity of the repair function (does it repair files on a file-by-file basis, or does it 'repair' an entire block, rather than individual files?) Either way, this is a **serious bug**.|
|Storage Spaces|Working as advertised|I did not see the issue where Storage Spaces can overwrite your mirror's good copy with a bad copy; the original poster may have encountered this issue as a result of using removable media which is [not officially supported](https://docs.microsoft.com/en-us/windows-server/storage/refs/refs-overview#feature-comparison) with ReFS.|

# Script functionality

The script currently works along these lines:

* Set up testing environment (number of disks, simple/mirror/parity volumes, two-way/three-way mirror or single/dual parity, other setup for tests)
* Create VHDs on the C: drive as the basis of the ReFS Storage Spaces pool
* Create the Storage Pool, create a single ReFS volume on top, mount it
* Create a set of files on the pool called 'testx.xxxx.txt'. Each set will be found on a single disk and corrupted. *Each set is made up of multiple files within the set to make sure we test how ReFS behaves when multiple files are corrupted.*
* Dismount the volume and create corruption in each file set (only one set is corrupted per disk searched to ensure there is always a 'good' copy left somewhere in the Storage Space - unless you set it to create file set 0, in which case file set 0 is corrupted on *every* drive to allow testing that scenario)
* Manually search the VHDs to verify the uncorrupted / corrupted status of each drive before attempting repair
* Remount the volume and attempt to get file contents (including setting Enforce to $false on set 0, to test the ability to still access data even when a file is completely corrupted)
* Perform manual scrub/repair on the files to ensure every copy of the data has corruption detected & repaired
* Check the event logs for ReFS corruption / repair event logs (at least one event should be generated for each corrupted file with correct info included)
* Dismount the volume again
* Manually search the VHDs for potentially corrupted data to check the outcome of any repair process

NB While the script itself doesn't use Hyper-V, it does need the Hyper-V PowerShell modules installed to get the New-VHD cmdlet in the script to work. The following command should do this on desktop Windows:

    DISM.exe /Online /Enable-Feature /All /FeatureName:Microsoft-Hyper-V

and on Windows Servers:

    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart

# Summary

I have raised this issue with Microsoft Professional Support on 26/4/2022 (#2204260040003921), but they were unwilling to acknowledge that the bug existed, or accept the case, advising me to submit 'feedback' via the [Feedback Hub](https://support.microsoft.com/en-us/windows/send-feedback-to-microsoft-with-the-feedback-hub-app-f59187f8-8739-22d6-ba93-f66612949332) application - I have done so at the [following location](https://aka.ms/AAice7g) \- if the link doesn't work, you may need to sign in to the Feedback Hub app **before** opening the above link, or [register for the Windows Insider program](https://www.microsoft.com/en-us/windowsinsider/register).

EDIT: As of September 2025 the above Feedback Hub issue is no longer available - it appears to have been removed/deleted, not on my part. I have therefore attempted all possible avenues to report this issue. It is unclear whether Microsoft are seeking to resolve this in any way, so I would advise to steer well clear of Integrity Streams with ReFS until further notice.

It should be easy to get the event reporting errors resolved, since these can be can be easily reproduced; the self-healing issues may be harder to replicate but badly need reporting nonetheless. If you would like to test a 2-way / 3-way / parity Storage Space with any number of disks, you can modify the variables at the start of the script to achieve what you need. If you would like to test it on Windows Server as your potential use case, you should be able to download the [Evaluation editions of Windows Server](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-server) from Microsoft and test it using Hyper-V, although I have to say I have found Windows and Windows Server to behave largely identically (you may need nested virtualisation enabled to get the Hyper-V components within the virtual machine). If you find any issues are resolved please post them below and I'll try to keep the post updated with new information if the situation improves.

I can't help with testing Storage Spaces Direct via the script (although the underlying technology is probably the same so I suspect it's broken there too). It should be possible to use the same method to test SSD with a bit of work if you wanted to though.

I am disappointed that these issues still remain in ReFS nearly ~~9~~ ~~10~~ ~~11~~ ~~12~~ 13 years after the original release. I suspect many people use it unthinkingly, trusting that it will 'just work'. My ultimate goal is to see these bugs acknowledged, accepted, and resolved, but at this point in time if you are using ReFS with Integrity Streams enabled on resilient Storage Spaces, based on this research your data is more, not less vulnerable to data corruption and bitrot.
