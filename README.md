<img src="https://www.omnios.org/OmniOSce_logo.svg" height="128">

zadm
=========

[![Unit Tests](https://github.com/omniosorg/zadm/workflows/Unit%20Tests/badge.svg?branch=master&event=push)](https://github.com/omniosorg/zadm/actions?query=workflow%3A%22Unit+Tests%22)

Version: 0.14.0

Date: 2023-07-03

`zadm` - zone management tool.

Setup
-----

To build `zadm` you require perl and gcc packages on your
system.

Get a copy of `zadm` from https://github.com/omniosorg/zadm/releases
and unpack it into your scratch directory and cd there.

    ./configure --prefix=$HOME/opt/zadm
    gmake

Configure will check if all requirements are met and give
hints on how to fix the situation if something is missing.

Any missing perl modules will be built and installed into the prefix
directory. Your system perl will NOT be affected by this.

To install the application, just run

    gmake install

Check the [man page](doc/zadm.pod) for information about how to use `zadm`.

