#!/bin/sh

set -e

go fmt
go build -o precommit.out
stat precommit.out
