# frozen_string_literal: true

namespace :api do
  namespace :admin do
    resources :task_requests, only: %i[create show]
  end
end
