A perl script to track changes in a directory
and zip them, encrypt them, and back them up to
Amazon's s3 storage.

It needs these packages installed in debian:

* sudo apt-get install perl gzip gnupg s3cmd 

You can skip the encryption if you want.

I built it for me. I wanted:
* Simple to install
  * Install with a simple file copy and cron job
* Needs few libs
* Encrypts before sending
* Backup whole directories
* Stop after given amount of bandwidth
* Stop after given amount of time.


Things I still want but it doesn't do yet:
* Give priority to certain sub-directories
* Limit bandwidth in any given minute.

Things I don't want:
* Hidden directory names/structure
* Less than one archive file per backed up file

I want to be able to restore any given file
as easily as possible, so each is packed and
decrypted and split into chunks if needed
then sent to S3, one chunk at a time.

This may well mean it takes up more space on
the remote system. I'm cool with that. I want
to be able to see the filenames and pick
the files at random.


How It Works
============
Run it in a script, or from the command line.
Pass it the path to a directory.

First time you run it, it'll create a config
file in the root of that directory.

Edit that file to give it a bucket name
and gpg encryption recipient.

Then run it again. It'll take each file in 
the directory, compress it, encrypt it, split
it if it's big, and upload each chunk to S3
with the same path-name as the path-name on
your local machine.

If it runs out of time (specified in minutes)
it'll stop.

If it hits a chunk-limit, it'll stop.

When it's done, it writes a database of
which files have been backed up and when
they were backed up into the root of the
backup directory.

It always ensures existing backed up files
don't need refreshing before continuing with
looking for new files.

If you tell it -verbose, it'll tell you what
it's doing.

Stick it in a cron to run every night when you
hit the sack, tell it to run for no longer than
when you sleep. Provided you don't create more
edit more data every day than you can upload
every night, eventually your whole system should
be backed up.

Starting with the important ones.
=================================

Since it does things in the database first, you
can pre-load the database with a bunch of files.
pipe 'find /path/to/important/files' into appending
to the database file, then do a regexp
s/^/"/g
and
s/$/" 0/g

On the new lines.

I might make this better later, but this is
enough for me for now.
