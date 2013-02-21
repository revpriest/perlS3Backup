perlS3Backup
============

A perl script to zip, encrypt, split-if-needed and upload to S3 every file. It saves it's progress and quits after a set number of files or minutes. Put it in a cron-job to incrementally back up a folder. 