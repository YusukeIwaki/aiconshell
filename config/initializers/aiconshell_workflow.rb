# frozen_string_literal: true

# Pure Ruby port roots are deliberately excluded from Zeitwerk.
%w[plugins ai observability].each do |port|
  path = Rails.root.join("lib", "aiconshell", "#{port}.rb")
  if path.file?
    require path.to_s
  else
    Rails.logger.warn("[workflow] #{port} port is unavailable")
  end
end

Rails.application.config.after_initialize do
  WorkflowSettings.validate!
end
