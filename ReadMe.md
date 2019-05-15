# backup-restic
Restic backup for Linux and Windows machines. Written in Powershell with Powershell Core in mind.
Backup source may be the complete machine or specific diretories.
Backup target may be a local repository or AWS S3.


What to do to get started:
- Download and install restic backup on each maschine that should be backed up (restic.net)
- Download and install Powershell Core somewhere
- Download and install the database client driver 
- Create a database (in my case MySQL) 
- Put the backup script "restic-backup.ps1" somewhere
- Create a config file. Set restrictive file system rights! There are passwords in there. For each repository and individual config file
- Create a cron job / scheduled task. The path to powershell, the restic backup script and the config file are set in that automatic job definition


What to expect:
- Backups should run automatically since they are configured as cron jobs / scheduled tasks. Automation is the key imho
- Current status of a backup process is written to a central database
- Backup result is written to a database


Todo:
- Upload the webpage that displays the latest status to this github repository
- Add notification via email, if backups failed
- Add the other supported backup target / repository types
- Improvement in detecting backup process malfunctions
- Add some kind of watchdog mechanism to deal with potentialy stalled backups
- Add way more robustness to the backup script
- Put database and webserver in a docker image
- Maybe start thinking about if we might need expiry of backups / retention time
- When working with AWS maybe a good idea to automate setting the S3 storage class (Standard, IA, Glacier, ...) after creating the repo for the first time
