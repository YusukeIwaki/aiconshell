# frozen_string_literal: true

module Admin
  # Plugin configuration diagnosis. Shows plugin ids, supported
  # operations, and required environment variable *names* with a
  # configured flag. Secret values are never read for display and never
  # rendered. A failing plugins lane degrades to an inline notice; the
  # rest of the admin console is unaffected.
  class PluginsController < BaseController
    def index
      result = PluginStatus.catalog
      @entries = result.entries
      @plugins_available = result.available
      @plugins_error = result.error
    end
  end
end
