# frozen_string_literal: true

# Admin console routes loaded by draw(:admin) in config/routes.rb.
namespace :admin do
  root "tasks#index"

  resources :tasks, only: %i[index show] do
    resources :feedbacks, only: %i[create]
  end

  resources :layer_policies, only: %i[index edit update], param: :layer do
    member do
      post :connection_check
    end
  end
  resources :accounts, only: %i[index] do
    collection do
      patch :github
      patch :discord
      post :health_check
      post :rotate_api_token
    end
  end
  resources :event_logs, only: %i[index]
  resources :task_requests, only: %i[new create show]
  resources :ai_connections, only: %i[index] do
    collection do
      post :login
      post :status_check
    end
    member do
      post :code
      post :cancel
    end
  end
end
