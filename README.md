Einarc - Einarc is not a RAID CLI
=================================

Einarc is a part of Inquisitor platform, a universal storage RAID
command line interface and an API that provides management for various
hardware/software RAID devices, uniting them all in a single paradigm.

How does it work?
-----------------

So far, anyone who wanted to manage a storage device had to download
proprietary management utility, learn it and use it. There's no even
single standard in the industry: for example, Areca uses 3-tier
hierarchy while building RAIDs (physical discs – raidsets –
volumesets), LSI uses 2-tier hierarchy (physical discs – logical
discs).

Enter Einarc, a solution to unify proprietary storage management
paradigms. Einarc works as a translator that makes it possible for a
user to control all these devices using simple terms like "physical
disc", "logical disc", "adapter", etc, while transparently converting
these requests to proprietary RAID paradigms. In fact, the system
still uses underlying proprietary CLIs, but the user doesn't interact
with them directly, staying in a single, well-documented interface.

Who would be interested to use Einarc?
--------------------------------------

First of all, system administrators who have a large variety of
RAIDs/storage devices to manage and who want to manage them all in the
single paradigm. There's no need to remember lots of cryptic commands
to create volumes on particular model of RAID controller, it would be
just one single and simple command like `einarc logical add 5 100000
0:1,0:2,0:3` (that means add *logical* disc, *RAID level 5*, with size
of *100000 MB* and consisting of 3 physical drives: *0:1,0:2,0:3*).

Second, Einarc is also a easy-to-use library that can be used in other
software that needs unified disc management. For example, it is used
in Inquisitor to test discs arrays, building and destroying various
logical disc combinations under the stress.

Requirements
------------

Build requirements:
* wget
* gzip / gunzip
* tar
* unzip
* ruby
* make

Runtime requirements:
* ruby

Recommended:
* asciidoc / a2x (to build documentation)

Licensing
---------

Unfortunately, Einarc uses some proprietary command-line utilities to
control storages. Using it means that you agree with respective
licenses and download agreements. For your convenience, they are
available in `agreements/` directory. Please read them and agree
before issuing `make download` command and using this software.

Standalone installation
-----------------------

Installation of Einarc involves following things:

* `./configure` (generates `Makefile.config` and `src/raid/config.rb`)
* `make download` to download all the proprietary tools; doing so means
you've read and agreed to the agreements & licenses listed above.
* `make` to build Einarc's files
* `make install` to install everything

Documentation
-------------

See reference manual for general usage recommendations.
