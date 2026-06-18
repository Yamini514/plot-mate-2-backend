
options = {
  address: ENV['EMAIL_SMTP_SERVER'],
  port: 465,
  domain: ENV['EMAIL_DOMAN'],  # Replace with your domain
  user_name: ENV['EMAIL_USER'],  # Replace with your email username
  password: ENV['PASSWORD'],  # Replace with your email password
  authentication: 'plain',
  enable_starttls_auto: true,  # If TLS is needed, but for port 465 SSL is directly used
  ssl: true  # SSL is required on port 465
}

Mail.defaults do
  delivery_method :smtp, options
end



# mail = Mail.new do
#   from    'noreply@vhrr.net'
#   to      'sathish@pasupunuri.com'  # Replace with the recipient email
#   subject 'Test email'
#   body    'This is a test email sent from a Ruby Roda app!'
# end

# mail.deliver!