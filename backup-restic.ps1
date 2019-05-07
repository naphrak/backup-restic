$version = "0.0.2"
#
# Variables
$restic_exe_linux = '/usr/local/bin/restic'
$restic_exe_win   = 'C:\temp\restic_0.9.5_windows_amd64.exe'
$mysql_dll_linux  = "$(Resolve-Path ~)/.config/restic/MySql.Data.dll"  
$mysql_dll_win    = "C:\Program Files (x86)\MySQL\MySQL Connector Net 8.0.16\Assemblies\v4.5.2\MySql.Data.dll"
$currdate         = get-date -format "yyyy-MM-dd HH:mm"


# Preparation
$confpath = $args[0]
IF ( test-path $confpath -ErrorAction Stop ) {
   TRY {
      $vars = Get-Content $confpath | ConvertFrom-json

   }
   CATCH {
      Write-Host -ForegroundColor Red "ERROR: Syntax error parsing json config file!"
      EXIT
   }
} ELSE {
     Write-Host -ForegroundColor Red "Error: Missing config file ´"config.json´". Exiting!"
     EXIT
}

IF ( ($env:processor_architecture).length -eq 0 ) {
   #write-host -foregroundcolor Yellow "Linux environment detected"
   $resticExePath = $restic_exe_linux
   add-type -Path $mysql_dll_linux                                #prep MySql driver
} ELSE {
   #write-host -foregroundcolor Yellow "Windows environment detected"
   Add-Type -Path $mysql_dll_win                                  #prep MySql driver
   $resticExePath = $restic_exe_win
}

$resticversion = (&($resticExePath) version).Split()[1]


# Functions

#===========================================
#=== Write into database
#===========================================
Function write2db( $querystring ) {
   TRY {
      $Connection = New-Object MySql.Data.MySqlClient.MySqlConnection
      $Connection.Connectionstring = $ConnectionString
      $Connection.Open()

      $Command = New-Object MySql.Data.MySqlClient.MySqlCommand($querystring, $Connection)
      $DataAdapter = New-Object MySql.Data.MySqlClient.MySqlDataAdapter($Command)
      $DataSet = New-Object System.Data.DataSet
      $DataAdapter.Fill($DataSet, "data")
      $DataSet.Tables[0]
      $Connection.Close()
   }
   CATCH {
      Write-Host -Foregroundcolor Red "ERROR : Unable to run query : $Query `n$Error[0]"
      EXIT
   }
}
#===========================================





#===========================================
#== Main 
#===========================================
IF ( test-path $confpath ) {
     $vars = Get-Content $confpath | ConvertFrom-json
} ELSE {
     Write-Host -ForegroundColor Red "ERROR: Missing config file config.json. Exiting!"
     EXIT
}

$env:RESTIC_REPOSITORY=$vars.backupset.repository
$env:RESTIC_PASSWORD=$vars.backupset.password
$env:AWS_ACCESS_KEY_ID=$vars.backupset.AWS_ACCESS_KEY_ID
$env:AWS_SECRET_ACCESS_KEY=$vars.backupset.AWS_SECRET_ACCESS_KEY
$ConnectionString = "server=" + $vars.dbconfig.host  + ";port=" + $vars.dbconfig.port  +  ";uid=" + $vars.dbconfig.user + ";pwd=" + $vars.dbconfig.password + ";database="+$vars.dbconfig.database


# Check if restic repo exists and create it
$command = "$resticExePath init --verbose --json"
$scriptblock = [ScriptBlock]::Create($command)
$initjob = Start-Job -ScriptBlock $scriptblock 

Wait-Job -Id $initjob.Id -Timeout 300 |Out-Null

IF ( (get-job $initjob.id).State -eq 'Completed' ) {
   $logoutput = $initjob.ChildJobs.output
   $logerror  = $initjob.ChildJobs.error
   IF ( $logoutput ) {
      Write-Host -ForegroundColor Green $logoutput
   } ELSEIF ( $logerror ) {
      Write-Host -ForegroundColor Red "ERROR: "$logerror
   }
}


# Restic Repo exists - Backing up 
FOREACH ($entry in $vars.backupset.srcdirs) {
   Write-Host -Foregroundcolor Yellow "Backing up: " $entry

   $tag = $vars.backupset.tag
   $exclude = $vars.backupset.excludefile
   $errormsg = 'na'	
   $status = 'running'

   # Write status "running" to database
   $Query = "use "+$vars.dbconfig.database+"; INSERT INTO "+$vars.dbconfig.table+" ( `
                                                hostname, `
                                                insertdate, `
                                                updatedate, `
                                                setname, `
                                                srcdir, `
                                                laststatus, `
                                                resticversion ) `
                                       VALUES ('" + $vars.backupset.host + "','" + `
                                                   $currdate + "','" + `
                                                   $currdate + "','" + `
                                                   $vars.backupset.setname + "','" + `
                                                   $entry + "','" + `
                                                   $status + "','" + `
                                                   $resticversion + "') `
                                       ON DUPLICATE KEY UPDATE updatedate='"+$currdate+ "',setname='"+$vars.backupset.setname+"',srcdir='"+$entry+"',`
                                       laststatus='" + $status + "',resticversion ='" + $resticversion + "';"
   #Write "running" status to database
   write2db $Query
   
   #Start backup process
   $command = "$resticExePath backup '" + $entry + "' --tag '" + $tag + "' --verbose --cleanup-cache --exclude-file='" + $exclude + "' --json"
   $scriptblock = [ScriptBlock]::Create($command)
   $backupjob = Start-Job -ScriptBlock $scriptblock 

   # While job is running check every 15 seconds
   $modu = $true
   while ( (get-job $backupjob.id).State -eq 'Running' ) {
      IF ( ((get-date -Format ss) % 15) -eq 0 -and $modu ) {         
         $modu = $false
         $logoutput = $backupjob.ChildJobs.output | Select-Object -Last 1
         # Only in Windows the job output starts with some strange characters. Get rid of them to be able to convertfrom-json
         IF ( $logoutput[0] -eq '{' ) {
            # Linux behavior
            $logoutput = $logoutput | ConvertFrom-Json
         } ELSE {
            # Windows behavior. Getting rid of the four leading garbage characters.
            $logoutput = $logoutput.substring(4,$($logoutput.length)-4) | ConvertFrom-Json
         }
         IF ($logoutput.message_type -eq 'Status') {
            IF ( $logoutput.percent_done ) {
               # Write status "running" to database
               $Query = "use "+$vars.dbconfig.database+";UPDATE "+$vars.dbconfig.table+" SET `
                                          hostname = '" + $vars.backupset.host + "',  `
                                          laststatus = '" + $status + " " + $(($logoutput.percent_done * 100).tostring().split(',')[0]) + "%', `
                                          files_new = '" + $logoutput.files_done + "', `
                                          data_added = '" + $logoutput.bytes_done + "', `
                                          total_files_processed = '" + $logoutput.total_files + "', `
                                          total_bytes_processed = '" + $logoutput.total_bytes + "', `
                                          resticversion = '" + $resticversion + "' `
                                       WHERE updatedate='" + $currdate  + "' AND setname='" + $vars.backupset.setname + "' AND srcdir='"+ $entry + "';"

               #Write "running" status to database
               write2db $Query
            }
         }
      } ELSE {
         IF ( ((get-date -Format ss) % 15) -ne 0 ) {
            $modu = $true
         }
      }
   }

   IF ( (Get-Job -Id $backupjob.id).state -eq "Completed") {
      IF (-not $backupjob.ChildJobs.error) {
         $joboutput = $backupjob.ChildJobs.output
         FOR ($x = $joboutput.length ; $x-- ; $x -ge 0) {
            IF ($joboutput[$x].length -gt 4) {
               # Only in Windows the job output starts with some strange characters. Get rid of them to be able to convertfrom-json
               IF ( $joboutput[$x][0] -eq '{' ) {
                  # Linux behavior
                  $logoutput = $joboutput[$x] | ConvertFrom-Json
               } ELSE {
                  # Windows behavior. Getting rid of the four leading garbage characters.
                  $logoutput = $joboutput[$x].substring(4, $joboutput[$x].length -4) | ConvertFrom-Json
               }
               IF ($logoutput.message_type -eq "summary"){
                  $donedate = get-date -format "yyyy-MM-dd HH:mm"
                  $status = 'ok'
                  $Query = "use "+$vars.dbconfig.database+"; UPDATE "+$vars.dbconfig.table+" SET `
                                                               hostname = '" + $vars.backupset.host + "',  `
                                                               updatedate = '" + $donedate + "', `
                                                               setname = '" + $vars.backupset.setname + "', `
                                                               srcdir = '" + $entry + "', `
                                                               laststatus = '" + $status + "', `
                                                               files_new = '" + $logoutput.files_new + "', `
                                                               files_changed = '" + $logoutput.files_changed + "', `
                                                               files_unmodified = '" + $logoutput.files_unmodified + "', `
                                                               dirs_new = '" + $logoutput.dirs_new + "', `
                                                               dirs_changed = '" + $logoutput.dirs_changed + "', `
                                                               dirs_unmodified = '" + $logoutput.dirs_unmodified + "', `
                                                               data_blobs = '" + $logoutput.data_blobs + "', `
                                                               tree_blobs = '" + $logoutput.tree_blobs + "', `
                                                               data_added = '" + $logoutput.data_added + "', `
                                                               total_files_processed = '" + $logoutput.total_files_processed + "', `
                                                               total_bytes_processed = '" + $logoutput.total_bytes_processed + "', `
                                                               total_duration = '" + $logoutput.total_duration + "', `
                                                               snapshot_id = '" + $logoutput.snapshot_id + "', `
                                                               errormsg = '" + $errormsg + "', `
                                                               resticversion = '" + $resticversion + "' `
                                                         WHERE updatedate='" + $currdate  + "' AND setname='" + $vars.backupset.setname + "' AND srcdir='"+ $entry + "';"
                  write2db $Query
                  break
               }
            }
         }
      } ELSE {
         $status = 'failed'
         $Query = "use "+$vars.dbconfig.database+"; UPDATE "+$vars.dbconfig.table+" SET `
                                                         hostname = '" + $vars.backupset.host + "', `
                                                         laststatus = '" + $status + "', `
                                                         errormsg = '" + $backupjob.ChildJobs.error + "' `
                                                   WHERE updatedate='" + $currdate  + "' AND setname='" + $vars.backupset.setname + "' AND srcdir='"+ $entry + "';"
         write2db $Query
      }
   }
}
