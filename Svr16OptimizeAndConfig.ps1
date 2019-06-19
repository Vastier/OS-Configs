<#	
    .SYNOPSIS
        Applies Windows Server 16 Optimizations and configurations
    
    .DESCRIPTION
		Applies Windows Server 16 Optimizations and configurations.
        Utilizes LGPO.exe to apply group policy item where neceassary.
        Utilizes MDT/SCCM TaskSequence property control
            Configurable using custom variables in MDT/SCCM

    .INFO
        Author:         Richard Tracy
        Email:          richard.tracy@hotmail.com
        Twitter:        @rick2_1979
        Website:        www.powershellcrack.com
        Last Update:    06/18/2019
        Version:        1.0.0
        Thanks to:      unixuser011,W4RH4WK,TheVDIGuys,cluberti,JGSpiers
 
    .DISCLOSURE
        ALL INFORMATION HERE IS PROVIDED "AS IS." THIS SCRIPT HAS NO WARRANTY OR GUARANTEE TO FIX OR RESOLVE SYSTEM CONFIGURATIONS. 
        BY USING OR DISTRIBUTING THIS SCRIPT, YOU AGREE THAT IN NO EVENT SHALL RICHARD TRACY OR ANY AFFILATES BE HELD LIABLE FOR ANY DAMAGES
        WHATSOEVER RESULTING FROM USING OR DISTRIBUTION OF THIS SCRIPT, INCLUDING, WITHOUT LIMITATION, ANY SPECIAL, CONSEQUENTIAL, 
        INCIDENTAL OR OTHER DIRECT OR INDIRECT DAMAGES. BACKUP UP ALL DATA BEFORE PROCEEDING. 
    
    .CHANGE LOG
        1.0.0 - Jun 18, 2019 - initial 
#>
 
##*===========================================================================
##* FUNCTIONS
##*===========================================================================

Function Test-IsISE {
  # trycatch accounts for:
  # Set-StrictMode -Version latest
  try {    
      return ($null -ne $psISE);
  }
  catch {
      return $false;
  }
}
Function Get-ScriptPath {
  # Makes debugging from ISE easier.
  if ($PSScriptRoot -eq "")
  {
      if (Test-IsISE)
      {
          $psISE.CurrentFile.FullPath
          #$root = Split-Path -Parent $psISE.CurrentFile.FullPath
      }
      else
      {
          $context = $psEditor.GetEditorContext()
          $context.CurrentFile.Path
          #$root = Split-Path -Parent $context.CurrentFile.Path
      }
  }
  else
  {
      #$PSScriptRoot
      $PSCommandPath
      #$MyInvocation.MyCommand.Path
  }
}

Function Get-SMSTSENV{
  param(
      [switch]$ReturnLogPath
  )
  
  Begin{
      ## Get the name of this function
      [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
      
      if (-not $PSBoundParameters.ContainsKey('Verbose')) {
        $VerbosePreference = $PSCmdlet.SessionState.PSVariable.GetValue('VerbosePreference')
      }
  }
  Process{
      If(${CmdletName}){$prefix = "${CmdletName} ::" }Else{$prefix = "" }

      try{
          # Create an object to access the task sequence environment
          $Script:tsenv = New-Object -COMObject Microsoft.SMS.TSEnvironment
          Write-Verbose ("{0}Task Sequence environment detected!" -f $prefix)
      }
      catch{
          Write-Verbose ("{0}Task Sequence environment not detected. Running in stand-alone mode" -f $prefix)
          
          #set variable to null
          $Script:tsenv = $null
      }
      Finally{
          #set global Logpath
          if ($Script:tsenv){
              #grab the progress UI
              $Script:TSProgressUi = New-Object -ComObject Microsoft.SMS.TSProgressUI

              # Convert all of the variables currently in the environment to PowerShell variables
              $tsenv.GetVariables() | ForEach-Object { Set-Variable -Name "$_" -Value "$($tsenv.Value($_))" }
              
              # Query the environment to get an existing variable
              # Set a variable for the task sequence log path
              
              #Something like: C:\MININT\SMSOSD\OSDLOGS
              #[string]$LogPath = $tsenv.Value("LogPath")
              #Somthing like C:\WINDOWS\CCM\Logs\SMSTSLog
              [string]$LogPath = $tsenv.Value("_SMSTSLogPath")
              
          }
          Else{
              [string]$LogPath = $env:Temp
          }
      }
  }
  End{
      #If output log path if specified , otherwise output ts environment
      If($ReturnLogPath){
          return $LogPath
      }
      Else{
          return $Script:tsenv
      }
  }
}


Function Format-ElapsedTime($ts) {
  $elapsedTime = ""
  if ( $ts.Minutes -gt 0 ){$elapsedTime = [string]::Format( "{0:00} min. {1:00}.{2:00} sec", $ts.Minutes, $ts.Seconds, $ts.Milliseconds / 10 );}
  else{$elapsedTime = [string]::Format( "{0:00}.{1:00} sec", $ts.Seconds, $ts.Milliseconds / 10 );}
  if ($ts.Hours -eq 0 -and $ts.Minutes -eq 0 -and $ts.Seconds -eq 0){$elapsedTime = [string]::Format("{0:00} ms", $ts.Milliseconds);}
  if ($ts.Milliseconds -eq 0){$elapsedTime = [string]::Format("{0} ms", $ts.TotalMilliseconds);}
  return $elapsedTime
}

Function Format-DatePrefix{
  [string]$LogTime = (Get-Date -Format 'HH:mm:ss.fff').ToString()
[string]$LogDate = (Get-Date -Format 'MM-dd-yyyy').ToString()
  return ($LogDate + " " + $LogTime)
}

Function Write-LogEntry{
  param(
      [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
      [ValidateNotNullOrEmpty()]
      [string]$Message,
      [Parameter(Mandatory=$false,Position=2)]
  [string]$Source = '',
      [parameter(Mandatory=$false)]
      [ValidateSet(0,1,2,3,4)]
      [int16]$Severity,

      [parameter(Mandatory=$false, HelpMessage="Name of the log file that the entry will written to")]
      [ValidateNotNullOrEmpty()]
      [string]$OutputLogFile = $Global:LogFilePath,

      [parameter(Mandatory=$false)]
      [switch]$Outhost
  )
  Begin{
      [string]$LogTime = (Get-Date -Format 'HH:mm:ss.fff').ToString()
      [string]$LogDate = (Get-Date -Format 'MM-dd-yyyy').ToString()
      [int32]$script:LogTimeZoneBias = [timezone]::CurrentTimeZone.GetUtcOffset([datetime]::Now).TotalMinutes
      [string]$LogTimePlusBias = $LogTime + $script:LogTimeZoneBias
      
  }
  Process{
      # Get the file name of the source script
      Try {
          If ($script:MyInvocation.Value.ScriptName) {
              [string]$ScriptSource = Split-Path -Path $script:MyInvocation.Value.ScriptName -Leaf -ErrorAction 'Stop'
          }
          Else {
              [string]$ScriptSource = Split-Path -Path $script:MyInvocation.MyCommand.Definition -Leaf -ErrorAction 'Stop'
          }
      }
      Catch {
          $ScriptSource = ''
      }
      
      
      If(!$Severity){$Severity = 1}
      $LogFormat = "<![LOG[$Message]LOG]!>" + "<time=`"$LogTimePlusBias`" " + "date=`"$LogDate`" " + "component=`"$ScriptSource`" " + "context=`"$([Security.Principal.WindowsIdentity]::GetCurrent().Name)`" " + "type=`"$Severity`" " + "thread=`"$PID`" " + "file=`"$ScriptSource`">"
      
      # Add value to log file
      try {
          Out-File -InputObject $LogFormat -Append -NoClobber -Encoding Default -FilePath $OutputLogFile -ErrorAction Stop
      }
      catch {
          Write-Host ("[{0}] [{1}] :: Unable to append log entry to [{1}], error: {2}" -f $LogTimePlusBias,$ScriptSource,$OutputLogFile,$_.Exception.ErrorMessage) -ForegroundColor Red
      }
  }
  End{
      If($Outhost -or $Global:OutTohost){
          If($Source){
              $OutputMsg = ("[{0}] [{1}] :: {2}" -f $LogTimePlusBias,$Source,$Message)
          }
          Else{
              $OutputMsg = ("[{0}] [{1}] :: {2}" -f $LogTimePlusBias,$ScriptSource,$Message)
          }

          Switch($Severity){
              0       {Write-Host $OutputMsg -ForegroundColor Green}
              1       {Write-Host $OutputMsg -ForegroundColor Gray}
              2       {Write-Warning $OutputMsg}
              3       {Write-Host $OutputMsg -ForegroundColor Red}
              4       {If($Global:Verbose){Write-Verbose $OutputMsg}}
              default {Write-Host $OutputMsg}
          }
      }
  }
}

function Show-ProgressStatus
{
  <#
  .SYNOPSIS
      Shows task sequence secondary progress of a specific step
  
  .DESCRIPTION
      Adds a second progress bar to the existing Task Sequence Progress UI.
      This progress bar can be updated to allow for a real-time progress of
      a specific task sequence sub-step.
      The Step and Max Step parameters are calculated when passed. This allows
      you to have a "max steps" of 400, and update the step parameter. 100%
      would be achieved when step is 400 and max step is 400. The percentages
      are calculated behind the scenes by the Com Object.
  
  .PARAMETER Message
      The message to display the progress
  .PARAMETER Step
      Integer indicating current step
  .PARAMETER MaxStep
      Integer indicating 100%. A number other than 100 can be used.
  .INPUTS
       - Message: String
       - Step: Long
       - MaxStep: Long
  .OUTPUTS
      None
  .EXAMPLE
      Set's "Custom Step 1" at 30 percent complete
      Show-ProgressStatus -Message "Running Custom Step 1" -Step 100 -MaxStep 300
  
  .EXAMPLE
      Set's "Custom Step 1" at 50 percent complete
      Show-ProgressStatus -Message "Running Custom Step 1" -Step 150 -MaxStep 300
  .EXAMPLE
      Set's "Custom Step 1" at 100 percent complete
      Show-ProgressStatus -Message "Running Custom Step 1" -Step 300 -MaxStep 300
  #>
  param(
      [Parameter(Mandatory=$true)]
      [string] $Message,
      [Parameter(Mandatory=$true)]
      [int]$Step,
      [Parameter(Mandatory=$true)]
      [int]$MaxStep,
      [string]$SubMessage,
      [int]$IncrementSteps,
      [switch]$Outhost
  )

  Begin{

      If($SubMessage){
          $StatusMessage = ("{0} [{1}]" -f $Message,$SubMessage)
      }
      Else{
          $StatusMessage = $Message

      }
  }
  Process
  {
      If($Script:tsenv){
          $Script:TSProgressUi.ShowActionProgress(`
              $Script:tsenv.Value("_SMSTSOrgName"),`
              $Script:tsenv.Value("_SMSTSPackageName"),`
              $Script:tsenv.Value("_SMSTSCustomProgressDialogMessage"),`
              $Script:tsenv.Value("_SMSTSCurrentActionName"),`
              [Convert]::ToUInt32($Script:tsenv.Value("_SMSTSNextInstructionPointer")),`
              [Convert]::ToUInt32($Script:tsenv.Value("_SMSTSInstructionTableSize")),`
              $StatusMessage,`
              $Step,`
              $Maxstep)
      }
      Else{
          Write-Progress -Activity "$Message ($Step of $Maxstep)" -Status $StatusMessage -PercentComplete (($Step / $Maxstep) * 100) -id 1
      }
  }
  End{
      Write-LogEntry $Message -Severity 1 -Outhost:$Outhost
  }
}

Function Set-Bluetooth{
  [CmdletBinding()] 
  Param (
  [Parameter(Mandatory=$true)][ValidateSet('Off', 'On')]
  [string]$DeviceStatus
  )
  Begin{
      ## Get the name of this function
      [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
  }
  Process{
      Add-Type -AssemblyName System.Runtime.WindowsRuntime
      $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
      Function Await($WinRtTask, $ResultType) {
          $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
          $netTask = $asTask.Invoke($null, @($WinRtTask))
          $netTask.Wait(-1) | Out-Null
          $netTask.Result
      }
      [Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null
      [Windows.Devices.Radios.RadioAccessStatus,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null
      Await ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null
      $radios = Await ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
      $bluetooth = $radios | Where-Object { $_.Kind -eq 'Bluetooth' }
      [Windows.Devices.Radios.RadioState,Windows.System.Devices,ContentType=WindowsRuntime] | Out-Null
      If($bluetooth){
          Try{
              Await ($bluetooth.SetStateAsync($DeviceStatus)) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null
          }
          Catch{
              Write-LogEntry ("Unable to configure Bluetooth Settings: {0}" -f $_.Exception.ErrorMessage) -Severity 3 -Source ${CmdletName}
          }
          Finally{
              #If ((Get-Service bthserv).Status -eq 'Stopped') { Start-Service bthserv }
          }
      }
      Else{
          Write-LogEntry ("No Bluetooth found") -Severity 0 -Source ${CmdletName}
      }
  }
  End{}
}


function Disable-Indexing {
  Param($Drive)
  $obj = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter='$Drive'"
  $indexing = $obj.IndexingEnabled
  if("$indexing" -eq $True){
      Write-Host "Disabling indexing of drive $Drive"
      $obj | Set-WmiInstance -Arguments @{IndexingEnabled=$False} | Out-Null
  }
}

Function Convert-ToHexString{
  [Parameter(Mandatory=$true,Position=0)]
  Param ([string]$str)

  $bytes=[System.Text.Encoding]::UniCode.GetBytes($str)
  return ([byte[]]$bytes)
}

Function Convert-FromHexString{
  [Parameter(Mandatory=$true,Position=0)]
  Param ($hex)
  [System.Text.Encoding]::UniCode.GetString($hex)
}

Function Set-SystemSetting {
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
  Param (

  [Parameter(Mandatory=$true,Position=0)]
  [Alias("Path")]
  [string]$RegPath,

  [Parameter(Mandatory=$false,Position=1)]
  [Alias("v")]
  [string]$Name,

  [Parameter(Mandatory=$false,Position=2)]
  [Alias("d")]
  $Value,

  [Parameter(Mandatory=$false,Position=3)]
  [ValidateSet('None','String','Binary','DWord','ExpandString','MultiString','QWord')]
  [Alias("PropertyType","t")]
  $Type,

  [Parameter(Mandatory=$false,Position=4)]
  [Alias("f")]
  [switch]$Force,

  [Parameter(Mandatory=$false)]
  [boolean]$TryLGPO,

  [Parameter(Mandatory=$false)]
  $LGPOExe = $Global:LGPOPath,

  [Parameter(Mandatory=$false)]
  [string]$LogPath,

  [Parameter(Mandatory=$false)]
  [switch]$RemoveFile

  )
  Begin
  {
      ## Get the name of this function
      [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

      if (-not $PSBoundParameters.ContainsKey('Verbose')) {
          $VerbosePreference = $PSCmdlet.SessionState.PSVariable.GetValue('VerbosePreference')
      }

      if (-not $PSBoundParameters.ContainsKey('Confirm')) {
          $ConfirmPreference = $PSCmdlet.SessionState.PSVariable.GetValue('ConfirmPreference')
      }
      if (-not $PSBoundParameters.ContainsKey('WhatIf')) {
          $WhatIfPreference = $PSCmdlet.SessionState.PSVariable.GetValue('WhatIfPreference')
      }

  }
  Process
  {
      $RegKeyHive = ($RegPath).Split('\')[0].Replace('Registry::','').Replace(':','')

      #if Name not specified, grab last value from full path
      If(!$Name){
          $RegKeyPath = Split-Path ($RegPath).Split('\',2)[1] -Parent
          $RegKeyName = Split-Path ($RegPath).Split('\',2)[1] -Leaf
      }
      Else{
          $RegKeyPath = ($RegPath).Split('\',2)[1]
          $RegKeyName = $Name
      }

      #The -split operator supports specifying the maximum number of sub-strings to return.
      #Some values may have additional commas in them that we don't want to split (eg. LegalNoticeText)
      [String]$Value = $Value -split ',',2

      Switch($RegKeyHive){
          HKEY_LOCAL_MACHINE {$LGPOHive = 'Computer';$RegHive = 'HKLM:'}
          MACHINE {$LGPOHive = 'Computer';$RegHive = 'HKLM:'}
          HKLM {$LGPOHive = 'Computer';$RegHive = 'HKLM:'}
          HKEY_CURRENT_USER {$LGPOHive = 'User';$RegHive = 'HKCU:'}
          HKEY_USERS {$LGPOHive = 'User';$RegHive = 'Registry::HKEY_USERS'}
          HKCU {$LGPOHive = 'User';$RegHive = 'HKCU:'}
          HKU {$LGPOHive = 'User';$RegHive = 'Registry::HKEY_USERS'}
          USER {$LGPOHive = 'User';$RegHive = 'HKCU:'}
          default {$LGPOHive = 'Computer';$RegHive = 'HKLM:'}
      }

      #convert registry type to LGPO type
      Switch($Type){
          'None' {$LGPORegType = 'NONE'}
          'String' {$LGPORegType = 'SZ'}
          'ExpandString' {$LGPORegType = 'EXPAND_SZ'}
          'Binary' {$LGPORegType = 'BINARY'; $value = Convert-ToHexString $value}
          'DWord' {$LGPORegType = 'DWORD'}
          'QWord' {$LGPORegType = 'DWORD_BIG_ENDIAN'}
          'MultiString' {$LGPORegType = 'LINK'}
          default {$LGPORegType = 'DWORD';$Type = 'DWord'}
      }

      Try{
          #check if tryLGPO is set and path is set
          If($TryLGPO -and $LGPOExe)
          {
              #does LGPO path exist?
              If(Test-Path $LGPOExe)
              {
                  #$lgpoout = $null
                  $lgpoout = "; ----------------------------------------------------------------------`r`n"
                  $lgpoout += "; PROCESSING POLICY`r`n"
                  $lgpoout += "; Source file:`r`n"
                  $lgpoout += "`r`n"
                  
                  # build a unique output file
                  $LGPOfile = ($RegKeyHive + '-' + $RegKeyPath.replace('\','-').replace(' ','') + '-' + $RegKeyName.replace(' ','') + '.lgpo')
                  
                  #Remove the Username or SID from Registry key path
                  If($LGPOHive -eq 'User'){
                      $UserID = $RegKeyPath.Split('\')[0]
                      If($UserID -match "DEFAULT|S-1-5-21-(\d+-?){4}$"){
                          $RegKeyPath = $RegKeyPath.Replace($UserID+"\","")
                      }
                  }
                  #complete LGPO file
                  Write-LogEntry ("LGPO applying [{3}] to registry: [{0}\{1}\{2}] as a Group Policy item" -f $RegHive,$RegKeyPath,$RegKeyName,$RegKeyName) -Severity 4 -Source ${CmdletName}
                  $lgpoout += "$LGPOHive`r`n"
                  $lgpoout += "$RegKeyPath`r`n"
                  $lgpoout += "$RegKeyName`r`n"
                  $lgpoout += "$($LGPORegType):$Value`r`n"
                  $lgpoout += "`r`n"
                  $lgpoout | Out-File "$env:Temp\$LGPOfile"

                  If($VerbosePreference){$args = "/v /q /t"}Else{$args="/q /t"}
                  Write-LogEntry "Start-Process $LGPOExe -ArgumentList '/t $env:Temp\$LGPOfile' -RedirectStandardError '$env:Temp\$LGPOfile.stderr.log'" -Severity 4 -Source ${CmdletName}
                  
                  If(!$WhatIfPreference){$result = Start-Process $LGPOExe -ArgumentList "$args $env:Temp\$LGPOfile /v" -RedirectStandardError "$env:Temp\$LGPOfile.stderr.log" -Wait -NoNewWindow -PassThru | Out-Null}
                  Write-LogEntry ("LGPO ran successfully. Exit code: {0}" -f $result.ExitCode) -Severity 4
              }
              Else{
                  Write-LogEntry ("LGPO will not be used. Path not found: {0}" -f $LGPOExe) -Severity 3

              }
          }
          Else{
              Write-LogEntry ("LGPO not enabled. Hardcoding registry keys [{0}\{1}\{2}]" -f $RegHive,$RegKeyPath,$RegKeyName) -Severity 0 -Source ${CmdletName}
          }
      }
      Catch{
          If($TryLGPO -and $LGPOExe){
              Write-LogEntry ("LGPO failed to run. exit code: {0}. Hardcoding registry keys [{1}\{2}\{3}]" -f $result.ExitCode,$RegHive,$RegKeyPath,$RegKeyName) -Severity 3 -Source ${CmdletName}
          }
      }
      Finally
      {
          #wait for LGPO file to finish generating
          start-sleep 1
          
          #verify the registry value has been set
          Try{
              If( -not(Test-Path ($RegHive +'\'+ $RegKeyPath)) ){
                  Write-LogEntry ("Key was not set; Hardcoding registry keys [{0}\{1}] with value [{2}]" -f ($RegHive +'\'+ $RegKeyPath),$RegKeyName,$Value) -Severity 0 -Source ${CmdletName}
                  New-Item -Path ($RegHive +'\'+ $RegKeyPath) -Force -WhatIf:$WhatIfPreference -ErrorAction SilentlyContinue | Out-Null
                  New-ItemProperty -Path ($RegHive +'\'+ $RegKeyPath) -Name $RegKeyName -PropertyType $Type -Value $Value -Force:$Force -WhatIf:$WhatIfPreference -ErrorAction SilentlyContinue -PassThru
              } 
              Else{
                  Write-LogEntry ("Key name not found. Creating key name [{1}] at path [{0}] with value [{2}]" -f ($RegHive +'\'+ $RegKeyPath),$RegKeyName,$Value) -Source ${CmdletName}
                  Set-ItemProperty -Path ($RegHive +'\'+ $RegKeyPath) -Name $RegKeyName -Value $Value -Force:$Force -WhatIf:$WhatIfPreference -ErrorAction SilentlyContinue -PassThru
              }
          }
          Catch{
              Write-LogEntry ("Unable to set registry key [{0}\{1}\{2}] with value [{3}]" -f $RegHive,$RegKeyPath,$RegKeyName,$Value) -Severity 2 -Source ${CmdletName}
          }

      }
  }
  End {
      #cleanup LGPO logs
      If(!$WhatIfPreference){$RemoveFile =  $false}

      If($LGPOfile -and (Test-Path "$env:Temp\$LGPOfile") -and $RemoveFile){
             Remove-Item "$env:Temp\$LGPOfile" -ErrorAction SilentlyContinue | Out-Null
             #Remove-Item "$env:Temp" -Include "$LGPOfile*" -Recurse -Force
      }
  }

}


Function Set-UserSetting {
  [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
  Param (
      [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
      [Alias("Path")]
      [string]$RegPath,

      [Parameter(Mandatory=$false,Position=1)]
      [Alias("v")]
      [string]$Name,

      [Parameter(Mandatory=$false,Position=2)]
      [Alias("d")]
      $Value,

      [Parameter(Mandatory=$false,Position=3)]
      [ValidateSet('None','String','Binary','DWord','ExpandString','MultiString','QWord')]
      [Alias("PropertyType","t")]
      [string]$Type,

      [Parameter(Mandatory=$false,Position=4)]
      [ValidateSet('CurrentUser','AllUsers','DefaultUser')]
      [Alias("Users")]
      [string]$ApplyTo = $Global:ApplyToProfiles,


      [Parameter(Mandatory=$false,Position=5)]
      [Alias("r")]
      [switch]$Remove,

      [Parameter(Mandatory=$false,Position=6)]
      [Alias("f")]
      [switch]$Force,

      [Parameter(Mandatory=$false)]
      [ValidateNotNullOrEmpty()]
      [string]$Message,

      [Parameter(Mandatory=$false)]
      [boolean]$TryLGPO,

      [Parameter(Mandatory=$false)]
      $LGPOExe = $Global:LGPOPath,

      [Parameter(Mandatory=$false)]
      [string]$LogPath

  )
  Begin
  {
      ## Get the name of this function
      [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

      if (-not $PSBoundParameters.ContainsKey('Verbose')) {
          $VerbosePreference = $PSCmdlet.SessionState.PSVariable.GetValue('VerbosePreference')
      }

      if (-not $PSBoundParameters.ContainsKey('Confirm')) {
          $ConfirmPreference = $PSCmdlet.SessionState.PSVariable.GetValue('ConfirmPreference')
      }
      if (-not $PSBoundParameters.ContainsKey('WhatIf')) {
          $WhatIfPreference = $PSCmdlet.SessionState.PSVariable.GetValue('WhatIfPreference')
      }

      #If user profile variable doesn't exist, build one
      If(!$Global:UserProfiles){
          # Get each user profile SID and Path to the profile
          $AllProfiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" | Where-Object {$_.PSChildName -match "S-1-5-21-(\d+-?){4}$" } | 
                  Select-Object @{Name="SID"; Expression={$_.PSChildName}}, @{Name="UserHive";Expression={"$($_.ProfileImagePath)\NTuser.dat"}}, @{Name="UserName";Expression={Split-Path $_.ProfileImagePath -Leaf}}

          # Add in the DEFAULT User Profile (Not be confused with .DEFAULT)
          $DefaultProfile = "" | Select-Object SID, UserHive,UserName
          $DefaultProfile.SID = "DEFAULT"
          $DefaultProfile.Userhive = "$env:systemdrive\Users\Default\NTuser.dat"
          $DefaultProfile.UserName = "Default"

          #Add it to the UserProfile list
          $Global:UserProfiles = @()
          $Global:UserProfiles += $AllProfiles
          $Global:UserProfiles += $DefaultProfile

          #get current users sid
          [string]$CurrentSID = (Get-WmiObject win32_useraccount | Where-Object {$_.name -eq $env:username}).SID
      }
  }
  Process
  { 
      #grab the hive from the regpath
      $RegKeyHive = ($RegPath).Split('\')[0].Replace('Registry::','').Replace(':','')
      
      #Grab user keys and profiles based on whom it will be applied to
      Switch($ApplyTo){
          'AllUsers'      {$RegHive = 'HKEY_USERS'; $ProfileList = $Global:UserProfiles}
          'CurrentUser'   {$RegHive = 'HKCU'      ; $ProfileList = ($Global:UserProfiles | Where-Object{$_.SID -eq $CurrentSID})}
          'DefaultUser'   {$RegHive = 'HKU'       ; $ProfileList = $DefaultProfile}
          default         {$RegHive = $RegKeyHive ; $ProfileList = ($Global:UserProfiles | Where-Object{$_.SID -eq $CurrentSID})}
      }
      
      #check if hive is local machine.
      If($RegKeyHive -match "HKEY_LOCAL_MACHINE|HKLM|HKCR"){
          Write-LogEntry ("Registry path [{0}] is not a user path. Use Set-SystemSetting cmdlet instead" -f $RegKeyHive) -Severity 2 -Source ${CmdletName}
          return
      }
      #check if hive was found and is a user hive
      ElseIf($RegKeyHive -match "HKEY_USERS|HKEY_CURRENT_USER|HKCU|HKU"){
          #if Name not specified, grab last value from full path
           If(!$Name){
               $RegKeyPath = Split-Path ($RegPath).Split('\',2)[1] -Parent
               $RegKeyName = Split-Path ($RegPath).Split('\',2)[1] -Leaf
           }
           Else{
               $RegKeyPath = ($RegPath).Split('\',2)[1]
               $RegKeyName = $Name
           } 
      }
      ElseIf($ApplyTo){
          #if Name not specified, grab last value from full path
          If(!$Name){
              $RegKeyPath = Split-Path ($RegPath) -Parent
              $RegKeyName = Split-Path ($RegPath) -Leaf
          }
          Else{
              $RegKeyPath = $RegPath
              $RegKeyName = $Name
          } 
      }
      Else{
          Write-LogEntry ("User registry hive was not found or specified in Keypath [{0}]. Either use the -ApplyTo Switch or specify user hive [eg. HKCU\]" -f $RegPath) -Severity 3 -Source ${CmdletName}
          return
      }

      #loope through profiles as long as the hive is not the current user hive
      If($RegHive -notmatch 'HKCU|HKEY_CURRENT_USER'){

          $p = 1
          # Loop through each profile on the machine
          Foreach ($UserProfile in $ProfileList) {
              
              Try{
                  $objSID = New-Object System.Security.Principal.SecurityIdentifier($UserProfile.SID)
                  $UserName = $objSID.Translate([System.Security.Principal.NTAccount]) 
              }
              Catch{
                  $UserName = $UserProfile.UserName
              }

              If($Message){Show-ProgressStatus -Message $Message -SubMessage ("(Users: {0} of {1})" -f $p,$ProfileList.count) -Step $p -MaxStep $ProfileList.count}

              #loadhive if not mounted
              If (($HiveLoaded = Test-Path Registry::HKEY_USERS\$($UserProfile.SID)) -eq $false) {
                  Start-Process -FilePath "CMD.EXE" -ArgumentList "/C REG.EXE LOAD HKU\$($UserProfile.SID) $($UserProfile.UserHive)" -Wait -WindowStyle Hidden
                  $HiveLoaded = $true
              }

              If ($HiveLoaded -eq $true) {   
                  If($Message){Write-LogEntry ("{0} for User [{1}]" -f $Message,$UserName)}
                  If($Remove){
                      Remove-ItemProperty "$RegHive\$($UserProfile.SID)\$RegKeyPath" -Name $RegKeyName -Force:$Force -WhatIf:$WhatIfPreference -ErrorAction SilentlyContinue | Out-Null  
                  }
                  Else{
                      Set-SystemSetting -Path "$RegHive\$($UserProfile.SID)\$RegKeyPath" -Name $RegKeyName -Type $Type -Value $Value -Force:$Force -WhatIf:$WhatIfPreference -TryLGPO:$TryLGPO
                  }
              }

              #remove any leftover reg process and then remove hive
              If ($HiveLoaded -eq $true) {
                  [gc]::Collect()
                  Start-Sleep -Seconds 3
                  Start-Process -FilePath "CMD.EXE" -ArgumentList "/C REG.EXE UNLOAD HKU\$($UserProfile.SID)" -Wait -PassThru -WindowStyle Hidden | Out-Null
              }
              $p++
          }
      }
      Else{
          If($Message){Write-LogEntry ("{0} for [{1}]" -f $Message,$ProfileList.UserName)}
          If($Remove){
              Remove-ItemProperty "$RegHive\$RegKeyPath\$RegKeyPath" -Name $RegKeyName -Force:$Force -WhatIf:$WhatIfPreference -ErrorAction SilentlyContinue | Out-Null  
          }
          Else{
              Set-SystemSetting -Path "$RegHive\$RegKeyPath" -Name $RegKeyName -Type $Type -Value $Value -Force:$Force -WhatIf:$WhatIfPreference -TryLGPO:$TryLGPO
          }
      }

  }
  End {
     If($Message){Show-ProgressStatus -Message "Completed $Message"  -Step 1 -MaxStep 1}
  }
}

function Set-PowerPlan {
  <#
   Get-WmiObject -Class Win32_PowerPlan -Namespace root\cimv2\power -Filter "ElementName= 'Balanced'" | Invoke-WmiMethod -Name Activate | Out-Null
  Start-Process "C:\Windows\system32\powercfg.exe" -ArgumentList "-SETACTIVE 381b4222-f694-41f0-9685-ff5bb260df2e" -Wait -NoNewWindow
  Start-Process "C:\Windows\system32\powercfg.exe" -ArgumentList "-x -standby-timeout-ac 0" -Wait -NoNewWindow
  #>
  [CmdletBinding(SupportsShouldProcess = $True)]
  param (

      [ValidateSet("High performance", "Balanced", "Power saver")]
      [ValidateNotNullOrEmpty()]
      [string]$PreferredPlan = "High Performance",
      
      [ValidateSet("On", "Off")]
      [string]$Hibernate,

      [ValidateRange(0,120)]
      [int32]$ACTimeout,

      [ValidateRange(0,120)]
      [int32]$DCTimeout,

      [ValidateRange(0,120)]
      [int32]$ACMonitorTimeout,

      [ValidateRange(0,120)]
      [int32]$DCMonitorTimeout,

      [string]$ComputerName = $env:COMPUTERNAME
  )
  Begin
  {
      ## Get the name of this function
      [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

      if (-not $PSBoundParameters.ContainsKey('Verbose')) {
          $VerbosePreference = $PSCmdlet.SessionState.PSVariable.GetValue('VerbosePreference')
      }

      if (-not $PSBoundParameters.ContainsKey('Confirm')) {
          $ConfirmPreference = $PSCmdlet.SessionState.PSVariable.GetValue('ConfirmPreference')
      }
      if (-not $PSBoundParameters.ContainsKey('WhatIf')) {
          $WhatIfPreference = $PSCmdlet.SessionState.PSVariable.GetValue('WhatIfPreference')
      }

  }
  Process
  {
      Write-LogEntry ("Setting power plan to `"{0}`"" -f $PreferredPlan) -Source ${CmdletName}

      $guid = (Get-WmiObject -Class Win32_PowerPlan -Namespace root\cimv2\power -Filter "ElementName='$PreferredPlan'" -ComputerName $ComputerName).InstanceID.ToString()
      $regex = [regex]"{(.*?)}$"
      $plan = $regex.Match($guid).groups[1].value

      $process = Get-WmiObject -Query "SELECT * FROM Meta_Class WHERE __Class = 'Win32_Process'" -Namespace "root\cimv2" -ComputerName $ComputerName
      Try{
          If($VerbosePreference){Write-LogEntry ("COMMAND: powercfg -S $plan") -Severity 4 -Source ${CmdletName} -Outhost}
          $process.Create("powercfg -S $plan") | Out-Null
      }
      Catch{
          Write-LogEntry ("Failed to create power confugration:" -f $_.Exception.Message) -Severity 3 -Source ${CmdletName} -Outhost
      }

      $Output = "Power plan set to "
      $Output += "`"" + ((Get-WmiObject -Class Win32_PowerPlan -Namespace root\cimv2\power -Filter "IsActive='$True'" -ComputerName $ComputerName).ElementName) + "`""

      $params = ""

      If($Hibernate){
              $params += "-H $Hibernate"
              $Output += " with hibernate set to [$Hibernate]" 
      }

      If(($ACTimeout -ge 0) -or ($DCTimeout -ge 0) -or ($ACMonitorTimeout -ge 0) -or ($DCMonitorTimeout -ge 0)){$params += " -x "}
      
      If($ACTimeout -ge 0){
              $params += "-standby-timeout-ac $ACTimeout "
              $Output += " . The AC System timeout was set to [$($ACTimeout.ToString())]" 
      }

      If($DCTimeout -ge 0){
              $params += "-standby-timeout-dc $DCTimeout "
              $Output += " . The DC System timeout was set to [$($DCTimeout.ToString())]" 
      }

      If($ACMonitorTimeout -ge 0){
              $params += "-standby-timeout-ac $ACMonitorTimeout "
              $Output += " . The AC Monitor timeout was set to [$($ACMonitorTimeout.ToString())]" 
      }

      If($DCMonitorTimeout -ge 0){
              $params += "-standby-timeout-dc $DCMonitorTimeout "
              $Output += " . The DC Monitor timeout was set to [$($DCMonitorTimeout.ToString())]" 
      }

      Try{
          If($VerbosePreference){Write-LogEntry ("COMMAND: powercfg $params") -Severity 4 -Source ${CmdletName} -Outhost}
          $process.Create("powercfg $params") | Out-Null
      }
      Catch{
          Write-LogEntry ("Failed to set power confugration:" -f $_.Exception.Message) -Severity 3 -Source ${CmdletName} -Outhost
      }
  }
  End {
      #Write-Host $Output
      Write-LogEntry ("{0}" -f $Output) -Source ${CmdletName}
  }
}


Function Copy-ItemWithProgress
{
  [CmdletBinding()]
  Param
  (
  [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true,Position=0)]
  [string]$Source,
  [Parameter(Mandatory=$true,Position=1)]
  [string]$Destination,
  [Parameter(Mandatory=$false,Position=3)]
  [switch]$Force
  )

  Begin{
      $Source = $Source
  
      #get the entire folder structure
      $Filelist = Get-Childitem $Source -Recurse

      #get the count of all the objects
      $Total = $Filelist.count

      #establish a counter
      $Position = 0
  }
  Process{
      #Stepping through the list of files is quite simple in PowerShell by using a For loop
      foreach ($File in $Filelist)

      {
          #On each file, grab only the part that does not include the original source folder using replace
          $Filename = ($File.Fullname).replace($Source,'')
      
          #rebuild the path for the destination:
          $DestinationFile = ($Destination+$Filename)
      
          #get just the folder path
          $DestinationPath = Split-Path $DestinationFile -Parent

          #show progress
          Show-ProgressStatus -Message "Copying data from $source to $Destination" -Step (($Position/$total)*100) -MaxStep $total

          #create destination directories
          If (-not (Test-Path $DestinationPath) ) {
              New-Item $DestinationPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
          }

          #do copy (enforce)
          Try{
              Copy-Item $File.FullName -Destination $DestinationFile -Force:$Force -ErrorAction:$VerbosePreference -Verbose:($PSBoundParameters['Verbose'] -eq $true) | Out-Null
              Write-Verbose ("Copied file [{0}] to [{1}]" -f $File.FullName,$DestinationFile)
          }
          Catch{
              Write-Host ("Unable to copy file in {0} to {1}; Error: {2}" -f $File.FullName,$DestinationFile ,$_.Exception.Message) -ForegroundColor Red
              break
          }
          #bump up the counter
          $Position++
      }
  }
  End{
      Show-ProgressStatus -Message "Copy completed" -Step $total -MaxStep $total
  }
}

##*===========================================================================
##* VARIABLES
##*===========================================================================
# Use function to get paths because Powershell ISE and other editors have differnt results
$scriptPath = Get-ScriptPath
[string]$scriptDirectory = Split-Path $scriptPath -Parent
[string]$scriptName = Split-Path $scriptPath -Leaf
[string]$scriptBaseName = [System.IO.Path]::GetFileNameWithoutExtension($scriptName)

[int]$OSBuildNumber = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
[string]$OsCaption = (Get-WmiObject -class Win32_OperatingSystem).Caption

#Create Paths
$ToolsPath = Join-Path $scriptDirectory -ChildPath 'Tools'
$AdditionalScriptsPath = Join-Path $scriptDirectory -ChildPath 'Scripts'
$ModulesPath = Join-Path -Path $scriptDirectory -ChildPath 'PSModules'
$BinPath = Join-Path -Path $scriptDirectory -ChildPath 'Bin'
$FilesPath = Join-Path -Path $scriptDirectory -ChildPath 'Files'


#check if running in verbose mode
$Global:Verbose = $false
If($PSBoundParameters.ContainsKey('Debug') -or $PSBoundParameters.ContainsKey('Verbose')){
    $Global:Verbose = $PsBoundParameters.Get_Item('Verbose')
    $VerbosePreference = 'Continue'
    Write-Verbose ("[{0}] [{1}] :: VERBOSE IS ENABLED" -f (Format-DatePrefix),$scriptName)
}
Else{
    $VerbosePreference = 'SilentlyContinue'
}

#build log name
[string]$FileName = $scriptBaseName +'.log'
#build global log fullpath
$Global:LogFilePath = Join-Path (Get-SMSTSENV -ReturnLogPath) -ChildPath $FileName
Write-Host "logging to file: $LogFilePath" -ForegroundColor Cyan

##*===========================================================================
##* DEFAULTS: Configurations are here (change values if needed)
##*===========================================================================
# Global Settings
[boolean]$DisableScript = $false
[boolean]$UseLGPO = $true
[string]$Global:LGPOPath = "$ToolsPath\LGPO\LGPO.exe"
[boolean]$DisabledUnusedServices = $false
[boolean]$DisableSchTasks = $false
[boolean]$DisabledHyperVServices = $false

# Configurations comes from Tasksequence
# When running in Tasksequence and configureation exists, use that instead
If(Get-SMSTSENV){
  If($tsenv:CFG_DisabledUnusedServices){[boolean]$DisabledUnusedServices = [boolean]::Parse($tsenv.Value("CFG_DisabledUnusedServices"))}
  If($tsenv:CFG_DisabledHyperVServices){[boolean]$DisabledHyperVServices = [boolean]::Parse($tsenv.Value("CFG_DisabledHyperVServices"))}
  If($tsenv:CFG_DisableSchTasks){[boolean]$DisableSchTasks = [boolean]::Parse($tsenv.Value("CFG_DisableSchTasks"))}
}


If ($DisabledUnusedServices)
{
    $services = [ordered]@{
            AJRouterA="llJoyn Router Service"
            ALG="Application Layer Gateway Service"               
            AppMgmt="Application Management"
            BITS="Background Intelligent Transfer Service"
            bthserv="Bluetooth Support Service"
            DcpSvc="DataCollectionPublishingService"
            DPS="Diagnostic Policy Service"
            WdiServiceHost="Diagnostic Service Host"
            WdiSystemHost="Diagnostic System Host"
            DiagTrack="Connected User Experiences and Telemetry [Diagnostics Tracking Service]"
            dmwappushservice="dmwappushsvc"
            MapsBroker="Downloaded Maps Manager"
            EFS="Encrypting File System [EFS]"
            Eaphost="Extensible Authentication Protocol"
            FDResPub="Function Discovery Resource Publication"
            lfsvc="Geolocation Service"
            UI0Detect="Interactive Services Detection"
            SharedAccess="Internet Connection Sharing [ICS]"
            iphlpsvc="IP Helper"
            lltdsvc="Link-Layer Topology Discovery Mapper"
            "diagnosticshub.standardcollector.service"="Microsoft [R] Diagnostics Hub Standard Collector Service"
            wlidsvc="Microsoft Account Sign-in Assistant"
            MSiSCSI="Microsoft iSCSI Initiator Service"
            smphost="Microsoft Storage Spaces SMP"
            NcbService="Network Connection Broker"
            NcaSvc="Network Connectivity Assistant"
            defragsvc="Optimize drives"
            wercplsupport="Problem Reports and Solutions Control Panel"
            PcaSvc="Program Compatibility Assistant Service"
            QWAVE="Quality Windows Audio Video Experience"
            RmSvc="Radio Management Service"
            RasMan="Remote Access Connection Manager"
            SstpSvc="Secure Socket Tunneling Protocol Service"
            SensorDataService="Sensor Data Service"
            SensrSvc="Sensor Monitoring Service"
            SensorService="Sensor Service"
            SNMPTRAP="SNMP Trap"
            sacsvr="Special Administration Console Helper"
            svsvc="Spot Verifier"
            SSDPSRV="SSDP Discovery"
            TieringEngineService="Storage Tiers Management"
            SysMain="Superfetch"
            TapiSrv="Telephony"
            UALSVC="User Access Logging Service"
            Wcmsvc="Windows Connection Manager"
            WerSvc="Windows Error Reporting Service"
            wisvc="Windows Insider Service"
            icssvc="Windows Mobile Hotspot Service"
            wuauserv="Windows Update"
            dot3svc="Wired AutoConfig"
            XblAuthManager="Xbox Live Auth Manager"
            XblGameSave="Xbox Live Game Save"
    }

    $i = 1
    Foreach ($key in $services.GetEnumerator()){
        #write-host ("`"{1}`"=`"{0}`"" -f $key.Key,$key.Value)
        $SvcName = $key.Value
        
        Write-LogEntry ("Disabling {0} Service [{1}]" -f $SvcName,$key.Key)

        Show-ProgressStatus -Message "Disabling Unused Service" -SubMessage ("Removing: {2} ({0} of {1})" -f $i,$services.count,$SvcName) -Step $i -MaxStep $services.count

        Try{
            Set-Service $key.Key -StartupType Disabled -ErrorAction Stop | Out-Null
        }
        Catch [System.Management.Automation.ActionPreferenceStopException]{
            Write-LogEntry ("Unable to Disable {0} Service: {1}" -f $SvcName,$_) -Severity 3
        }

        Start-Sleep -Seconds 10
        $i++
    }

    $SyncService = Get-Service -Name OneSync* | select -ExpandProperty Name
    Set-Service $SyncService -StartupType Disabled -ErrorAction Stop | Out-Null

}
Else{$stepCounter++}


# Disable Scheduled Tasks
If ($DisableSchTasks)
{
    Show-ProgressStatus -Message "Disabling Scheduled Tasks" -Step ($stepCounter++) -MaxStep $script:Maxsteps

    $ScheduledTasks = [ordered]@{
          "AD RMS Rights Policy Template Management (Manual)"="\Microsoft\Windows\Active Directory Rights Management Services Client"
          "EDP Policy Manager"="\Microsoft\Windows\AppID"
          "SmartScreenSpecific"="\Microsoft\Windows\AppID"
          "Microsoft Compatibility Appraiser"="\Microsoft\Windows\Application Experience"
          "ProgramDataUpdater"="\Microsoft\Windows\Application Experience"
          "StartupAppTask"="\Microsoft\Windows\Application Experience"
          "CleanupTemporaryState"="\Microsoft\Windows\ApplicationData"
          "DsSvcCleanup"="\Microsoft\Windows\ApplicationData"
          "Proxy"="\Microsoft\Windows\Autochk"
          "UninstallDeviceTask"="\Microsoft\Windows\Bluetooth"
          "AikCertEnrollTask"="\Microsoft\Windows\CertificateServicesClient"
          "CryptoPolicyTask"="\Microsoft\Windows\CertificateServicesClient"
          "KeyPreGenTask"="\Microsoft\Windows\CertificateServicesClient"
          "ProactiveScan"="\Microsoft\Windows\Chkdsk"
          "CreateObjectTask"="\Microsoft\Windows\CloudExperienceHost"
          "Consolidator"="\Microsoft\Windows\Customer Experience Improvement Program"
          "KernelCeipTask"="\Microsoft\Windows\Customer Experience Improvement Program"
          "UsbCeip"="\Microsoft\Windows\Customer Experience Improvement Program"
          "Data Integrity Scan"="\Microsoft\Windows\Data Integrity Scan"
          "Data Integrity Scan for Crash Recovery"="\Microsoft\Windows\Data Integrity Scan"
          "ScheduledDefrag"="\Microsoft\Windows\Defrag"
          "Device"="\Microsoft\Windows\Device Information"
          "Scheduled"="\Microsoft\Windows\Diagnosis"
          "SilentCleanup"="\Microsoft\Windows\DiskCleanup"
          "Microsoft-Windows-DiskDiagnosticDataCollector"="\Microsoft\Windows\DiskDiagnostic"
          "Notifications"="\Microsoft\Windows\Location"
          "WindowsActionDialog"="\Microsoft\Windows\Location"
          "WinSAT"="\Microsoft\Windows\Maintenance"
          "MapsToastTask"="\Microsoft\Windows\Maps"
          "MNO Metadata Parser"="\Microsoft\Windows\Mobile Broadband Accounts"
          "LPRemove"="\Microsoft\Windows\MUI"
          "GatherNetworkInfo"="\Microsoft\Windows\NetTrace"
          "Secure-Boot-Update"="\Microsoft\Windows\PI"
          "Sqm-Tasks"="\Microsoft\Windows\PI"
          "AnalyzeSystem"="\Microsoft\Windows\Power Efficiency Diagnostics"
          "MobilityManager"="\Microsoft\Windows\Ras"
          "VerifyWinRE"="\Microsoft\Windows\RecoveryEnvironment"
          "RegIdleBackup"="\Microsoft\Windows\Registry"
          "CleanupOldPerfLogs"="\Microsoft\Windows\Server Manager"
          "StartComponentCleanup"="\Microsoft\Windows\Servicing"
          "IndexerAutomaticMaintenance"="\Microsoft\Windows\Shell"
          "Configuration"="\Microsoft\Windows\Software Inventory Logging"
          "SpaceAgentTask"="\Microsoft\Windows\SpacePort"
          "SpaceManagerTask"="\Microsoft\Windows\SpacePort"
          "SpeechModelDownloadTask"="\Microsoft\Windows\Speech"
          "Storage Tiers Management Initialization"="\Microsoft\Windows\Storage Tiers Management"
          "Tpm-HASCertRetr"="\Microsoft\Windows\TPM"
          "Tpm-Maintenance"="\Microsoft\Windows\TPM"
          "Schedule Scan"="\Microsoft\Windows\UpdateOrchestrator"
          "ResolutionHost"="\Microsoft\Windows\WDI"
          "QueueReporting"="\Microsoft\Windows\Windows Error Reporting"
          "BfeOnServiceStartTypeChange"="\Microsoft\Windows\Windows Filtering Platform"
          "Automatic App Update"="\Microsoft\Windows\WindowsUpdate"
          "Scheduled Start"="\Microsoft\Windows\WindowsUpdate"
          "sih"="\Microsoft\Windows\WindowsUpdate"
          "sihboot"="\Microsoft\Windows\WindowsUpdate"
          "XblGameSaveTask"="\Microsoft\XblGameSave"
          "XblGameSaveTaskLogon"="\Microsoft\XblGameSave"
    }

    Foreach ($task in $ScheduledTasks.GetEnumerator()){
        Write-LogEntry ('Disabling [{0}]' -f $task.Key)
        Disable-ScheduledTask -TaskName $task.Value -ErrorAction SilentlyContinue | Out-Null
    }

}
Else{$stepCounter++}

If ($DisabledHyperVServices)
{
    $services = [ordered]@{
        HvHost="HV Host Service"
        vmickvpexchange="Hyper-V Data Exchange Service"
        vmicguestinterface="Hyper-V Guest Service Interface"
        vmicshutdown="Hyper-V Guest Shutdown Interface"
        vmicheartbeat="Hyper-V Heartbeat Service"
        vmicvmsession="Hyper-V PowerShell Direct Service"
        vmicrdv="Hyper-V Remote Desktop Virtualization Service"
        vmictimesync="Hyper-V Time Synchronization Service"
        vmicvss="Hyper-V Volume Shadow Copy Requestor"
    }

    $i = 1
    Foreach ($key in $services.GetEnumerator()){
        #write-host ("`"{1}`"=`"{0}`"" -f $key.Key,$key.Value)
        $SvcName = $key.Value
        
        Write-LogEntry ("Disabling {0} Service [{1}]" -f $SvcName,$key.Key)

        Show-ProgressStatus -Message "Disabling Hyper-V Service" -SubMessage ("Removing: {2} ({0} of {1})" -f $i,$services.count,$SvcName) -Step $i -MaxStep $services.count

        Try{
            Set-Service $key.Key -StartupType Disabled -ErrorAction Stop | Out-Null
        }
        Catch [System.Management.Automation.ActionPreferenceStopException]{
            Write-LogEntry ("Unable to Disable {0} Service: {1}" -f $SvcName,$_) -Severity 3
        }

        Start-Sleep -Seconds 10
        $i++
    }
}
Else{$stepCounter++}



 <#
  
 #Array of registry objects that will be created
 $CreateRegistry =
 @("HideSCAHealth DWORD - Hide Action Center Icon.","HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' /v HideSCAHealth /t REG_DWORD /d 0x1 /f"), #Confirmed that this does hide the Action Center in 2012 R2.
  ("NoRemoteRecursiveEvents DWORD - Turn off change notify events for file and folder changes.","'HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Policies\Explorer' /v NoRemoteRecursiveEvents /t REG_DWORD /d 0x1 /f"),
  ("SendAlert DWORD - Do not send Administrative alert during system crash.","'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' /v SendAlert /t REG_DWORD /d 0x0 /f"),
  ("ServicesPipeTimeout DWORD - Increase services startup timeout from 30 to 45 seconds.","'HKLM\SYSTEM\CurrentControlSet\Control' /v ServicesPipeTimeout /t REG_DWORD /d 0xafc8 /f"),
  ("DisableFirstRunCustomize DWORD - Disable Internet Explorer first-run customise wizard.","'HKLM\SOFTWARE\Policies\Microsoft\Internet Explorer\Main' /v DisableFirstRunCustomize /t REG_DWORD /d 0x1 /f"),
  ("AllowTelemetry DWORD - Disable telemetry.","'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' /v AllowTelemetry /t REG_DWORD /d 0x0 /f"),
  ("Enabled DWORD - Disable offline files.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\NetCache' /v Enabled /t REG_DWORD /d 0x0 /f"),
  ("Enable REG_SZ - Disable Defrag.","'HKLM\SOFTWARE\Microsoft\Dfrg\BootOptimizeFunction' /v Enable /t REG_SZ /d N /f"),
  ("NoAutoUpdate DWORD - Disable Windows Autoupdate.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' /v NoAutoUpdate /t REG_DWORD /d 0x1 /f"),
  ("AUOptions DWORD - Disable Windows Autoupdate.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' /v AUOptions /t REG_DWORD /d 0x1 /f"),
  ("ScheduleInstallDay DWORD - Disable Windows Autoupdate.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' /v ScheduleInstallDay /t REG_DWORD /d 0x0 /f"),
  ("ScheduleInstallTime DWORD - Disable Windows Autoupdate.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update' /v ScheduleInstallTime /t REG_DWORD /d 0x3 /f"),
  ("EnableAutoLayout DWORD - Disable Background Layout Service.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OptimalLayout' /v EnableAutoLayout /t REG_DWORD /d 0x0 /f"),
  ("DumpFileSize DWORD - Reduce DedicatedDumpFile DumpFileSize to 2 MB.","'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' /v DumpFileSize /t REG_DWORD /d 0x2 /f"),
  ("IgnorePagefileSize DWORD - Reduce DedicatedDumpFile DumpFileSize to 2 MB.","'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' /v IgnorePagefileSize /t REG_DWORD /d 0x1 /f"),
  ("DisableLogonBackgroundImage DWORD - Disable Logon Background Image.","'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' /v DisableLogonBackgroundImage /t REG_DWORD /d 0x1 /f")
 
 #Array of registry objects that will be deleted
 $DeleteRegistry =
 @("StubPath - Themes Setup.","'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{2C7339CF-2B09-4501-B3F3-F3508C9228ED}' /v StubPath /f"),
  ("StubPath - WinMail.","'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{44BBA840-CC51-11CF-AAFA-00AA00B6015C}' /v StubPath /f"),
  ("StubPath x64 - WinMail.","'HKLM\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\{44BBA840-CC51-11CF-AAFA-00AA00B6015C}' /v StubPath /f"),
  ("StubPath - Windows Media Player.","'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{6BF52A52-394A-11d3-B153-00C04F79FAA6}' /v StubPath /f"),
  ("StubPath x64 - Windows Media Player.","'HKLM\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\{6BF52A52-394A-11d3-B153-00C04F79FAA6}' /v StubPath /f"),
  ("StubPath - Windows Desktop Update.","'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11cf-8B85-00AA005B4340}' /v StubPath /f"),
  ("StubPath - Web Platform Customizations.","'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11cf-8B85-00AA005B4383}' /v StubPath /f"),
  ("StubPath - DotNetFrameworks.","'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{89B4C1CD-B018-4511-B0A1-5476DBF70820}' /v StubPath /f"),
  ("StubPath x64 - DotNetFrameworks.","'HKLM\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\{89B4C1CD-B018-4511-B0A1-5476DBF70820}' /v StubPath /f"),
  ("StubPath - Windows Media Player.", "'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\>{22d6f312-b0f6-11d0-94ab-0080c74c7e95}' /v StubPath /f"),
  ("StubPath x64 - Windows Media Player.", "'HKLM\SOFTWARE\WOW6432Node\Microsoft\Active Setup\Installed Components\>{22d6f312-b0f6-11d0-94ab-0080c74c7e95}' /v StubPath /f"),
  ("StubPath - IE ESC for Admins.", "'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}' /v StubPath /f"),
  ("StubPath - IE ESC for Users.", "'HKLM\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}' /v StubPath /f")

 #Array of registry objects that will be modified
 $ModifyRegistry =
 @("DisablePagingExecutive DWORD from 0x0 to 0x1 - Keep drivers and kernel on physical memory.","'HKLM\System\CurrentControlSet\Control\Session Manager\Memory Management' /v DisablePagingExecutive /t REG_DWORD /d 0x1 /f"),
  ("EventLog DWORD from 0x3 to 0x1 - Log print job error notifications in Event Viewer.","'HKLM\SYSTEM\CurrentControlSet\Control\Print\Providers' /v EventLog /t REG_DWORD /d 0x1 /f"),
  ("CrashDumpEnabled DWORD from 0x7 to 0x0 - Disable crash dump creation.","'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' /v CrashDumpEnabled /t REG_DWORD /d 0x0 /f"),
  ("LogEvent DWORD from 0x1 to 0x0 - Disable system crash logging to Event Log.","'HKLM\SYSTEM\CurrentControlSet\Control\CrashControl' /v LogEvent /t REG_DWORD /d 0x0 /f"),
  ("ErrorMode DWORD from 0x0 to 0x2 - Hide hard error messages.","'HKLM\SYSTEM\CurrentControlSet\Control\Windows' /v ErrorMode /t REG_DWORD /d 0x2 /f"),
  ("MaxSize DWORD from 0x01400000 to 0x00010000 - Reduce Application Event Log size to 64KB","'HKLM\SYSTEM\CurrentControlSet\Services\Eventlog\Application' /v MaxSize /t REG_DWORD /d 0x10000 /f"),
  ("MaxSize DWORD from 0x0140000 to 0x00010000 - Reduce Security Event Log size to 64KB.","'HKLM\SYSTEM\CurrentControlSet\Services\Eventlog\Security' /v MaxSize /t REG_DWORD /d 0x10000 /f"),
  ("MaxSize DWORD from 0x0140000 to 0x00010000 - Reduce System Event Log size to 64KB.","'HKLM\SYSTEM\CurrentControlSet\Services\Eventlog\System' /v MaxSize /t REG_DWORD /d 0x10000 /f"),
  ("ClearPageFileAtShutdown DWORD to 0x0 - Disable clear Page File at shutdown.","'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' /v ClearPageFileAtShutdown /t REG_DWORD /d 0x0 /f"),
  ("Creating Paths DWORD - Reduce IE Temp File.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Cache\Paths' /v Paths /t REG_DWORD /d 0x4 /f"),
  ("Creating CacheLimit DWORD - Reduce IE Temp File.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Cache\Paths\path1' /v CacheLimit /t REG_DWORD /d 0x100 /f"),
  ("Creating CacheLimit DWORD - Reduce IE Temp File.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Cache\Paths\path2' /v CacheLimit /t REG_DWORD /d 0x100 /f"),
  ("Creating CacheLimit DWORD - Reduce IE Temp File.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Cache\Paths\path3' /v CacheLimit /t REG_DWORD /d 0x100 /f"),
  ("Creating CacheLimit DWORD - Reduce IE Temp File.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Cache\Paths\path4' /v CacheLimit /t REG_DWORD /d 0x100 /f"),
  ("DisablePasswordChange DWORD from 0x0 to 0x1 - Disable Machine Account Password Changes.","'HKLM\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' /v DisablePasswordChange /t REG_DWORD /d 0x1 /f"),
  ("PreferredPlan REG_SZ from 381b4222-f694-41f0-9685-ff5bb260df2e to 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c - Changing Power Plan to High Performance.","'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel\NameSpace\{025A5937-A6BE-4686-A844-36FE4BEC8B6D}' /v PreferredPlan /t REG_SZ /d 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c /f"),
  ("TimeoutValue DWORD from 0x41 to 0xC8 - Increase Disk I/O Timeout to 200 seconds.","'HKLM\SYSTEM\CurrentControlSet\Services\Disk' /v TimeoutValue /t REG_DWORD /d 0xC8 /f"),
  ("Start DWORD from 0x2 to 0x4 - Disable the Sync Host Service.","'HKLM\SYSTEM\CurrentControlSet\Services\$SyncService' /v Start /t REG_DWORD /d 0x4 /f")


 #Check if VMware Tools is installed. If so, ask user if they want to hide the VMware Tools icon from the Notification Area. If yes, add required object to CreateRegistry array.
 if ( Test-Path 'C:\Program Files\\VMware\VMware Tools' )
 { $VMwareAnswer = Read-Host VMware Tools has been detected on your system. Would you like to hide the VMware Tools icon from the Notifications Area for all users? Y/N }
     else { $VMwareAnswer = 'N' }
     while ( "Y","N" -notcontains $VMwareAnswer ) { $VMwareAnswer = Read-Host "Enter Y or N" }
         if ( $VMwareAnswer -eq "Y" ) { $CreateRegistry +=("ShowTray DWORD - Hide VMware Tools tray icon.","'HKLM\SOFTWARE\VMware, Inc.\VMware Tools' /v ShowTray /t REG_DWORD /d 0x0 /f") 
                                     }

Application REG_EXPAND_SZ from default location to $DriveLetterAnswer - Move Application Event Log from default location to $DriveLetterAnswer","'HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application' /v File /t REG_EXPAND_SZ /d '$($DriveLetterAnswer):\Event Logs\Application.evtx' /f"),
                                                           ("Security REG_EXPAND_SZ from default location to $DriveLetterAnswer - Move Security Event Log from default location to $DriveLetterAnswer","'HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Security' /v File /t REG_EXPAND_SZ /d '$($DriveLetterAnswer):\Event Logs\Security.evtx' /f"),
                                                           ("System REG_EXPAND_SZ from default location to $DriveLetterAnswer - Move System Event Log from default location to $DriveLetterAnswer","'HKLM\SYSTEM\CurrentControlSet\Services\EventLog\System' /v File /t REG_EXPAND_SZ /d '$($DriveLetterAnswer):\Event Logs\System.evtx' /f")
                                       }

 #Check if user is using App Layering. If using App Layering, the "Microsoft Software Shadow Copy Provider" and "Volume Shadow Copy" services will be disabled.
 $ALAnswer = Read-Host Are you planning to use this image with App Layering? Y/N
  while ( "Y","N" -notcontains $ALAnswer ) { $ALAnswer = Read-Host "Enter Y or N" }
           if ( $ALAnswer -eq "Y" ) { $Services +=("swprv - Microsoft Software Shadow Copy Provider","swprv"),
                                                 ("VSS - Volume Shadow Copy","VSS")
                                       }

 #Creating Registry Objects
 foreach ($NewCreateRegistryObject in $NewCreateRegistry) {
 Write-Host Creating registry object $NewCreateRegistryObject[0] -ForegroundColor Cyan
 Invoke-Expression ("reg add " + $NewCreateRegistryObject[1])
 Invoke-Expression $Pausefor2
 }

 #Deleting Registry Objects
 foreach ($DeleteRegistryObject in $DeleteRegistry) {
 Write-Host Deleting registry object $DeleteRegistryObject[0] -Foregroundcolor Cyan
 Invoke-Expression ("reg delete " + $DeleteRegistryObject[1])
 Invoke-Expression $Pausefor2
 }
 

 #Modifying Registry Objects
 foreach ($NewModifyRegistryObject in $NewModifyRegistry) {
 Write-Host Modifying $NewModifyRegistryObject[0] -ForegroundColor Cyan
 Invoke-Expression ("reg add " + $NewModifyRegistryObject[1])
 Invoke-Expression $Pausefor2
 }





 #Removing Windows Defender which also removes Scheduled Tasks and services related to Windows Defender
 Write-Host Removing Windows Defender. -ForegroundColor Cyan
 Remove-WindowsFeature "Windows-Defender-Features"

#>