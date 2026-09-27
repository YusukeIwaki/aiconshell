Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Public entry page; operational data remains behind admin authentication.
  root "home#index"

  # User-delegated OAuth provider callback (issue #23). Public on
  # purpose: the provider redirects the operator's browser here without
  # admin credentials, and the session-bound one-time state is the
  # forgery guard. The provider name is fixed by this constraint; token
  # URLs, redirect URIs, and tenants always come from fixed
  # configuration, never from callback input.
  get "oauth/:provider/callback", to: "oauth_callbacks#show", as: :oauth_callback,
      constraints: { provider: /atlassian|microsoft/ }

  # Admin console (issue #7). Route details live in config/routes/admin.rb.
  draw(:admin)

  # JSON admin API for task requests (issue #10). Details in config/routes/api.rb.
  draw(:api)
end
