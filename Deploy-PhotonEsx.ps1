#Requires -Version 5.0
#Requires -Modules @{ ModuleName="ScriptLogger"; ModuleVersion="2.0.0" }
#Requires -Modules @{ ModuleName="ScriptConfig"; ModuleVersion="2.0.0" }
#Requires -Modules @{ ModuleName="VMware.PowerCLI"; ModuleVersion="10.0.0" }

function New-IsoFile {
    <#
    .Synopsis
    Creates a new .iso file
    .Description
    The New-IsoFile cmdlet creates a new .iso file containing content from chosen folders
    .Example
    New-IsoFile "c:\tools","c:Downloads\utils"
    This command creates a .iso file in $env:temp folder (default location) that contains c:\tools and c:\downloads\utils folders. The folders themselves are included at the root of the .iso image.
    .Example 
    New-IsoFile -FromClipboard -Verbose 
    Before running this command, select and copy (Ctrl-C) files/folders in Explorer first.
    .Example
    dir c:\WinPE | New-IsoFile -Path c:\temp\WinPE.iso -BootFile "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\efisys.bin" -Media DVDPLUSR -Title "WinPE"
    This command creates a bootable .iso file containing the content from c:\WinPE folder, but the folder itself isn't included. Boot file etfsboot.com can be found in Windows ADK. Refer to IMAPI_MEDIA_PHYSICAL_TYPE enumeration for possible media types: http://msdn.microsoft.com/en-us/library/windows/desktop/aa366217(v=vs.85).aspx
    .Notes 
    NAME:New-IsoFile
    AUTHOR: Chris Wu
    URL : https://gallery.technet.microsoft.com/scriptcenter/New-ISOFile-function-a8deeffd
    LASTEDIT: 03/23/2016 14:46:50
    #>

    [CmdletBinding(DefaultParameterSetName='Source')]Param( 
    [parameter(Position=1,Mandatory=$true,ValueFromPipeline=$true, ParameterSetName='Source')]$Source,
    [parameter(Position=2)][string]$Path = "$env:temp\$((Get-Date).ToString('yyyyMMdd-HHmmss.ffff')).iso",
    [ValidateScript({Test-Path -LiteralPath $_ -PathType Leaf})][string]$BootFile = $null, 
    [ValidateSet('CDR','CDRW','DVDRAM','DVDPLUSR','DVDPLUSRW','DVDPLUSR_DUALLAYER','DVDDASHR','DVDDASHRW','DVDDASHR_DUALLAYER','DISK','DVDPLUSRW_DUALLAYER','BDR','BDRE')][string] $Media = 'DVDPLUSRW_DUALLAYER',
    [string]$Title = (Get-Date).ToString("yyyyMMdd-HHmmss.ffff"),
    [switch]$Force, 
    [parameter(ParameterSetName='Clipboard')][switch]$FromClipboard
    ) 
    
    Begin {
        ($cp = new-object System.CodeDom.Compiler.CompilerParameters).CompilerOptions = '/unsafe'
        if (!('ISOFile' -as [type])) {
            Add-Type -CompilerParameters $cp -TypeDefinition `
@' 
            public class ISOFile { 
                public unsafe static void Create(string Path, object Stream, int BlockSize, int TotalBlocks) {
                    int bytes = 0;
                    byte[] buf = new byte[BlockSize];
                    var ptr = (System.IntPtr)(&bytes);
                    var o = System.IO.File.OpenWrite(Path);
                    var i = Stream as System.Runtime.InteropServices.ComTypes.IStream;
                    if (o != null) {
                        while (TotalBlocks-- > 0) {
                            i.Read(buf, BlockSize, ptr); o.Write(buf, 0, bytes);
                        }
                        o.Flush(); o.Close();
                    }
                }
            }
'@
        }

        if ($BootFile) { 
            if('BDR','BDRE' -contains $Media) {
                Write-Warning "Bootable image doesn't seem to work with media type $Media"
            }
            ($Stream = New-Object -ComObject ADODB.Stream -Property @{Type=1}).Open()# adFileTypeBinary
            $Stream.LoadFromFile((Get-Item -LiteralPath $BootFile).Fullname)
            ($Boot = New-Object -ComObject IMAPI2FS.BootOptions).AssignBootImage($Stream)
        } 

        $MediaType = @('UNKNOWN','CDROM','CDR','CDRW','DVDROM','DVDRAM','DVDPLUSR','DVDPLUSRW','DVDPLUSR_DUALLAYER','DVDDASHR','DVDDASHRW','DVDDASHR_DUALLAYER','DISK','DVDPLUSRW_DUALLAYER','HDDVDROM','HDDVDR','HDDVDRAM','BDROM','BDR','BDRE')

        Write-Verbose -Message "Selected media type is $Media with value $($MediaType.IndexOf($Media))"
        ($Image = New-Object -com IMAPI2FS.MsftFileSystemImage -Property @{VolumeName=$Title}).ChooseImageDefaultsForMediaType($MediaType.IndexOf($Media))

        if (!($Target = New-Item -Path $Path -ItemType File -Force:$Force -ErrorAction SilentlyContinue)) {
            Write-Error -Message "Cannot create file $Path. Use -Force parameter to overwrite if the target file already exists."; break
        }
    }

    Process {
        if($FromClipboard) {
            if($PSVersionTable.PSVersion.Major -lt 5) {
                Write-Error -Message 'The -FromClipboard parameter is only supported on PowerShell v5 or higher'; break
            }
            $Source = Get-Clipboard -Format FileDropList
        }

        foreach($item in $Source) {
            if($item -isnot [System.IO.FileInfo] -and $item -isnot [System.IO.DirectoryInfo]) {
                $item = Get-Item -LiteralPath $item
            }

            if($item) {
                Write-Verbose -Message "Adding item to the target image: $($item.FullName)"
                try {
                    $Image.Root.AddTree($item.FullName, $true)
                } catch {
                    Write-Error -Message ($_.Exception.Message.Trim() + ' Try a different media type.')
                }
            }
        }
    }

    End {
        if ($Boot) {
            $Image.BootImageOptions=$Boot
        }
        $Result = $Image.CreateResultImage()
        [ISOFile]::Create($Target.FullName,$Result.ImageStream,$Result.BlockSize,$Result.TotalBlocks)
        Write-Verbose -Message "Target image ($($Target.FullName)) has been created"
        $Target
    }
}

if (!(Get-ChildItem -Path ".\cloud-init" -ErrorAction SilentlyContinue)){
    Try{
        New-Item -Path "cloud-init" -ItemType:Directory -ErrorAction Stop
    } Catch {
        Write-ErrorLog -Message "Error creating .\cloud-init"
    }
}
$deployDir = Get-ChildItem -Directory -Path ".\" | Where-Object Name -eq deployments
$scriptLogger = Start-ScriptLogger -Path "$deployDir\deploy-master.log" -Format '{0:yyyy-MM-dd}`t{0:HH:mm:ss}`t{1}`t{2}`t{3,-11}`t{4}' -Encoding 'UTF8' -NoEventLog -Level Information
$curGuid = [guid]::NewGuid()
Write-InformationLog -Message "$($curGuid.Guid): New GUID Created"
#Start ScriptLogger module

Try { 
    New-Item .\cloud-init\$curGuid
} Catch {
    Write-ErrorLog -Message "$($curGuid.Guid): Error creating GUID directory"
} Finally {
    Write-InformationLog -Message "$($curGuid.Guid): Created GUID directory"
}

try {
    $value = do-thing -erroraction 'SilentlyContinue'
    if ($value) {
        write-log "Yay!"
    } else {
        $Error = ":("
        write-log $Error
        Throw $Error
    }
} Catch {
    # do something else with the error. Could have write-log down here too and then do Write-Log $_
}