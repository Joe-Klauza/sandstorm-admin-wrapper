#!/usr/bin/env bash

pushd admin-interface

bundle && bundle exec ruby lib/webapp.rb

