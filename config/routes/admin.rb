# frozen_string_literal: true

# Admin console routes loaded by draw(:admin) in config/routes.rb.
namespace :admin do
  root "tasks#index"

  resources :tasks, only: %i[index show] do
    resources :feedbacks, only: %i[create]
  end

  resources :layer_policies, only: %i[index edit update], param: :layer
  resources :plugins, only: %i[index]
  resources :event_logs, only: %i[index]
  resources :task_requests, only: %i[new create show]
end
