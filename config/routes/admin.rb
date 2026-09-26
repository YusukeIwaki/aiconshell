# frozen_string_literal: true

# Admin console routes (issue 7). Loaded from the application routes with:
#
#   Rails.application.routes.draw do
#     ...
#     draw(:admin)
#   end
#
# Kept in a separate file so this lane never edits config/routes.rb itself;
# the coordinator adds the one-line `draw(:admin)` call at merge time.
namespace :admin do
  root "tasks#index"

  resources :tasks, only: %i[index show] do
    resources :feedbacks, only: %i[create]
  end

  resources :layer_policies, only: %i[index edit update], param: :layer
  resources :plugins, only: %i[index]
  resources :event_logs, only: %i[index]
end
