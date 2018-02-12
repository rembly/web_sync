#!/bin/sh

# assumes ruby installed
# sudo apt-get install software-properties-common
# sudo apt-add-repository -y ppa:rael-gc/rvm
# sudo apt-get update
# sudo apt-get install rvm
# rvm --default install ruby-2.5.0

# Exit if any subcommand fails
set -e

# Copy over configs
if ! [ -f .env ]; then
  cp .example.env .env
fi

if ! [ -f ./config/.example.smtp_settings.yml ]; then
  cp ./config/.example.smtp_config.yml ./config/smtp_config.yml
fi

# Set up Ruby dependencies via Bundler
gem install bundler --conservative
bundle check || bundle install
