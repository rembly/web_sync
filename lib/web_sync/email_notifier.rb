require 'net/smtp'
require 'yaml'
require 'active_support/all'
require 'pony'


class EmailNotifier
  LOG = Logger.new(File.join(File.dirname(__FILE__), '..', '..', 'log', 'email.log'))
  EMAIL_CONFIG = YAML.load_file(File.join(File.dirname(__FILE__), '..', '..', 'config', 'smtp_config.yml'))

  def initialize
    @to = EMAIL_CONFIG['to']
    @from = EMAIL_CONFIG['from']
    @options = EMAIL_CONFIG['via_options'].inject({}){|map, (key, val)| map[key.to_sym] = val; map}
  end

  def send_email(subject:, body:)
    LOG.info("To/From: #{@to}/#{@from}, Subject: #{subject}, Body: #{body}, Options: #{@options}")
    # TODO uncomment when ready to send
    # Pony.mail(body: body, subject: subject, to: @to, from: @from, via: :smtp, via_options: @options)
  end
end
