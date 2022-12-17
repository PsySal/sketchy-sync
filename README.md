# sketcy-sync

Sketchy tool for rsync'ing files. I really can't recommend you use this-- it's just not very safe and may even delete/overwrite files unexpectedly. O.K. you've been warned!

:warning: sketchy-sync does not have any logic to resolve conflicts. in case you edit a file in two places and then sync them back up, there is no real guarantee which edit will "stick". Typically in this case you will simply lose one or the other edits silently.

## Prerequisites

sketchy-sync uses a central hub to sync to and from. I use it to sync files that are too large or inconvenient to manage via Git.

Before it will work you need:

- a hub server which you can rsync to, for instance a local file server
- passwordless ssh access set up
- rsync installed locally

## Connect

Use `--connect` to initialize a local archive. sketchy-sync will:

- create a configuration directory `~/.sync` from your current working directory
- run a bunch of tests to make sure it looks like files will sync properly; no guarantees though

For example:

```bash
$ sketchy-sync.rb --connect yourname@yourhubserver:/Path/to/ARCHIVE
```

## Sync

sketchy-sync considers top level directories to be a special case.

Suppose your hub server had a directory, "SAMPLES". You can sync them down with:

```bash
$ mkdir SAMPLES
$ sketchy-sync.rb
```

This will grab everthing from the hub server's "SAMPLES" directory, including subdirectories. If you then make modifications or edit files locally in "SAMPLES", the next run of sketchy-sync will sync them back up.

:warning: sketchy-sync does not have any logic to resolve conflicts. in case you edit a file in two places and then sync them back up, there
is no real guarantee which edit will "stick". Typically in this case you will simply lose one or the other edits silently.

## Advanced

There are some options in .sync/sync_settings.yaml you can toy with. Not currently documented.

## Building, Installing Gem

```bash
$ gem build sketchy_sync.gemspec
$ gem install ./sketchy_sync-2.0.0.gem
``

