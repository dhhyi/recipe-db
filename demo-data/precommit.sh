#!/bin/sh

set -e

ariadne-codegen --config precommit.toml

black ./*.py
pylint ./*.py
