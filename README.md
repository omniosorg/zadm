<img src="http://www.omniosce.org/OmniOSce_logo.svg" height="128">

zadm
=========

[![Build Status](https://travis-ci.org/omniosorg/zadm.svg?branch=master)](https://travis-ci.org/omniosorg/zadm)

Version: 0.1.0-rc1

Date: 2020-05-04

zadm is a zone admin tool.

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
