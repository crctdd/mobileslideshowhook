#!/bin/sh
set -e
make clean
make package THEOS_PACKAGE_SCHEME=roothide
