﻿function Set-DiskPartition {
  <#
    .Synopsis
    Sets the content of a Disk using a source WIM or ISO
    .DESCRIPTION
    This command will copy the content of the SourcePath ISO or WIM and populate the 
    partitions found on the disk. You must supply the path to a valid WIM/ISO. You 
    should also include the index number for the Windows Edition to install. If the 
    recovery partitions are present the source WIM will be copied to the recovery 
    partition. Optionally, you can also specify an XML file to be inserted into the 
    OS partition as unattend.xml, any Drivers, WindowsUpdate (MSU) or Optional Features 
    you want installed. And any additional files to add.
    CAUTION: This command will replace the content partitions.
    .EXAMPLE
    PS C:\> Set-VHDPartition -DiskNumber 0 -SourcePath D:\wim\Win2012R2-Install.wim -Index 1 
    .EXAMPLE
    PS C:\> Set-VHDPartition -DiskNumber 0 -SourcePath D:\wim\Win2012R2-Install.wim -Index 1 -Confirm:$false -force -Verbose
    #>
  [CmdletBinding(SupportsShouldProcess = $true, 
    PositionalBinding = $true,
    ConfirmImpact = 'Medium')]
  Param
  (
    # Disk number, disk must exist
    [Parameter(Position = 0, Mandatory,
      HelpMessage = 'Disk Number based on Get-Disk')]
    [ValidateNotNullorEmpty()]
    [ValidateScript( {
        if (Get-Disk -Number $_) {
          $true
        }
        else {
          Throw "Disk number $_ does not exist."
        }
      })]
    [string]$DiskNumber,
        
    # Path to WIM or ISO used to populate VHDX
    [parameter(Position = 1, Mandatory = $true,
      HelpMessage = 'Enter the path to the WIM/ISO file')]
    [ValidateScript( {
        Test-Path -Path (Get-FullFilePath -Path $_ )
      })]
    [string]$SourcePath,
        
    # Index of image inside of WIM (Default 1)
    [int]$Index = 1,
        
    # Path to file to copy inside of VHD(X) as C:\unattent.xml
    [ValidateScript( {
        if ($_) {
          Test-Path -Path $_
        }
        else {
          $true
        }
      })]
    [string]$Unattend,

    # Native Boot does not have the boot code on the disk. Only usefull for VHD(X). 
    [switch]$NativeBoot,

    # Add payload for all removed features
    [switch]$AddPayloadForRemovedFeature,

    # Feature to turn on (in DISM format)
    [ValidateNotNullOrEmpty()]
    [string[]]$Feature,

    # Feature to remove (in DISM format)
    [ValidateNotNullOrEmpty()]
    [string[]]$RemoveFeature,

    # Feature Source path. If not provided, all ISO and WIM images in $sourcePath searched 
    [ValidateNotNullOrEmpty()]
    [ValidateScript( {
        Test-Path -Path $(Resolve-Path $_)
      })]
    [string]$FeatureSource,

    # Feature Source index. If the source is a .wim provide an index Default =1 
    [int]$FeatureSourceIndex = 1,

    # Path to drivers to inject
    [ValidateNotNullOrEmpty()]
    [ValidateScript( {
        Test-Path -Path $(Resolve-Path $_)
      })]
    [string[]]$Driver,

    # Path of packages to install via DSIM
    [ValidateNotNullOrEmpty()]
    [ValidateScript( {
        Test-Path -Path $(Resolve-Path $_)
      })]
    [string[]]$Package,

    # Files/Folders to copy to root of Winodws Drive (to place files in directories mimic the direcotry structure off of C:\)
    [ValidateNotNullOrEmpty()]
    [ValidateScript( {
        foreach ($Path in $_) {
          Test-Path -Path $(Resolve-Path $Path)
        }
      })]
    [string[]]$filesToInject,

    # Bypass the warning and about lost data
    [switch]$Force
  )
           
  
  Process {
    $SourcePath = $SourcePath | Get-FullFilePath

    if ($pscmdlet.ShouldProcess("[$($MyInvocation.MyCommand)] : Overwrite partitions inside [$Path] with content of [$SourcePath]",
        "Overwrite partitions inside [$Path] with contentce of [$SourcePath]? ",
        'Overwrite WARNING!')) {
      if ($Force -Or $pscmdlet.ShouldContinue('Are you sure? Any existin data will be lost!', 'Warning')) {
        $ParametersToPass = @{}
        foreach ($key in ('Whatif', 'Verbose', 'Debug')) {
          if ($PSBoundParameters.ContainsKey($key)) {
            $ParametersToPass[$key] = $PSBoundParameters[$key]
          }
        }
        #region ISO detection
        # If we're using an ISO, mount it and get the path to the WIM file.
        if (([IO.FileInfo]$SourcePath).Extension -ilike '.ISO') {
          # If the ISO isn't local, copy it down so we don't have to worry about resource contention
          # or about network latency.
          if (Test-IsNetworkLocation -Path $SourcePath) {
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] : Copying ISO [$(Split-Path -Path $SourcePath -Leaf)] to [$env:temp]"
            $null = & "$env:windir\system32\robocopy.exe" $(Split-Path -Path $SourcePath -Parent) $env:temp $(Split-Path -Path $SourcePath -Leaf)
            $SourcePath = "$($env:temp)\$(Split-Path -Path $SourcePath -Leaf)"
            
            $tempSource = $SourcePath
          }

          $isoPath = (Resolve-Path $SourcePath).Path

          Write-Verbose -Message "[$($MyInvocation.MyCommand)] : Opening ISO [$(Split-Path -Path $isoPath -Leaf)]"
          $openIso = Mount-DiskImage -ImagePath $isoPath -StorageType ISO -PassThru
          # Workarround for new drive letters in script modules
          $null = Get-PSDrive
          # Refresh the DiskImage object so we can get the real information about it.  I assume this is a bug.
          $openIso = Get-DiskImage -ImagePath $isoPath
          $driveLetter = ($openIso | Get-Volume).DriveLetter

          $SourcePath = "$($driveLetter):\sources\install.wim"

          # Check to see if there's a WIM file.
          Write-Verbose -Message "[$($MyInvocation.MyCommand)] : Looking for $($SourcePath)"
          if (!(Test-Path $SourcePath)) {
            throw 'The specified ISO does not appear to be valid Windows installation media.'
          }
        }
        #endregion
                
        #region WIM on network
        # Check to see if the WIM is local, or on a network location.  If the latter, copy it locally.
        if (Test-IsNetworkLocation -Path $SourcePath) {
          Write-Verbose -Message "[$($MyInvocation.MyCommand)] : Copying WIM $(Split-Path -Path $SourcePath -Leaf) to [$env:temp]"
          $null = & "$env:windir\system32\robocopy.exe" $(Split-Path -Path $SourcePath -Parent) $env:temp $(Split-Path -Path $SourcePath -Leaf)
          $SourcePath = "$($TempDirectory)\$(Split-Path -Path $SourcePath -Leaf)"
            
          $tempSource = $SourcePath
        }
        $SourcePath = (Resolve-Path $SourcePath).Path
        #endregion
                
              
        try {                   
          #region Assign Drive Letters
          foreach ($partition in (Get-Partition -DiskNumber $DiskNumber | 
                Where-Object -Property Type -NE -Value Reserved)) {
            $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
          } 
          # Workarround for new drive letters in script modules
          $null = Get-PSDrive
          Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Partition Table"
          Write-Verbose -Message (Get-Partition -DiskNumber $DiskNumber |
              Select-Object -Property PartitionNumber, DriveLetter, Size, Type|
              Out-String)
          #endregion

          #region get partitions
          $RecoveryToolsPartition = Get-Partition -DiskNumber $DiskNumber | 
            Where-Object -Property Type -EQ -Value Recovery | 
            Select-Object -First 1 
          if ((Get-Partition -DiskNumber $DiskNumber | 
                Where-Object -Property Type -EQ -Value Recovery).count -gt 1) {
            $RecoveryImagePartition = Get-Partition -DiskNumber $DiskNumber | 
              Where-Object -Property Type -EQ -Value Recovery | 
              Select-Object -Last 1 
          }
          $WindowsPartition = Get-Partition -DiskNumber $DiskNumber | 
            Where-Object -Property Type -EQ -Value Basic| 
            Select-Object -First 1 
          $SystemPartition = Get-Partition -DiskNumber $DiskNumber | 
            Where-Object -Property Type -EQ -Value System| 
            Select-Object -First 1 

          $DiskLayout = 'UEFI'
          if (-not ($WindowsPartition -and $SystemPartition)) {
            $WindowsPartition = Get-Partition -DiskNumber $DiskNumber | 
              Where-Object -Property Type -EQ -Value IFS| 
              Select-Object -First 1 
            $SystemPartition = $WindowsPartition
            $DiskLayout = 'BIOS'
          }
          
          if (Get-Partition -DiskNumber $DiskNumber | 
              Where-Object -Property Type -EQ -Value FAT32 ) {
            $DiskLayout = 'WindowsToGo'
          }

          #endregion

          #region Recovery Image
          if ($RecoveryImagePartition) {
            #copy the WIM to recovery image partition as Install.wim
            $recoverfolder = Join-Path -Path "$($RecoveryImagePartition.DriveLetter):" -ChildPath 'Recovery'
            $null = mkdir -Path $recoverfolder
            $recoveryPath = Join-Path -Path $recoverfolder -ChildPath 'install.wim'
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] Recovery Image Partition [$($RecoveryImagePartition.PartitionNumber)] : copying [$SourcePath] to [$recoveryPath]"
            Copy-Item -Path $SourcePath -Destination $recoveryPath -ErrorAction Stop
          } # end if Recovery
          #endregion

          #region Windows partition 
          if ($WindowsPartition) {
            $WinPath = Join-Path -Path "$($WindowsPartition.DriveLetter):" -ChildPath '\'
            $windir = Join-Path -Path $WinPath -ChildPath Windows
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] Windows Partition [$($WindowsPartition.partitionNumber)] : Applying image from [$SourcePath] to [$WinPath] using Index [$Index]"
            $null = Expand-WindowsImage -ImagePath $SourcePath -Index $Index -ApplyPath $WinPath -ErrorAction Stop

            #region Modify the OS with Drivers, Active Features and Packages
            if ($Driver) {
              Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Adding Windows Drivers to the Image"

              $Driver | ForEach-Object -Process 
              {
                Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Driver path: [$PSItem]"
                $Dism = Add-WindowsDriver -Path $WinPath -Recurse -Driver $PSItem
              }
            }
            if ($filesToInject) {
              foreach ($filePath in $filesToInject) {
                Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] Windows Partition [$($WindowsPartition.partitionNumber)] : Adding files from $filePath"
                $recurse = $false
                if (Test-Path $filePath -PathType Container) {
                  $recurse = $true
                }
                Copy-Item -Path $filePath -Destination $WinPath -Recurse:$recurse
              }
            }
                        
                        
            if ($Unattend) {
              try {
                Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] Windows Partition [$($WindowsPartition.partitionNumber)] : Adding Unattend.xml ($Unattend)"
                Copy-Item $Unattend -Destination "$WinPath\unattend.xml"
              }
              catch {
                Write-Error -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Error Installing Windows Feature "
                throw $_.Exception.Message
              }
            }
            if ($AddPayloadForRemovedFeature) {
              $Feature = $Feature + (Get-WindowsOptionalFeature -Path $WinPath | Where-Object -Property state -EQ -Value 'DisabledWithPayloadRemoved' ).FeatureName
            }

            If ($Feature) {
              try { 
                Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Installing Windows Feature(s) : Colecting posible source paths"
                $FeatureSourcePath = @()
                $MountFolderList = @()
                
                # ISO
                if ($driveLetter) {
                  $FeatureSourcePath += Join-Path -Path "$($driveLetter):" -ChildPath 'sources\sxs'
                }
                
                $notWinPE = $true
                if ((Resolve-Path -Path $env:temp).drive.name -eq 'X') {
                  $notWinPE = $false
                  Write-Warning "WinPE does not support Mounting WIM, Feature sources must be present in the image OR -FeatureSource must be a Folder"}
                if ($FeatureSource) {
                  Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Installing Windows Feature(s) : Source Path provided [$FeatureSource]"
                  if (($FeatureSource |
                        Resolve-Path |
                        Get-Item ).PSIsContainer -eq $true ) {
                    Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Installing Windows Feature(s) : Source Path [$FeatureSource] in folder"
                    $FeatureSourcePath += $FeatureSource
                  }
                  elseif ((($FeatureSource |
                        Resolve-Path |
                        Get-Item ).extension -like '.wim') -and $notWinPE) { 
                    #$FeatureSourcePath += Convert-Path $FeatureSource
                    $MountFolder = [System.IO.Directory]::CreateDirectory((Join-Path -Path $env:temp -ChildPath ([System.IO.Path]::GetRandomFileName().split('.')[0])))
                    $MountFolderList += $MountFolder.FullName
                    Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Installing Windows Feature(s) : Mounting Source [$FeatureSource] Index [$FeatureSourceIndex]"
                    $null = Mount-WindowsImage -ImagePath $FeatureSource -Index $FeatureSourceIndex -Path  $MountFolder.FullName -ReadOnly
                    $FeatureSourcePath += Join-Path -Path $MountFolder.FullName -ChildPath 'Windows\WinSxS'
                  }
                  else {
                    Write-Warning -Message "$FeatureSource is not a .wim or folder"
                  }
                }
                elseif ($notWinPE) { #NO $FeatureSource
                  
                  $images = Get-WindowsImage -ImagePath $SourcePath
                                    
                  foreach ($image in $images) {
                    $MountFolder = [System.IO.Directory]::CreateDirectory((Join-Path -Path $env:temp -ChildPath ([System.IO.Path]::GetRandomFileName().split('.')[0])))
                    $MountFolderList += $MountFolder.FullName
                    Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Installing Windows Feature(s) : Mounting Source [$SourcePath] [$($image.ImageIndex)] [$($image.ImageName)] to [$($MountFolder.FullName)] "
                    $null = Mount-WindowsImage -ImagePath $SourcePath -Index $image.ImageIndex -Path  $MountFolder.FullName -ReadOnly
                    $FeatureSourcePath += Join-Path -Path $MountFolder.FullName -ChildPath 'Windows\WinSxS'
                  }
                } #end if FeatureSource
                if ($FeatureSourcePath.count -gt 0) { 
                  Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Installing Windows Feature(s) [$Feature] to the Image : Search Source Path [$FeatureSourcePath]"
                  $null = Enable-WindowsOptionalFeature -Path $WinPath -All -FeatureName $Feature -Source $FeatureSourcePath
                }
                else { 
                Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Installing Windows Feature(s) [$Feature] to the Image : No Source Path"
                  $null = Enable-WindowsOptionalFeature -Path $WinPath -All -FeatureName $Feature 
                }
              }
              catch {
                Write-Error -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Error Installing Windows Feature "
                throw $_.Exception.Message
              }
              finally { 
                foreach ($MountFolder in $MountFolderList) {
                  $null = Dismount-WindowsImage -Path $MountFolder -Discard
                  Remove-Item $MountFolder
                }
              }
            }

            if ($Package) {
              Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Adding Windows Packages to the Image"
            
              $Package | ForEach-Object -Process {
                Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Package path: [$PSItem]"
                $Dism = Add-WindowsPackage -Path $WinPath -PackagePath $PSItem
              }
            }
            if ($RemoveFeature) {
              Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Removing Windows Features from the Image"
            
              $Package | ForEach-Object -Process {
                Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Package path: [$PSItem]"
                try {
                  $null = Disable-WindowsOptionalFeature -Path $WinPath -FeatureName $Feature @ParametersToPass
                }
                catch {
                  Write-Error -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Error Removeing Windows Feature [$Feature] "
                  throw $_.Exception.Message
                }
              }
            }
            #endregion
          }
          else {
            throw 'Unable to find OS partition'
          }
          #endregion
 
          #region System partition
          if ($SystemPartition -and (-not ($NativeBoot))) {
            $systemDrive = "$($SystemPartition.driveletter):"
                        
 
            $bcdBootArgs = @(
              "$($WinPath)Windows", # Path to the \Windows on the Disk
              "/s $systemDrive", # Specifies the volume letter of the drive to create the \BOOT folder on.
              '/v'                        # Enabled verbose logging.
            )

            #if ($UEFICapable) {
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Disk Layout [$DiskLayout]"
            switch ($DiskLayout) {        
              'UEFI' {
                $bcdBootArgs += '/f UEFI'   # Specifies the firmware type of the target system partition
              }
              'BIOS' {
                $bcdBootArgs += '/f BIOS'   # Specifies the firmware type of the target system partition
              }

              'WindowsToGo' {    
                # Create entries for both UEFI and BIOS if possible
                if (Test-Path -Path "$($windowsDrive)\Windows\boot\EFI\bootmgfw.efi") {
                  $bcdBootArgs += '/f ALL'
                }     
              }
            }
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] System Partition [$($SystemPartition.partitionNumber)] : Running [$windir\System32\bcdboot.exe] -> $bcdBootArgs" 
            Run-Executable -Executable "$windir\System32\bcdboot.exe" -Arguments $bcdBootArgs @ParametersToPass

            # The following is added to mitigate the VMM diff disk handling
            # We're going to change from MBRBootOption to LocateBootOption.
            if ($DiskLayout -eq 'BIOS') {
              Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] System Partition [$($SystemPartition.partitionNumber)] : Fixing the Device ID in the BCD store on [$($VHDFormat)]"
              Run-Executable -Executable "$windir\System32\bcdboot.exe" -Arguments (
                "/store $($WinPath)boot\bcd", 
                "/set `{bootmgr`} device locate"
              )
              Run-Executable -Executable "$windir\System32\bcdboot.exe" -Arguments (
                "/store $($WinPath)boot\bcd", 
                "/set `{default`} device locate"
              )
              Run-Executable -Executable "$windir\System32\bcdboot.exe" -Arguments (
                "/store $($WinPath)boot\bcd", 
                "/set `{default`} osdevice locate"
              )
            }
          }
          #endregion               

          #region Recovery Tools
          if ($RecoveryToolsPartition) {
            $recoverfolder = Join-Path -Path "$($RecoveryToolsPartition.DriveLetter):" -ChildPath 'Recovery'
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] Recovery Tools Partition [$($RecoveryToolsPartition.partitionNumber)] : Register Reovery Image "
            Start-Process -NoNewWindow -Wait -FilePath "$windir\System32\reagentc.exe" -ArgumentList "/setosimage /path $recoverfolder /index $Index /target $windir"  -NoNewWindow
                        
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] Recovery Tools Partition [$($RecoveryToolsPartition.partitionNumber)] : Creating Recovery\WindowsRE folder [$($RecoveryToolsPartition.driveletter):\Recovery\WindowsRE]"
            $repath = mkdir -Path "$($RecoveryToolsPartition.driveletter):\Recovery\WindowsRE"
            Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] Recovery Tools Partition [$($RecoveryToolsPartition.partitionNumber)] : Copying [$($WindowsPartition.DriveLetter):\Windows\System32\recovery\winre.wim] to [$($repath.fullname)]"
            #the winre.wim file is hidden
            Get-ChildItem -Path "$($WindowsPartition.DriveLetter):\Windows\System32\recovery\winre.wim" -Hidden |
              Copy-Item -Destination $repath.FullName
          }
          #endregion
        }
        catch {
          Write-Error -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Error setting partition content "
          throw $_.Exception.Message
        }
        finally {
          Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Removing Drive letters"
          Get-Partition -DiskNumber $DiskNumber |
            Where-Object -FilterScript {
            $_.driveletter
          }  |
            Where-Object -Property Type -NE -Value 'Basic' |
            Where-Object -Property Type -NE -Value 'IFS' |
            ForEach-Object -Process {
            $dl = "$($_.DriveLetter):"
            $_ |
              Remove-PartitionAccessPath -AccessPath $dl
          }
          #dismount
          if ($isoPath -and (Get-DiskImage $isoPath).Attached) {
            $null = Dismount-DiskImage -ImagePath $isoPath
          }
          Write-Verbose -Message "[$($MyInvocation.MyCommand)] [$DiskNumber] : Finished"
        }
      }
      else {
        Write-Warning -Message 'Process aborted by user'
      }
    }
    else {
      # Write-Warning 'Process aborted by user'
    }
       
  }
}