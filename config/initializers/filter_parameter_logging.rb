# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :title, :description, :body,
  :auth_code, :verification_uri, :user_code, :encrypted_challenge, :encrypted_input_code,
  # User-delegated OAuth callback (issue #23): the provider returns
  # code/state/error/error_description in the callback query, and the
  # authorize redirect carries state/code_challenge. Filtering keeps them
  # out of the "Started ..." request line (filtered_path) and the
  # Parameters log line. Partial matching also covers compound names.
  :code, :state, :error, :error_description, :challenge, :verifier
]
