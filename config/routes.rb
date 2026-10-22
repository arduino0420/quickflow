Rails.application.routes.draw do
  if Demo::Guest.enabled?
    post "/guest/:role", to: "guest_sessions#create", as: :guest_login
  end

  namespace :admin do
    get "login", to: "sessions#new", as: :login
    post "login", to: "sessions#create"
    delete "logout", to: "sessions#destroy", as: :logout
    resources :teachers, only: [ :index, :new, :create, :edit, :update ]
    resources :students, only: [ :index, :new, :create, :edit, :update, :destroy ] do
      member do
        post :confirm_update
        get :confirm_destroy
      end
      resource :password_reset, only: [ :edit, :update ], controller: "student_password_resets"
    end
    root "dashboard#show"
  end

  get "/login", to: "sessions#new", as: :login
  post "/login", to: "sessions#create"
  delete "/logout", to: "sessions#destroy", as: :logout

  get "/student/login", to: "student_sessions#new", as: :student_login
  post "/student/login", to: "student_sessions#create"
  delete "/student/logout", to: "student_sessions#destroy", as: :student_logout

  resources :students, only: [ :new, :create ]

  resources :assignments, only: [ :index, :show, :new, :create, :edit, :update, :destroy ] do
    get :export, on: :member, defaults: { format: :xlsx }
    resources :submissions, only: [ :show, :update ] do
      get :answer, on: :member
      post :resume_grading, on: :member
    end
  end

  namespace :student do
    resources :assignments, only: [ :index, :show ] do
      get :material, on: :member
      get :result, on: :member
      get :answer, on: :member
      resource :answer_draft, only: [ :show, :update ] do
        get :recovery, on: :member
      end
      resource :pdf_preview, only: [ :show ], controller: "pdf_previews"
      resource :submission, only: [ :show, :create ]
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "home#index"
end
